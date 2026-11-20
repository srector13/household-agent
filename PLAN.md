# Household Agent — Build Plan

A private, always-on pipeline that watches household messages (iMessage first, then Mail), uses a local LLM to extract to-dos and events, and writes them into Apple Reminders and Calendar — with a web dashboard showing everything it did and why.

Example: wife texts "Can you grab eggs tomorrow?" → a reminder "Pick up eggs" lands in the Groceries list, due tomorrow with a 4:00 PM alert, synced to iPhone via iCloud.

---

## 1. Architecture

Three machines, all on the same Tailscale tailnet:

```
┌──────────────────────────┐        ┌──────────────────────────┐        ┌──────────────────────┐
│  Mac hub (M2 MacBook Air)│        │  Brain (Linux home server│        │  DGX Spark (EdgeXpert)│
│  mac-agent (Swift)       │ HTTPS  │  — Surface Pro 8, Docker)│ OpenAI │  vLLM (existing)      │
│  • watches chat.db       │──────▶ │  brain (Python/FastAPI)  │──────▶ │  Qwen, OpenAI-compat  │
│  • EventKit read/write   │◀────── │  • ingest + extraction   │  API   │  /v1/chat/completions │
│  • heartbeat             │ long-  │  • SQLite event log      │        └──────────────────────┘
│                          │ poll   │  • dashboard (web)       │
└──────────────────────────┘        │  • IMAP IDLE (phase 5)   │
                                    │  • Discord alerts        │
                                    └──────────────────────────┘
```

Design rules:
- **The Spark only does inference.** No app services run on it. The brain calls the existing vLLM endpoint.
- **The brain does not run on the Mac.** If the Mac sleeps, the brain must still be up to notice the missing heartbeat and alert.
- **The Mac agent only makes outbound connections** (POST events, long-poll for commands, heartbeat). Nothing needs to reach into the Mac.
- **Swap-friendly:** the mac-agent is the only Mac-specific piece, so moving to a Mac mini later means copying one binary + plist.

---

## 2. Tech choices

| Component | Choice | Why |
|---|---|---|
| mac-agent | Swift, Swift Package Manager command-line executable, run by launchd | Native EventKit; Full Disk Access and Reminders/Calendar permissions attach cleanly to one signed binary (granting them to a Python interpreter is messy) |
| brain | Python 3.12, FastAPI, SQLite (via SQLModel or plain sqlite3), `httpx`, `imapclient` | Simple, easy to run in Docker |
| dashboard | Served by brain: Jinja2 + HTMX + Server-Sent Events for the live feed | No separate frontend build |
| LLM | Existing vLLM on the Spark, OpenAI-compatible API, structured output via `response_format: {type: "json_schema"}` | Guaranteed-valid JSON, no second "formatting" model |
| Alerts | Discord webhook | Already used for Hermes |
| Auth | Tailscale ACLs + a shared bearer token between mac-agent and brain | Defense in depth |

The developer has a paid Apple Developer account; sign the mac-agent binary with it so macOS privacy permissions persist across rebuilds.

---

## 3. Repo layout

```
household-agent/
├── PLAN.md
├── README.md
├── config.example.yaml
├── brain/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── pyproject.toml
│   ├── app/
│   │   ├── main.py            # FastAPI app, routes
│   │   ├── models.py          # DB tables
│   │   ├── schemas.py         # Pydantic: Event, Extraction, Action, Command
│   │   ├── gate.py            # rule-based prefilter
│   │   ├── extract.py         # LLM call with json_schema
│   │   ├── planner.py         # extraction → commands (apply rules/defaults)
│   │   ├── commands.py        # command queue for mac-agent
│   │   ├── heartbeat.py       # watchdog + Discord alerts
│   │   ├── mail.py            # IMAP IDLE listener (phase 5)
│   │   └── templates/         # dashboard pages
│   └── tests/
│       ├── fixtures/messages.jsonl   # golden set: input + expected output
│       └── test_*.py
└── mac-agent/
    ├── Package.swift
    ├── Sources/MacAgent/
    │   ├── main.swift
    │   ├── MessagesWatcher.swift     # chat.db reader + file watcher
    │   ├── AttributedBodyDecoder.swift
    │   ├── EventKitService.swift     # reminders + calendar
    │   ├── BrainClient.swift         # POST events, long-poll commands, heartbeat
    │   └── Checkpoint.swift          # last processed ROWID
    ├── Tests/
    └── launchd/com.household.mac-agent.plist
```

---

## 4. Data contracts

### 4.1 Event (mac-agent → brain, `POST /api/events`)
```json
{
  "event_id": "imessage:48213",
  "source": "imessage",
  "sender_handle": "+17855550000",
  "sender_label": "Wife",
  "chat_id": "iMessage;-;+17855550000",
  "received_at": "2026-11-19T16:52:00-06:00",
  "text": "Can you grab eggs tomorrow? We're out",
  "recent_context": ["Me: heading home soon", "Wife: ok"]
}
```
`event_id` is the idempotency key. The brain must ignore duplicates.

### 4.2 Extraction (LLM output, enforced by JSON schema)
```json
{
  "actionable": true,
  "actions": [
    {
      "type": "create_reminder",
      "title": "Pick up eggs",
      "list": "Groceries",
      "due_date": "2026-11-20",
      "due_time": null,
      "notes": null,
      "source_quote": "grab eggs tomorrow"
    }
  ],
  "confidence": 0.94,
  "reasoning_brief": "Request to buy eggs; 'tomorrow' relative to Thu Nov 19."
}
```
Action types (v1): `create_reminder`, `create_event`. Event actions carry `start`, `end`, `all_day`, `location`, `calendar`. Keep the schema small and flat. Every field required, nullable where optional (better for constrained decoding).

### 4.3 Command (brain → mac-agent, via `GET /api/agent/commands?wait=30`)
```json
{
  "command_id": "cmd_01J...",
  "event_id": "imessage:48213",
  "op": "create_reminder",
  "payload": {
    "title": "Pick up eggs",
    "list": "Groceries",
    "due": "2026-11-20",
    "alert": "2026-11-20T16:00:00-06:00",
    "notes": "From Wife: \"Can you grab eggs tomorrow? We're out\"\n[ha:imessage:48213]"
  }
}
```
Ops: `create_reminder`, `create_event`, `delete_item` (undo). The mac-agent reports results to `POST /api/agent/commands/{id}/result` with `{status, apple_item_id, error}`. Store `apple_item_id` (EventKit `calendarItemIdentifier`) so undo can delete it.

### 4.4 Heartbeat (`POST /api/agent/heartbeat`, every 60 s)
`{agent_version, last_rowid, fda_ok, reminders_ok, calendar_ok, uptime_s}`

---

## 5. Processing pipeline (brain)

1. **Ingest**: validate, dedupe on `event_id`, store row `status=received`.
2. **Allowlist**: only process senders/chats listed in config. Everything else is dropped without being stored (privacy).
3. **Gate (rules, no LLM)**: skip and log `status=skipped, reason=...` for tapbacks ("Loved “…”"), emoji-only, ≤3 chars, "ok/lol/k/👍", messages from me (unless config allows self-notes).
4. **Extract**: call vLLM with system prompt + current local datetime + weekday + timezone (America/Chicago) + recent context + the message. Use `response_format` json_schema; temperature 0; disable model "thinking" output if the model supports it (make it a config flag). Timeout + 1 retry.
5. **Plan**: apply rules from config:
   - default reminder alert time when none given (e.g. 16:00)
   - list routing by keyword (groceries → "Groceries", else "Household")
   - "tonight" → today 18:00, "this weekend" → Saturday, etc. (let the model resolve dates; validate they are not in the past)
   - **confidence < threshold (e.g. 0.75) → `status=needs_review`** instead of auto-creating; send Discord message with approve/reject link to the dashboard.
6. **Queue commands** for the mac-agent; mark `status=queued`.
7. **Result**: on mac-agent result, mark `status=done` or `failed` with error.

Every step writes to the event log so the dashboard can show the full trace: raw text → gate decision → prompt → raw model output → parsed extraction → commands → results, with timings.

---

## 6. mac-agent details

### Messages watcher
- Open `~/Library/Messages/chat.db` **read-only** (`?mode=ro` URI, with `immutable=0` so WAL changes are visible). Requires Full Disk Access for the agent binary.
- Watch `chat.db` and `chat.db-wal` with `DispatchSource.makeFileSystemObjectSource` (or FSEvents). On change, debounce ~500 ms, then query `message.ROWID > last_rowid`, join `handle` (sender) and `chat_message_join`/`chat` (chat id). Also run a safety poll every 60 s in case a file event is missed.
- Convert `message.date` (nanoseconds since 2001-01-01 UTC) to ISO-8601.
- **Text decoding:** if `message.text` is NULL, decode `message.attributedBody` (typedstream-archived `NSAttributedString`; `NSUnarchiver` can decode it in Swift). Write unit tests with captured blobs.
- Pull the previous ~5 messages in the same chat as `recent_context`.
- Persist `last_rowid` to `~/Library/Application Support/HouseholdAgent/state.json` only after the brain returns 2xx. On first run, start from the current max ROWID (do NOT backfill history) unless `--backfill N` is passed.
- If the brain is unreachable, buffer events to a local file queue and retry with backoff.

### EventKit
- Request Reminders + Calendar full access on first run (`requestFullAccessToReminders`, `requestFullAccessToEvents`).
- `create_reminder`: find the list by name (create it if missing, configurable), set title, notes, `dueDateComponents`, and an `EKAlarm` at the alert time.
- `create_event`: find the calendar by name, create the `EKEvent`.
- `delete_item`: look up by `calendarItemIdentifier` and remove.
- Idempotency: before creating, search for an existing item whose notes contain the `[ha:<event_id>]` tag; if found, return it instead of creating a duplicate.

### Process
- launchd LaunchAgent (`~/Library/LaunchAgents/`) with `RunAtLoad` + `KeepAlive`, logs to `~/Library/Logs/HouseholdAgent/`.
- Config: brain URL (Tailscale MagicDNS name), bearer token (read from Keychain), allowlisted handles are enforced on the brain side but the agent may pre-filter too.

---

## 7. Dashboard (brain, over Tailscale)

- **Live feed**: newest events first, streamed via SSE. Each row: time, source, sender, snippet, outcome badge (created / skipped / needs review / failed).
- **Event detail**: full trace (Section 5) including the exact prompt and raw model response.
- **Actions**: Undo (queues `delete_item`), Retry (re-runs extraction), Approve/Reject for `needs_review`, "Reprocess with edits" (edit the extraction JSON and send).
- **Health panel**: mac-agent last heartbeat, permission flags, last ROWID, queue depth, vLLM reachability + latency, mail listener status.
- **Stats**: events/day, % actionable, avg extraction latency, failure count.
- Mobile-friendly layout (it will mostly be checked from an iPhone).

---

## 8. Watchdog & alerts

- No heartbeat for 3 minutes → Discord alert "Mac agent offline" (once, then again on recovery).
- Any permission flag false → alert.
- vLLM unreachable for 3 consecutive calls → alert; events stay `received` and are retried when it's back.
- `needs_review` items → Discord message with dashboard link.

---

## 9. Configuration (`config.yaml`)

```yaml
timezone: America/Chicago
llm:
  base_url: http://<spark-tailnet-name>:8000/v1
  model: <served model name>
  temperature: 0
  disable_thinking: true
  timeout_s: 30
watch:
  imessage:
    allow:
      - handle: "+1785555XXXX"
        label: Wife
  mail:
    enabled: false
    host: imap.example.com
    username: ...
    folders: [INBOX]
    allow_senders: ["*@school.example.org"]
rules:
  default_alert_time: "16:00"
  review_threshold: 0.75
  lists:
    default: Household
    routes:
      - match: [eggs, milk, bread, groceries, store]
        list: Groceries
  calendars:
    default: Family
alerts:
  discord_webhook_url: ...
security:
  agent_token: ...   # mac-agent reads its copy from Keychain
```

---

## 10. Build phases

Build and verify each phase before moving on.

**Phase 0 — Scaffold**
- Repo layout, config loading, Docker setup for brain, Swift package for mac-agent, README with setup steps.
- ✅ `docker compose up` serves an empty dashboard; `swift build` succeeds.

**Phase 1 — Brain extraction (no Mac yet)**
- Event ingest API, SQLite log, allowlist, gate, extraction against vLLM with json_schema, planner, dashboard feed + detail page.
- Golden set `tests/fixtures/messages.jsonl` with ≥30 cases: groceries, relative dates (tomorrow / tonight / Friday / next week / this weekend), pickups and appointments (→ events), multi-item asks, cancellations, chit-chat that must be skipped, questions that aren't tasks. Each case pins a fixed "now" timestamp.
- `make eval` runs the golden set against the live model and prints pass/fail per case.
- ✅ ≥90% of golden cases correct; dashboard shows full traces for a curl-posted event.

**Phase 2 — mac-agent read path**
- Messages watcher, attributedBody decoding, checkpointing, POST events, heartbeat, offline buffer, launchd plist.
- ✅ A real text from an allowlisted contact shows up in the dashboard within ~5 seconds; non-allowlisted texts never appear; killing the agent triggers a Discord alert within 3 minutes.

**Phase 3 — Write path (Reminders)**
- Command queue + long-poll, EventKit reminder creation, result reporting, idempotency tag, Undo.
- ✅ "grab eggs tomorrow" from the allowlisted contact produces the correct reminder on the iPhone; Undo removes it; re-sending the same event creates no duplicate.

**Phase 4 — Calendar + review flow**
- `create_event`, needs_review state, approve/reject/edit in dashboard, Discord review alerts.
- ✅ "dentist moved to Tuesday at 3:30" creates a calendar event; a low-confidence message waits for approval.

**Phase 5 — Mail**
- IMAP IDLE listener on the brain (reconnect on drop), sender allowlist, strip quoted replies/signatures, same pipeline with `source: "mail"`.
- ✅ An email from an allowlisted sender becomes a reminder or event.

**Phase 6 — Hardening**
- Mac setup script: `sudo pmset -a sleep 0 disksleep 0`, `pmset -a disablesleep 1` (lid-closed operation on power), document battery charge limiting, auto-login + agent at login.
- Log rotation, DB backups (nightly SQLite `.backup`), version shown in health panel.
- ✅ Mac runs lid-closed for 72 hours with no missed heartbeats.

**Phase 7 (optional) — Notes / extras**
- Read-only Apple Notes via AppleScript (`osascript`) for context (e.g. a "Household" note).
- Nightly digest: tomorrow's reminders + events summarized to Discord.

---

## 11. Non-goals (v1)

- No replying to or sending iMessages.
- No processing of non-allowlisted conversations, ever.
- No cloud LLM calls; all inference stays on the Spark.
- No changes to the Spark's existing vLLM setup.

## 12. Notes for the implementer

- Ask before choosing between equally valid options that affect setup (e.g. which Linux host runs the brain, exact list/calendar names).
- Never commit secrets; `config.yaml` is gitignored, `config.example.yaml` is committed.
- Keep the LLM prompt in its own file (`brain/app/prompts/extract.md`) so it can be tuned without code changes, and record the prompt version on every event row.
