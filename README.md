# Household Agent

A private, always-on pipeline that watches household messages (iMessage, then Mail), uses the
local LLM on the Spark to pull out to-dos and events, and writes them into Apple Reminders and
Calendar. A web dashboard shows everything it did and why.

> Wife texts “Can you grab eggs tomorrow?” → reminder **Pick up eggs** in *Groceries*, due
> tomorrow, alert 4:00 PM, synced to your iPhone through iCloud.

See [PLAN.md](PLAN.md) for the full design and [docs/API.md](docs/API.md) for the wire contract.

```
mac-agent (Swift, Mac)  ──HTTPS/Tailscale──▶  brain (FastAPI, Docker, Linux)  ──▶  vLLM on the Spark
  chat.db watcher                               allowlist → gate → extract → plan
  EventKit writer        ◀──long-poll commands  SQLite log, dashboard, Discord alerts, IMAP IDLE
```

## Repo

| Path | What |
|---|---|
| `brain/app/` | FastAPI app: `main.py` routes, `pipeline.py`, `gate.py`, `extract.py`, `planner.py`, `commands.py` (queue + SSE bus), `heartbeat.py` (watchdog + Discord), `mail.py` (IMAP IDLE), `backup.py`, `eval.py` |
| `brain/app/prompts/extract.md` | The extraction prompt, versioned in its front matter (`extract-v1`), recorded on every event |
| `brain/tests/` | Unit tests (fake LLM) + `fixtures/messages.jsonl`, the 40-case golden set |
| `mac-agent/` | Swift package: chat.db watcher, typedstream decoder, EventKit, outbox, launchd plist, install scripts. See [mac-agent/README.md](mac-agent/README.md) |
| `config.example.yaml` | Copy to `config.yaml` (gitignored) |

## Setup

### 1. Brain (Linux home server, Docker)

```sh
cp config.example.yaml config.yaml      # fill in llm.base_url/model, your allowlist, token, webhook
openssl rand -hex 32                    # → security.agent_token
cd brain
mkdir -p data && sudo chown 1000 data   # the container runs as uid 1000
BIND_ADDR=$(tailscale ip -4) docker compose up -d --build
```

Open `http://<server>.<tailnet>.ts.net:8080`. Secrets can come from env vars instead of the file
(`HA_AGENT_TOKEN`, `HA_DISCORD_WEBHOOK_URL`, `HA_MAIL_PASSWORD`, `HA_DASHBOARD_PASSWORD`). The
dashboard has no login of its own and relies on Tailscale; set `dashboard.password` if you want
HTTP basic auth on top (user `admin`). The SQLite DB and nightly backups live in `brain/data/`.

Check the model before wiring up the Mac:

```sh
make eval                 # golden set against the live vLLM; needs ≥90% to exit 0
make eval ARGS="-v --only dentist-moved"
curl -X POST "http://localhost:8080/api/events?sync=true" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"event_id":"manual:1","sender_handle":"+1785555XXXX","received_at":"2026-11-20T16:52:00-06:00","text":"Can you grab eggs tomorrow?"}'
```

The **Try** page in the dashboard does a dry run (prompt → raw output → planned commands) and
stores or creates nothing. Use it to tune `prompts/extract.md`, and bump `version` when you change it.

### 2. Mac agent (M2 MacBook Air)

```sh
cd mac-agent
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
BRAIN_URL="http://<server>.<tailnet>.ts.net:8080" HA_AGENT_TOKEN="<same token>" \
./scripts/install.sh
```

Then grant **Full Disk Access** to the installed binary and approve the Reminders and Calendars
prompts. [mac-agent/README.md](mac-agent/README.md) covers each step, the logs and
troubleshooting. For lid-closed, always-on operation (phase 6), run
`./scripts/setup-mac-power.sh`.

## Development

```sh
make test          # brain: 58 tests, no network (fake LLM)
make run           # brain locally on :8080 with ./config.yaml
make agent-test    # mac-agent: swift test (also runs on Linux, minus EventKit)
```

## How it behaves

- **Privacy:** messages from senders or chats not on the allowlist get an `ignored` reply and
  nothing about them is stored. All inference stays on the Spark.
- **Gate (no LLM):** tapbacks, emoji-only, ≤3 chars, “ok/lol/thanks…”, and your own messages
  (unless `allow_self_notes`) are logged as `skipped`.
- **Extraction:** temperature 0, `response_format: json_schema`, thinking disabled via
  `chat_template_kwargs`. Relative dates resolve against the message's arrival time, and the
  prompt includes a 15-day calendar. One retry on a timeout or 5xx. If vLLM is down, events stay
  `received` and are retried automatically. After 3 failed calls a Discord alert goes out.
- **Planner:** routes lists by keyword (`rules.lists.routes`), defaults the alert to 16:00 (an
  alert already past for today becomes ~10 minutes from now), sets 60-minute default event
  lengths, and adds a 30-minute event alarm. Low confidence (<0.75), a past date or a missing
  event start puts the event in **needs review** and posts the dashboard link to Discord.
- **Write path:** commands are long-polled by the Mac and leased for 5 minutes, then
  redelivered. Each item's notes carry an `[ha:<event_id>]` tag, so a redelivery or retry never
  creates a duplicate.
- **Dashboard actions:** *Undo* deletes the created items. *Retry* re-runs extraction. *Edit*
  sends a hand-edited extraction with no confidence gate. Retry and Edit remove the earlier
  run's items first.
- **Watchdog:** no heartbeat for 3 minutes → “Mac agent offline” alert (once), with another
  alert on recovery. A lost permission (Full Disk Access, Reminders, Calendar) also alerts.

## Decisions to confirm

The plan says to ask before choosing between equally valid setup options. These defaults are in
place and easy to change in `config.yaml`:

1. **Brain host:** built for the Surface Pro 8 home server (Docker). Nothing is host-specific.
2. **List and calendar names:** `Groceries` and `Household` for reminders, `Family` for events.
   Lists are created if they don't exist (`rules.create_missing_lists`); calendars are not.
3. **Mail account:** `watch.mail` is disabled until you fill in the host and username and set
   an app password in `HA_MAIL_PASSWORD`.
