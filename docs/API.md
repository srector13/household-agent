# Brain ↔ mac-agent API contract

All agent endpoints require `Authorization: Bearer <agent_token>`. Bodies are JSON
(`Content-Type: application/json`). Times are ISO-8601 with a UTC offset
(e.g. `2026-11-19T16:52:00-06:00`). Unknown fields must be ignored by both sides.

## POST /api/events

Submit one inbound message. `event_id` is the idempotency key.

```json
{
  "event_id": "imessage:48213",
  "source": "imessage",
  "sender_handle": "+17855550000",
  "sender_label": "Wife",
  "chat_id": "iMessage;-;+17855550000",
  "is_from_me": false,
  "received_at": "2026-11-19T16:52:00-06:00",
  "text": "Can you grab eggs tomorrow? We're out",
  "recent_context": ["Me: heading home soon", "Wife: ok"]
}
```

- `sender_label` is optional; the brain overrides it from its allowlist.
- `is_from_me` is optional (default `false`). For messages the user sent, the agent
  sets `sender_handle` to the other party's handle (what chat.db `handle_id` points
  at) and `is_from_me: true`.
- `recent_context`: up to ~5 previous messages in the same chat, oldest first,
  each prefixed `"Me: "` or `"<label or handle>: "`.

Response `200`:
```json
{"status": "accepted" | "duplicate" | "ignored", "event_id": "imessage:48213"}
```
`ignored` = not allowlisted (nothing stored). Any `2xx` means "consumed — advance the
checkpoint". `401` = bad token. `422` = malformed (the agent should log it and skip the
event, not retry forever). `5xx`/network error = retry later.

## GET /api/agent/commands?wait=30

Long-poll for work. Returns as soon as at least one command is available, or after
`wait` seconds (max 55) with an empty list.

```json
{"commands": [
  {
    "command_id": "cmd_01JD...",
    "event_id": "imessage:48213",
    "op": "create_reminder",
    "payload": { ... }
  }
]}
```

A delivered command is leased for 5 minutes; if no result arrives it is delivered again
(up to 5 times, then it is marked failed). The agent must therefore be idempotent (see the
`tag` field), and must execute commands **sequentially in the order returned** — a retry or
edit queues `delete_item` for the old item before the `create_*` that replaces it.

### Payloads

`create_reminder`
```json
{
  "title": "Pick up eggs",
  "list": "Groceries",
  "create_list_if_missing": true,
  "due": "2026-11-20",            // YYYY-MM-DD or null
  "due_time": null,               // "HH:MM" local or null (date-only due)
  "alert": "2026-11-20T16:00:00-06:00",  // or null = no alarm
  "notes": "From Wife: \"Can you grab eggs tomorrow? We're out\"\n[ha:imessage:48213]",
  "tag": "[ha:imessage:48213]",
  "url": null,                    // optional link, set as the item's URL (e.g. a gift idea's product page)
  "section": "Sarah",             // optional: section in `list` (a column in Reminders' column view), created if missing
  "tags": ["Sarah"],              // optional: hashtags without '#', letters/digits only
  "title_fallback": "Sarah · Kindle Paperwhite"  // optional: title used when section/tags can't be applied
}
```
`section` and `tags` need Apple's **private** ReminderKit framework (EventKit has no API for
either). The agent checks once at startup whether the needed classes/selectors exist. If they
don't, or `use_reminderkit` is false in the agent config, it creates the reminder with
`title_fallback` as its title instead. If applying fails after the reminder was created, it
renames the reminder to `title_fallback`. Either way the result is `done` with a `warning`.
`list` may be any name, including emoji and a person's name (e.g. `"🎁 Gifts for Sarah"`); it is
matched in canonical Unicode form (then case-insensitively) and created when missing if
`create_list_if_missing` is true.

`create_event`
```json
{
  "title": "Dentist",
  "calendar": "Family",
  "start": "2026-11-24T15:30:00-06:00",
  "end": "2026-11-24T16:30:00-06:00",
  "all_day": false,               // when true, use the local date parts of start/end; end is inclusive
  "location": null,
  "alert_minutes_before": 30,     // or null
  "notes": "From Wife: \"...\"\n[ha:imessage:48300]",
  "tag": "[ha:imessage:48300]",
  "url": null                     // optional
}
```

`update_item` (agent ≥ 0.3.0)
```json
{
  "apple_item_id": "x-apple-..." | null,
  "tag": "[ha:imessage:48213]",
  "kind": "reminder" | "event",
  "changes": {                    // only keys PRESENT are applied; explicit null clears the field
    "title": "Pick up eggs",
    "due": "2026-11-22" | null,   // reminders: with due_time → dueDateComponents (date-only if due_time null/absent); null removes the due date
    "due_time": "HH:MM" | null,   // alone (no "due"): changes the time on the existing due day
    "alert": "2026-11-22T16:00:00-06:00" | null,  // reminders: replaces all alarms with one absolute alarm; null removes all
    "completed": true,            // reminders: isCompleted
    "start": "ISO8601", "end": "ISO8601", "all_day": true,  // events; moving start without end keeps the length; relative alarms untouched
    "location": "..." | null,
    "url": "..." | null
  },
  "notes_append": "Updated from Me: \"I'll do it tomorrow\"" | null   // appended on a new line; [ha:] tag lines stay last
}
```
Lookup: by `apple_item_id`; if null or not found, by `tag` (same search as idempotency). Not found →
`failed` with error `"item not found"`. Malformed dates → `failed` before anything is changed.
Success → `done` with the item's identifier.

`delete_item`
```json
{"apple_item_id": "x-apple-..." | null, "kind": "reminder" | "event" | null, "tag": "[ha:imessage:48213]"}
```
`tag` is optional. If `apple_item_id` is null or not found and a tag is given, the item with that tag is
deleted (both kinds are searched when `kind` is null). The brain may send a null id with a tag when the
create has not reported back yet — commands run in order, so the create has already executed.

Idempotency: before `create_*`, search the target (all reminder lists / calendars ±1 year
around `start` or `due`) for an item whose notes contain `tag`. If found, report it as
`done` with its identifier instead of creating a duplicate. Deleting an item that no
longer exists is reported as `done`.

## POST /api/agent/commands/{command_id}/result

```json
{"status": "done" | "failed", "apple_item_id": "x-apple-..." , "error": null, "warning": null}
```
`warning` is set when the item was created but something optional didn't work, e.g.
`"ReminderKit unavailable — used title fallback"`. The status is still `done`.
`apple_item_id` = EventKit `calendarItemIdentifier`. Response `200 {"ok": true}`.
`404` = unknown command (drop it).

## POST /api/agent/heartbeat (every 60 s)

```json
{
  "agent_version": "0.1.0",
  "last_rowid": 48213,
  "fda_ok": true,
  "reminders_ok": true,
  "calendar_ok": true,
  "uptime_s": 3600,
  "buffered_events": 0,
  "allowlist_version": 7,
  "allowlist_size": 3,
  "reminderkit_ok": true,
  "contacts_ok": true
}
```
- `allowlist_version`: `settings_version` of the allowlist the agent is filtering with, or
  `null` when it has never synced one (or sync is off).
- `allowlist_size`: number of handles + chat ids in the active prefilter.
- `reminderkit_ok`: `true` = sections + tags work on this Mac (private ReminderKit), `false` = not
  available (title fallback in use), `null` = not probed yet.
- `contacts_ok`: Contacts access granted (optional; only used for contact photos). Agents
  before 0.6.0 omit it.

Response `200 {"ok": true, "settings_version": 7}`. When `settings_version` differs from the
agent's cached `allowlist_version`, the agent refetches `GET /api/agent/config`.

## GET /api/agent/config

The brain-managed iMessage allowlist (edited on the dashboard's Settings page). The agent fetches
it at startup, whenever the heartbeat reports a new `settings_version`, and every ~10 minutes as a
fallback, and caches it in `synced_config.json` so it keeps filtering while the brain is down.

```json
{
  "settings_version": 7,
  "allow": {
    "handles": ["+17855550000", "someone@icloud.com"],
    "chat_ids": ["iMessage;+;chat123456"]
  },
  "allow_self_notes": false
}
```

- Handles are normalized: emails lowercased; phone numbers `"+"` + digits, a 10-digit US number
  prefixed with `1`. The agent normalizes chat.db handles the same way before comparing.
- A message matches if its normalized handle is in `handles`, or its chat GUID or
  `chat_identifier` is in `chat_ids`. For `is_from_me` messages the handle is the other party's
  (or the chat identifier in group chats).
- The agent filters **at send time** (when draining its outbox) as well as at scan time, so
  list changes apply to events already buffered. Until a list has been synced at least once, the
  agent holds events instead of sending or dropping them. Events that don't match are dropped
  locally and the checkpoint moves past them; only the ROWID is logged.
- A `404` (brain that predates this endpoint) makes the agent fall back to its local
  `allow_handles` until the endpoint appears.

## GET /api/agent/tracked  (completion sync)

The open items the brain wants status for (≤500), plus how often to ask again.

```json
{"items": [{"apple_item_id": "x-apple-...", "kind": "reminder", "tag": "[ha:imessage:1]"}],
 "interval_s": 300}
```

The agent syncs ~30 s after startup, then every `interval_s` (clamped 60–3600, default 300), and
also 5 s after it executes commands (debounced; a burst can delay it by at most 30 s). Runs never
overlap. A `404` means the brain predates completion sync: the agent stops asking until it restarts.
Network errors just wait for the next interval.

## POST /api/agent/item-status

Batches of ≤200:

```json
{"items": [{"apple_item_id": "x-apple-...", "kind": "reminder", "exists": true,
            "completed": true, "completed_at": "2026-11-21T09:12:00-06:00",
            "title": "Pick up eggs", "due": "2026-11-21", "due_time": null,
            "start": null, "end": null}]}
```

- Lookup is by `apple_item_id`; if that fails the agent searches once by `tag`, and if found under a
  different identifier reports it under the ORIGINAL `apple_item_id` with `"found_id": "<new id>"`.
- `exists: false` is sent only when the agent could definitely have seen the item (store loaded,
  full access for that kind, neither lookup found it). Missing permission or a store error → the
  item is left out of the batch, never reported as missing.
- `completed`/`completed_at`/`due`/`due_time` are for reminders (null for events);
  `start`/`end` for events. Unset values are explicit `null`; `found_id` is omitted when unused.

Response `200 {"ok": true, "updated": n}`.

## POST /api/agent/snapshot  (full calendar picture, agent ≥ 0.6.0)

Everything on the user's calendars and reminder lists for the coming days — not only items the
brain created — so the app can show a complete "Up next" / "Coming up". Sent after every
completion-sync run that reached the brain (same cadence, including the debounced run after
commands); replaces the brain's previous snapshot.

```json
{"generated_at": "2026-11-22T08:00:00-06:00", "range_days": 7,
 "events": [{"id": "x-apple-...", "title": "Dentist", "start": "2026-11-24T09:00:00-06:00",
             "end": "2026-11-24T10:00:00-06:00", "all_day": false, "calendar": "Family",
             "calendar_color": "#FF2D55", "location": null, "ours": false}],
 "reminders": [{"id": "x-apple-...", "title": "Pick up eggs", "list": "Groceries",
                "list_color": "#34C759", "due": "2026-11-22", "due_time": "17:00",
                "priority": 0, "ours": true}]}
```

- `events`: all calendars, from now − 2 h to now + `range_days`, recurring events expanded into
  occurrences, canceled events skipped, sorted by `start`, ≤400. Occurrences of a recurring event
  share an Apple identifier, so their `id` is `"<calendarItemIdentifier>/<start>"`; one-off events
  use the plain identifier.
- `reminders`: incomplete reminders with a due date from now − 30 days (overdue) to now +
  `range_days`; reminders without a due date are not sent. Sorted by due, ≤400. `due_time` is
  `null` for date-only reminders; `priority` is EventKit's 0 (none) / 1–9 (1 = high).
- `ours`: the item's notes contain a `[ha:` tag (created by Second Brain).
- Times are ISO 8601 with the Mac's local offset; colors are `#RRGGBB` (best effort, else `null`).
- A kind the agent cannot read (no permission, store not loaded) is sent as `null` = "keep what
  you had", never `[]`. If neither is readable nothing is posted.
- A `404` turns snapshots off until the agent restarts; other errors retry next run.

Response `200 {"ok": true}`.

## POST /api/agent/avatars  (contact photos, agent ≥ 0.6.0)

Names and photos from the Mac's Contacts for the synced allowlist `handles` (chat ids are not
included). Nothing else from Contacts is read or sent.

```json
{"people": [{"handle": "+17855550000", "name": "Sam Rivera",
             "image": "<base64 JPEG>", "image_hash": "3f78…(sha1 hex of the JPEG)"},
            {"handle": "someone@icloud.com", "name": null, "image": null, "image_hash": null}]}
```

- One entry per allowlisted handle (normalized as in `/api/agent/config`); no matching contact →
  `name`/`image`/`image_hash` are `null`. Matching: phone numbers normalized the same way, emails
  case-insensitively.
- `image`: the contact thumbnail (or the full photo downscaled), ≤256 px JPEG, ≤96 KB before base64;
  bigger → `null`.
- Sent when the allowlist changes, at startup once an allowlist is known, and every 24 h — but only
  if some handle, name or photo changed since the last successful post (the agent keeps a
  fingerprint in `avatars.json`). The full list is sent each time; it replaces the previous one.
- Without Contacts access the agent sends nothing (heartbeat `contacts_ok: false`). A `404` turns
  this off until the agent restarts.

Response `200 {"ok": true}`.

## Dashboard / debugging (no agent token; protect with Tailscale)

- `GET /` live feed, `GET /events/{event_id}` trace, `GET /health`, `GET /stats`
- `GET /api/health` JSON health summary
- `GET /api/stream` Server-Sent Events (`data: {"event_id": "..."}` on every change)
- `POST /api/events?sync=true` (with the agent token) processes the event before
  responding and returns the final status — handy for `curl` testing.
