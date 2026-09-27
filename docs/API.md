# Suds & Slots API (v1)

The contract between the iPad app and the backend. The backend is the source of
truth once an iPad is pointed at it; with no server configured the app keeps
working locally as before.

Base URL: `http://<host>:8080/api/v1`. (On the dev Mac the container is published
on host port 8081 because Flamenco owns 8080: `SUDS_HOST_PORT` in backend/.env.) JSON everywhere, UTF-8.

## Auth

Optional. If the server runs with `SUDS_TOKEN=<secret>`, every request except
`GET /health` must send `X-Suds-Token: <secret>`, else `401 {"error":"unauthorized"}`.

## Types

**Person**: `"izzy" | "leon" | "ruby" | "sam" | "sophie"`
**Machine**: `"washer" | "dryer" | "rack"` (that's also the order stages run in)

**Booking**
```json
{
  "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",   // UUID, uppercase as Swift prints it; server accepts any case, echoes what it stored
  "person": "leon",
  "machine": "washer",
  "start": "2026-09-27T20:30:00Z",                // ISO-8601, UTC, whole seconds
  "minutes": 120,
  "startedAt": null,                              // ISO-8601 or null
  "finishedAt": null,                             // ISO-8601 or null
  "updatedAt": "2026-09-27T20:31:02Z"
}
```

**Move** (a booking pushed later by someone's extension)
```json
{ "booking": <Booking as it was before>, "newStart": "2026-09-27T22:30:00Z", "deferred": false }
```

**Notification**
```json
{
  "id": 17, "person": "ruby", "kind": "moved",
  "message": "Your washer slot moved to 10:30 PM – 11:30 PM because Leon extended their session.",
  "bookingId": "…", "oldStart": "…Z", "newStart": "…Z",
  "createdAt": "…Z", "readAt": null
}
```

**Error body**: `{"error": "<code>", "message": "<human sentence>", "clash": <Booking>?}`
Codes: `no_person`, `nothing_chosen`, `in_past` (all 422), `clash` (409),
`not_found` (404), `cannot_start` (409), `bad_request` (422), `unauthorized` (401).

## Rules (same as the app enforces locally)

- Clashes are per machine: two bookings on the same machine may not overlap
  (`a.start < b.end && b.start < a.end`). Different machines never clash.
- A booking is "in the past" if its end is at or before now.
- Chains: stages run back to back in machine order washer → dryer → rack
  (whatever order the array is in); each starts when the previous chosen stage
  ends. The same machine twice is `bad_request`. All stages are validated before any
  is stored (all or nothing).
- Start: allowed if not already started, and either the slot starts today (server
  local day, `TZ` env, default Europe/London) or has begun, and now is before
  `end + 4h`. `at` may be in the past; it's clamped to no earlier than now − 4h.
- Push ("shove along", Quick add): with `"push": true`, each stage may overlap
  bookings on its machine that have **not started** (startedAt null). Those are
  moved back, in start order, to begin when the previous one (starting with the
  new stage) now ends, keeping their length, until nothing overlaps; each moved
  person gets a `moved` notification ("…because Sam quick-added a wash").
  An overlap with a booking that has started or finished is still a `clash` 409.
  Stages are placed first, then pushes are computed per machine; pushes never
  cross machines. Without `push` (default false) any overlap is a 409 as before.
- Night rule (applies to every push, extend or shove): if a pushed booking would
  start at or after 10 PM local time, or in the small hours of a later day, it
  goes to 12:00 PM the next day instead (same length), then carries on pushing
  anything it now overlaps. Such moves have `"deferred": true`, and the
  notification says it would have run past 10 PM. Bookings that don't overlap
  anything placed stay where they are.
- Extend by N minutes: later bookings on the same machine (start ≥ this start)
  that would overlap get pushed to start when the previous one now ends, keeping
  their length, until the chain no longer overlaps. Every moved booking's person
  gets a `moved` notification.

## Endpoints

| Method & path | Body | Response |
| --- | --- | --- |
| `GET /health` | | `200 {"ok": true, "version": <int>}` (no auth) |
| `GET /api/v1/version` | | `{"version": <int>}` — bumps on every change; cheap to poll |
| `GET /api/v1/bookings` | | `{"version": <int>, "bookings": [Booking]}` — everything ending within the last 30 days or later |
| `POST /api/v1/bookings/chain` | `{"person", "start", "stages": [{"machine","minutes"}], "push": false}` | `201 {"version", "bookings": [Booking], "moves": [Move]}` or error |
| `POST /api/v1/bookings/chain-plan` | same body | `{"moves": [Move]}` or the same error the booking would get — a dry run, used to warn before shoving |
| `POST /api/v1/bookings/{id}/start` | `{"at": "<iso>"?}` | `{"version", "booking"}` |
| `POST /api/v1/bookings/{id}/finish` | | `{"version", "booking"}` |
| `GET /api/v1/bookings/{id}/extend-plan?minutes=N` | | `{"moves": [Move]}` |
| `POST /api/v1/bookings/{id}/extend` | `{"minutes": N}` (1…1440) | `{"version", "booking", "moves": [Move]}` |
| `DELETE /api/v1/bookings/{id}` | | `{"version"}` |
| `POST /api/v1/import` | `{"bookings": [Booking]}` | `{"version", "imported": <int>}` — inserts bookings whose id the server doesn't have (existing ids are skipped, never overwritten); for moving an iPad's local data up |
| `GET /api/v1/notifications?person=leon&unread=1` | | `{"notifications": [Notification]}` newest first |
| `POST /api/v1/notifications/{id}/read` | | `{"ok": true}` |
| `GET /api/v1/events` | | Server-Sent Events: `event: changed` / `data: {"version": N}` once on connect and on every change, plus a `: ping` comment every 15 s |

## Notification delivery

Stored notifications are always available from `/notifications`. In addition the
server fans each one out, if configured:

- `NTFY_URL` (e.g. `https://ntfy.sh`) + `NTFY_TOPIC_PREFIX` (default `suds`):
  POST the message to `<NTFY_URL>/<prefix>-<person>` so each person can subscribe
  to their own topic in the ntfy phone app.
- `WEBHOOK_URL`: POST the Notification JSON.

Failures to deliver are logged, never fail the request.
