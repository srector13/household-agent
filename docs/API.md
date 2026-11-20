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
  "tag": "[ha:imessage:48213]"
}
```

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
  "tag": "[ha:imessage:48300]"
}
```

`delete_item`
```json
{"apple_item_id": "x-apple-...", "kind": "reminder" | "event"}
```

Idempotency: before `create_*`, search the target (all reminder lists / calendars ±1 year
around `start` or `due`) for an item whose notes contain `tag`. If found, report it as
`done` with its identifier instead of creating a duplicate. Deleting an item that no
longer exists is reported as `done`.

## POST /api/agent/commands/{command_id}/result

```json
{"status": "done" | "failed", "apple_item_id": "x-apple-..." , "error": null}
```
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
  "buffered_events": 0
}
```
Response `200 {"ok": true}`.

## Dashboard / debugging (no agent token; protect with Tailscale)

- `GET /` live feed, `GET /events/{event_id}` trace, `GET /health`, `GET /stats`
- `GET /api/health` JSON health summary
- `GET /api/stream` Server-Sent Events (`data: {"event_id": "..."}` on every change)
- `POST /api/events?sync=true` (with the agent token) processes the event before
  responding and returns the final status — handy for `curl` testing.
