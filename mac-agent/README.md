# mac-agent

The only Mac-specific piece of Second Brain (formerly Household Agent). A small signed Swift command-line tool, run by
launchd, that:

- watches `~/Library/Messages/chat.db` (read-only) and POSTs new messages to the brain,
- long-polls the brain for commands and applies them to Reminders / Calendar via EventKit,
- sends a heartbeat every 60 s (version, last ROWID, permission flags, outbox depth),
- sends the brain a snapshot of the next week of calendar events + due reminders (all lists, not
  just its own) and the Contacts names/photos of the people it watches,
- optionally files reminders into list sections (column view) and #tags them via Apple's private
  ReminderKit, falling back to a "Person · Title" title when that isn't possible.

It only makes **outbound** connections. The wire contract is in [`../docs/API.md`](../docs/API.md).

## Layout

```
Package.swift
Sources/MacAgent/main.swift            CLI entry point (+ Info.plist embedded in the binary)
Sources/MacAgentCore/
  Agent.swift                 orchestrator: scan → outbox → brain, command loop, heartbeat, allowlist sync
  Allowlist.swift             brain-synced allowlist, handle normalization, /api/agent/config types
  MessagesDatabase.swift      chat.db queries + EventBuilder (rows → events, recent_context)
  AttributedBodyDecoder.swift typedstream NSAttributedString → text (pure Swift)
  FileWatcher.swift           DispatchSource on chat.db and chat.db-wal (500 ms debounce in Agent)
  EventKitService.swift       reminders / events / update / delete, tag-based idempotency
  ItemStore.swift             EventKit abstraction + CommandExecutor
  ReminderOrganizer.swift     sections + #tags abstraction (title fallback when unavailable)
  ReminderKitOrganizer.swift  ReminderKit backend: serial queue, timeout, cached availability
  BrainClient.swift           HTTP client (bearer token)
  OfflineBuffer.swift         durable JSONL outbox
  Checkpoint.swift            state.json (last ROWID)
  Config.swift, Keychain.swift, Logger.swift, AppleDate.swift, Models.swift, Wakeup.swift
Sources/CReminderKit/         Objective-C bridge to the private ReminderKit framework (macOS only)
Tests/MacAgentCoreTests/      unit tests (decoder, dates, payloads, outbox, checkpoint, chat.db fixtures)
launchd/com.household.mac-agent.plist
scripts/install.sh  uninstall.sh  setup-mac-power.sh  entitlements.plist
```

## Requirements

- macOS 14 Sonoma or later (uses `requestFullAccessToReminders` / `requestFullAccessToEvents`)
- Xcode 15+ or the Swift 5.9+ command-line tools
- An Apple Developer signing identity (strongly recommended, see below)

## Build & test

```sh
cd mac-agent
swift build
swift test
```

The core logic also builds and tests on Linux (EventKit/Keychain/file-watching are compiled out),
which is how CI-style checks can run off-Mac.

## Install

```sh
security find-identity -v -p codesigning        # pick your "Developer ID Application" or "Apple Development" identity
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BRAIN_URL="http://brain.your-tailnet.ts.net:8080" \
HA_AGENT_TOKEN="<the brain's security.agent_token>" \
./scripts/install.sh
```

This builds a release binary, signs it with the hardened runtime and the Calendar entitlement,
installs it at `~/Library/Application Support/HouseholdAgent/bin/mac-agent`, writes a default
`config.json` if none exists, stores the token in the login Keychain, and loads the LaunchAgent
`com.household.mac-agent` (`RunAtLoad` + `KeepAlive`).

**Why signing matters:** macOS privacy grants (Full Disk Access, Reminders, Calendars) are tied to
the binary's code-signing identity. With a stable Developer identity and the fixed identifier
`com.household.mac-agent`, grants survive rebuilds. Ad-hoc signed builds may be treated as a new app
after every rebuild.

### Permissions (one time)

1. **Full Disk Access** (to read chat.db): System Settings → Privacy & Security → Full Disk Access →
   `+` → ⌘⇧G → paste `~/Library/Application Support/HouseholdAgent/bin/mac-agent` → enable. Then
   `launchctl kickstart -k gui/$(id -u)/com.household.mac-agent`.
2. **Reminders + Calendars**: the agent requests full access on start; approve the prompts.
   To trigger them by hand (and print the status of all three permissions):
   ```sh
   "$HOME/Library/Application Support/HouseholdAgent/bin/mac-agent" --request-permissions
   ```
   Note: when run from Terminal, macOS may attribute the request to Terminal rather than the agent.
   The launchd-started agent is what needs the grant — check System Settings → Privacy & Security →
   Reminders / Calendars lists "Household Agent" / `mac-agent` and that the health panel on the
   dashboard shows `reminders_ok` and `calendar_ok`.

3. **Contacts** (optional): only used to send the watched people's names and photos to the
   brain. The agent asks on start (and `--request-permissions` asks too); without it photos are off
   and the heartbeat shows `contacts_ok: false`.

Never grant Full Disk Access to Terminal or a Python interpreter for this — only to the agent binary.

## Configuration

`~/Library/Application Support/HouseholdAgent/config.json`:

```json
{
  "brain_url": "http://brain.your-tailnet.ts.net:8080",
  "keychain_service": "com.household.mac-agent",
  "keychain_account": "agent_token",
  "sync_allowlist": true,
  "labels": {"+17855550000": "Wife"},
  "context_count": 5,
  "log_level": "info"
}
```

| Key | Default | Meaning |
|---|---|---|
| `brain_url` | — (required) | Brain base URL (Tailscale MagicDNS name) |
| `keychain_service` / `keychain_account` | `com.household.mac-agent` / `agent_token` | Keychain item with the bearer token. `HA_AGENT_TOKEN` env is the fallback. |
| `sync_allowlist` | `true` | Use the iMessage allowlist from the brain (edited on the dashboard's Settings page) as the prefilter, so other conversations never leave the Mac. Synced at startup, whenever the heartbeat reports a new `settings_version`, and every 10 min; cached in `synced_config.json`. Until a first sync succeeds, new events are **held** in the outbox (not sent, not dropped). Buffered events are re-checked at send time, so removing someone also drops their undelivered messages. |
| `allow_handles` | `[]` | Only used when `sync_allowlist` is `false` (or the brain is too old to serve `/api/agent/config`): exact-match handles, chat identifiers or chat GUIDs. Empty = send everything and let the brain filter. |
| `labels` | `{}` | Handle → name for `sender_label` and `recent_context` prefixes |
| `context_count` | `5` | Previous messages in the same chat sent as `recent_context` |
| `log_level` | `info` | `debug`, `info`, `warn`, `error` |
| `chat_db_path` | Messages default | Point at a copy of chat.db for testing |
| `poll_interval_s` | `60` | Safety poll in case a file event is missed |
| `heartbeat_interval_s` | `60` | |
| `long_poll_wait_s` | `30` | `wait` for `GET /api/agent/commands` |
| `use_reminderkit` | `true` | Put reminders into list **sections** (Reminders' column view) and add **#tags** using Apple's private ReminderKit framework (see below). `false` = always use the brain's title fallback (e.g. "Sarah · Kindle Paperwhite"). |
| `use_nsunarchiver_fallback` | `false` | Also try `NSUnarchiver` when the pure-Swift decoder fails. Off by default: malformed blobs can raise an uncatchable Objective-C exception, which under `KeepAlive` would crash-loop on the same row. |

To store or rotate the token by hand:

```sh
security add-generic-password -U -s com.household.mac-agent -a agent_token -w '<token>'
```

## How it works

- **Reading:** chat.db is opened with `file:…?mode=ro` (never written). A long-lived read connection
  sees WAL commits. File events on `chat.db` / `chat.db-wal` trigger a scan after a 500 ms debounce;
  a 60 s safety poll covers missed events. Each scan reads `message.ROWID > last` joined with `handle`
  and `chat`, skips tapbacks/reactions (`associated_message_type != 0`), non-text items, empty bodies
  and chats not on the allowlist synced from the brain. `text` falls back to decoding `attributedBody`.
- **Delivery:** every event goes through `outbox.jsonl` (append → POST → pop), so a brain outage
  or crash never loses a message and delivery stays in ROWID order. `state.json` keeps
  `last_rowid` (acknowledged by the brain with a 2xx, or deliberately skipped) and
  `last_scanned_rowid` (read and buffered). `422` from the brain is logged and skipped;
  `401` and `5xx`/network errors keep the event buffered and retry with exponential backoff.
- **First run** starts after the current max ROWID — no history is sent. `--backfill N` resends
  the last N messages (the brain dedupes on `event_id`).
- **Commands:** `create_reminder`, `create_event`, `update_item`, `delete_item` (see
  [`../docs/API.md`](../docs/API.md)). Before creating, the agent searches for an item whose notes
  contain the payload `tag` (`[ha:<event_id>]`) and returns that instead of creating a duplicate, so
  re-delivered commands are safe. `update_item` (change the date, title, alert, mark completed, append a
  note) and `delete_item` find the item by its identifier, falling back to the tag. Deleting an item that
  is already gone is reported as `done`; updating one that can't be found is `failed`. Creates may carry
  a `url` (shown on the reminder/event), and list names may include emoji and people's names.
- **Sections + tags:** a `create_reminder` may carry `section` (e.g. the person's name, so column
  view shows one column per person) and `tags` (`#Sarah`). EventKit can't do either, so the agent
  creates the reminder with EventKit as usual and then applies section + tags through Apple's
  **private** ReminderKit framework (see "ReminderKit" below). If ReminderKit is unavailable, the
  reminder is created with the brain's `title_fallback` ("Sarah · Kindle Paperwhite"). If applying
  fails afterwards, it is renamed to that title. Either way the result is `done` with a `warning`,
  which the brain shows on the dashboard.
- `sender_handle` for messages you sent (`is_from_me: true`) is the other party's handle in 1:1 chats
  and the chat identifier in group chats.

## CLI

```
mac-agent [--config PATH] [--backfill N] [--once] [--request-permissions] [--version]
mac-agent --probe-reminderkit [--write [--list NAME] [--keep]]
```

`--once` does a single scan / delivery / command poll (`wait=0`) / heartbeat and exits — handy with
`log_level: debug` when setting up.

## Completion sync

So the brain knows when you tick off, edit or delete one of its reminders on the iPhone, the agent
periodically asks the brain which items it is tracking (`GET /api/agent/tracked`), looks each one
up in EventKit and reports back (`POST /api/agent/item-status`): completed + when, current title,
due date/time (reminders) or start/end (events), or that it no longer exists. Timing: ~30 s after
start, then every few minutes (the brain decides), and a few seconds after the agent runs commands.
The agent only says an item is gone when it is sure (store loaded, full access); permission problems
or EventKit errors just leave the item out. Older brains without these endpoints turn the feature off.
`--once` also runs one sync.

## Calendar snapshot & contact photos

Right after each completion sync the agent also posts `POST /api/agent/snapshot`: every event on
all calendars from 2 h ago to 7 days ahead (recurring ones expanded, canceled skipped) and every
incomplete reminder due between 30 days ago and 7 days ahead, ≤400 each, with calendar/list names
and colors and an `ours` flag for Second Brain's own items. A kind it can't read is sent as `null`
so the brain keeps its last copy.

For the people on the synced allowlist it posts `POST /api/agent/avatars` (name + ≤256 px JPEG
thumbnail per handle) after the allowlist changes, at startup and daily — only when something
changed (fingerprint in `avatars.json`). Older brains without these endpoints turn them off.

## ReminderKit (sections + tags)

Apple's public Reminders API (EventKit) can't put a reminder into a section or tag it. The agent
uses the private `ReminderKit.framework` for that, through a small Objective-C bridge
(`Sources/CReminderKit/HAReminderKit.m`). **This is unsupported, undocumented API.** It is based on
public reverse-engineering notes from other projects, reported working on recent macOS (14–26),
but it has never been run on this project's build machine. A macOS update can break it at any
time. The bridge is written so that breaking can't crash the agent:

- ReminderKit is loaded with `dlopen` and every class and selector is checked before use. Every
  call is wrapped in `@try/@catch`, runs on its own queue and has a 20 s timeout. A timeout
  switches ReminderKit off until the next restart.
- Whenever it isn't available, reminders still get created, titled with the brain's fallback
  ("Sarah · Kindle Paperwhite"), and the heartbeat reports `reminderkit_ok: false`.
- Set `"use_reminderkit": false` in config.json to switch it off entirely.

Check it on your Mac:

```sh
BIN="$HOME/Library/Application Support/HouseholdAgent/bin/mac-agent"
"$BIN" --probe-reminderkit                 # which classes/selectors exist (read-only)
"$BIN" --probe-reminderkit --write         # create a test reminder in "Second Brain probe" with
                                           # section "Probe" + #haprobe, read it back, delete it
"$BIN" --probe-reminderkit --write --keep  # same, but keep it so you can look at View → as Columns
```

**Crash guard.** A private method whose signature changed in a macOS update can crash the agent
outright (an ObjC exception would be caught; a bad call can't be). Each ReminderKit call is
bracketed by `~/Library/Application Support/HouseholdAgent/reminderkit.inflight`. If the agent
starts and finds that file, the last run died inside ReminderKit, so it leaves sections and tags
off and uses the "Person · Title" fallback. The System page shows "unavailable". Once
`--probe-reminderkit --write` passes, it deletes the file; restart the agent to turn them back on.


`--write` needs Reminders access for the binary, the same as the agent. A `RESULT: sections + tags
work on this Mac` line means it's good to go. Some macOS versions don't expose a way to read a
section back, so the probe may report the section as "not readable". In that case, check the
list in column view with `--keep`.

## Files & logs

| Path | |
|---|---|
| `~/Library/Application Support/HouseholdAgent/config.json` | config |
| `~/Library/Application Support/HouseholdAgent/state.json` | checkpoint |
| `~/Library/Application Support/HouseholdAgent/outbox.jsonl` | undelivered events |
| `~/Library/Application Support/HouseholdAgent/synced_config.json` | last allowlist synced from the brain |
| `~/Library/Application Support/HouseholdAgent/avatars.json` | fingerprint of the last contact photos sent |
| `~/Library/Logs/HouseholdAgent/agent.log` | main log, rotated at 5 MB (`agent.log.1`–`.3`) |
| `~/Library/Logs/HouseholdAgent/stderr.log` | launchd stderr (crashes only) |

```sh
tail -f ~/Library/Logs/HouseholdAgent/agent.log
launchctl print gui/$(id -u)/com.household.mac-agent | head -30
launchctl kickstart -k gui/$(id -u)/com.household.mac-agent   # restart
```

## Always-on hub (Phase 6)

`./scripts/setup-mac-power.sh` disables system/disk sleep and enables lid-closed operation
(`pmset -a sleep 0 disksleep 0`, `pmset -a disablesleep 1`) and prints the manual steps for battery
charge limiting, automatic login and update settings.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Log: `cannot read …/chat.db — grant Full Disk Access` / dashboard `fda_ok: false` | Grant FDA to the **installed binary** path, then kickstart. Re-grant if you changed the signing identity. |
| `reminders_ok` / `calendar_ok` false | Approve in System Settings → Privacy & Security → Reminders / Calendars; run `--request-permissions`. |
| `no agent token` and exit 78 | Store the token in the Keychain (see above) or set `HA_AGENT_TOKEN`. |
| `brain rejected the agent token (401/403)` | Token mismatch with the brain's `security.agent_token`. |
| `brain unreachable … event(s) buffered` | Brain down or Tailscale disconnected; events are kept in `outbox.jsonl` and sent when it is back. |
| Texts show up in Messages but not the dashboard | Check the allowlist on the dashboard's Settings page and the agent's `allowlist_version` on the Health page (it should match the brain's settings version). The log says "holding N event(s) until the allowlist is synced" if the agent has never reached `/api/agent/config`. Run with `log_level: debug` to see per-ROWID skip reasons. |
| Messages from before install never appear | Expected — first run does not backfill. Use `--backfill N`. |
| Gift ideas etc. titled "Sarah · …" instead of sitting in a "Sarah" column / dashboard shows a ReminderKit warning | ReminderKit isn't working on this macOS (`reminderkit_ok: false`). Run `--probe-reminderkit` and see the log line "ReminderKit unavailable". Everything else keeps working. |
| Agent restarts repeatedly | `stderr.log`; `launchctl print gui/$(id -u)/com.household.mac-agent`. |

Uninstall: `./scripts/uninstall.sh` (add `--purge` to remove config/state/logs/token).
