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
| `brain/tests/` | Unit tests (fake LLM) + `fixtures/messages.jsonl`, the 64-case golden set |
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

Open `http://<server>.<tailnet>.ts.net:8080`. Most settings (people to watch, the reminders list,
model, alerts, mail) can then be changed on the dashboard's **Settings** page. Those edits are saved in
the brain's database on top of `config.yaml`, apply immediately, and each field shows whether it comes
from the file or the dashboard (with a reset link). Secrets can come from env vars instead of the file
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

The **Test lab** page does a dry run (prompt → raw output → planned commands) and
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
make test          # brain: 113 tests, no network (fake LLM)
make run           # brain locally on :8080 with ./config.yaml
make agent-test    # mac-agent: swift test (also runs on Linux, minus EventKit)
```

## iPhone app (PWA)

The dashboard installs as a home-screen app with its own icon. It opens full screen with an
iOS-style design: large titles, blurred navigation and tab bars, inset grouped lists, action
sheets, pull to refresh, and light/dark mode. iOS only enables the offline parts (the service
worker) over HTTPS, and Tailscale can provide a real certificate:

```sh
# on the brain's host (once): needs MagicDNS + HTTPS certificates turned on in the Tailscale admin
tailscale serve --bg 8080        # → https://<host>.<tailnet>.ts.net
```

1. Set **Settings → Alerts & dashboard → Dashboard URL** to that `https://` address, so alert
   links open the app. Optionally rename the app there too (e.g. "Second Brain").
2. On the iPhone, open the `https://` address in Safari → Share → **Add to Home Screen**.

Offline, the app shows the last version of each page you opened; actions need the connection.
Over plain `http://` it still installs and works, just without the offline cache. The Mac
agent can keep using whichever address it already has.

## Dashboard

| Page | What it's for |
|---|---|
| **Overview** | Today's numbers, the live pipeline (Mac agent → gate → LLM → planner → queue → Reminders, each with status and 24h counts, lighting up as messages flow), recent activity, what's coming up, 14-day chart |
| **Activity** | Every message with search and status filters; each one opens a step-by-step trace (prompt, raw model output, commands, Mac results) with Undo / Retry / Edit |
| **Review** | Low-confidence items with one-tap Approve / Reject |
| **Created items** | Everything the agent put in Reminders and Calendar that hasn't been undone |
| **Test lab** | Dry-run a message against the live model |
| **System** | Every component's health, funnel, command queue, alerts, settings change log, the prompt; test-alert and back-up-now buttons |
| **Settings** | People & chats to watch (add, rename, pause, remove), reminders list, alert times, review threshold, model endpoint (with connection test), Discord, mail |

It's built for the iPhone first (see **iPhone app** above) and works in light and dark mode.
Writes from other sites are blocked (same-origin check). Set `dashboard.password` if more people
share your tailnet, since anyone who can open the dashboard can change settings.

## Conversations, not just messages

Each conversation keeps track of what the agent created from it, and the model sees those open
items (numbered) with every new message. That lets later messages, including your own replies,
change earlier items:

| Message | What happens |
|---|---|
| Sarah: "Can you call the plumber?" | To-do **Call the plumber** (no date) |
| You: "I'll do it tomorrow" | Same to-do gets tomorrow's date and a 4 PM alert |
| Sarah: "Never mind about the eggs" | The earlier **Pick up eggs** is deleted |
| You: "Got the milk" | **Pick up milk** is checked off |
| Sarah: "Dentist moved to Wednesday at 10" | The existing dentist event moves (keeps its length) |
| Sarah: "I'd love this for my birthday https://…" | Added to **🎁 Gift ideas** in Sarah's column, tagged #Sarah, with the link |

Every item's notes start with who it's from and when, then a one-line summary and the original
message. Your own messages are only read when that conversation has open items, and they can
only change items, never create them (unless `allow_self_notes` is on). Each change is
recorded in the item's history on the **Created items** page, and **Undo** reverses it:
the old date comes back, a completed item is reopened, a cancelled one is re-created.

**Collections** are lists for things that aren't to-dos: gift ideas, things to remember about
someone, places to try, shows and books, recipes, someday ideas. Each collection is **one**
Reminders list. People are attached two ways:

- **Columns:** for collections set to "one column per person" (Gift ideas and People by
  default), each person gets a section. Switch the list to column view in Reminders to see
  Sarah | Mom | Emma side by side.
- **Tags:** every reminder tied to a person, to-dos included, gets a tag like `#Sarah`. Tap the
  tag in Reminders' sidebar to see everything for that person across lists.

Apple's public Reminders API can't set sections or tags, so the Mac agent uses Apple's private
ReminderKit framework for just that step. If it's unavailable (for example after a macOS update
changes it), the item is still created and the person's name goes in the title instead
("Sarah · Kindle Paperwhite"). The System page shows which mode is active. To check it on the
Mac, run `mac-agent --probe-reminderkit --write`.

You can add, rename or turn off collections in Settings. The description you write is what tells
the model what belongs there.

## Second brain

Built for an ADHD brain: capture with no friction, keep promises from slipping, and only ever
put a few things in front of you.

- **Notes to self:** add your own number in Settings → People and mark it **This is me**.
  Anything you text yourself, including a rambling brain dump, gets split into to-dos, ideas and
  saved notes, labelled "📝 Note to self". The duplicate copy Messages stores when you text
  yourself is skipped.
- **Promises you make:** "I'll send you the photos tonight" in a chat becomes a to-do marked
  "🤝 You promised Sarah". "Here you go!" later checks it off. Your messages are only read by the
  model when they sound like a commitment or the chat has open items.
- **Waiting on others:** "I'll ask my boss and let you know Monday" goes to **⏳ Waiting on**, in
  that person's column, with a follow-up on Monday. If no date was given, the follow-up is 3 days
  out. "Here's the quote" closes it.
- **A first step for big tasks:** "Do our taxes" gets "👉 Start: Find last year's return" as the
  second line of its notes, which shows in the Reminders preview, plus a few steps. Any to-do can
  get one later with **Break it down**.
- **Today's three:** each morning (07:30 by default) the model picks three things: late or due,
  promises first, plus a quick win. Each comes with a first step. They're moved into Reminders'
  **Today** view and posted to Discord. Everything else stays out of sight.
- **Evening recap** (20:30): what got done, unfinished picks moved back to their old dates (no
  overdue pile), and tomorrow's suggestions. You can pick tomorrow's three on the **Today** page.
- **Completion sync:** the Mac agent reports every few minutes which reminders you completed,
  edited or deleted on your phone. An item is only marked deleted after two reports in a row,
  and a report where most items vanish at once is ignored.

## How it behaves

- **Privacy:** the Mac agent syncs the allowlist from the brain (`GET /api/agent/config`), so texts
  from anyone else never leave the Mac. The brain also checks it and stores nothing for
  non-allowlisted senders. All inference stays on the Spark.
- **Gate (no LLM):** tapbacks, emoji-only, ≤3 chars, “ok/lol/thanks…”, and your own messages
  (unless `allow_self_notes`) are logged as `skipped`.
- **Extraction:** temperature 0, `response_format: json_schema`, thinking disabled via
  `chat_template_kwargs`. Relative dates resolve against the message's arrival time, and the
  prompt includes a 15-day calendar. One retry on a timeout or 5xx. If vLLM is down, events stay
  `received` and are retried automatically. After 3 failed calls a Discord alert goes out.
- **Planner:** every reminder goes to one list (`rules.reminder_list`), defaults the alert to 16:00 (an
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
2. **List and calendar names:** all reminders go to `Household`, events to `Family` (change both in
   Settings). The list is created if it doesn't exist (`rules.create_missing_lists`); calendars are not.
3. **Mail account:** `watch.mail` is disabled until you fill in the host and username and set
   an app password in `HA_MAIL_PASSWORD`.
