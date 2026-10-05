# Suds & Slots backend

A small server that keeps the household's laundry bookings in one place, so every
iPad sees the same washer, dryer and drying-rack slots. It implements
[`docs/API.md`](../docs/API.md) (the contract with the iPad app): FastAPI + SQLite,
live updates over Server-Sent Events, and optional ntfy / webhook alerts when
someone's slot gets moved.

## Run it

```sh
cd backend
docker compose up -d --build
curl http://localhost:8080/health        # {"ok":true,"version":0}
```

The data lives in the named volume `suds-data` (`/data/suds.db` in the
container), so it survives rebuilds. The container restarts itself unless you stop it.

**Port 8080 already taken?** (On the dev Mac the Flamenco render-farm manager
uses it.) Put `SUDS_HOST_PORT=8081` in `backend/.env`; the container still
listens on 8080 inside, only the host side changes. That file is git-ignored.

Logs: `docker compose logs -f api`. Stop: `docker compose down` (add `-v` only if
you really want to delete every booking).

## Settings

Set them in `backend/.env` (or the shell) and run `docker compose up -d` again.
`cp .env.example .env` gives you a commented starting point with every default.

| Variable | Default | What it does |
| --- | --- | --- |
| `SUDS_HOST_PORT` | `8080` | Host port the API is published on. |
| `SUDS_TOKEN` | empty | If set, every request except `/health` needs the header `X-Suds-Token: <value>` (or `?token=<value>`, handy for `/events` in a browser). Empty = no auth. |
| `NTFY_URL` | empty | e.g. `https://ntfy.sh` or your own ntfy server. Empty = no ntfy pushes. |
| `NTFY_TOPIC_PREFIX` | `suds` | Topics are `<prefix>-<person>`, e.g. `suds-ruby`. |
| `WEBHOOK_URL` | empty | If set, each notification's JSON is POSTed here too. |
| `TZ` | `Europe/London` | The household's time zone: decides what "today" means for Start, and the times written in notification messages. |

Inside the container `SUDS_DB` (default `/data/suds.db`) and `SUDS_PING_SECONDS`
(default 15) can also be set, but you shouldn't need to.

## Point the iPad app at it

1. Find the server machine's LAN address (e.g. `192.168.0.10`).
2. On the iPad, open the app's Server settings sheet (from the sync status in the side
   panel), enter `http://192.168.0.10:8080` (plus the token if you set
   `SUDS_TOKEN`), tap **Test Connection**, then **Save**.
3. The first time, the app uploads its own bookings with `/api/v1/import`; from
   then on the server is the source of truth and every iPad updates live.

For the simulator or a debug build you can also launch with
`-server http://localhost:8081 -token <secret>`.

## Get told when your slot moves (ntfy)

When someone extends a session, or quick-adds with "shove along", later bookings
on that machine get pushed back and each moved person gets a notification. To get
it on your phone:

1. Set `NTFY_URL=https://ntfy.sh` (or your own server) in `backend/.env` and
   `docker compose up -d`.
2. Install the **ntfy** app (iOS / Android), tap **+**, and subscribe to your own
   topic: `suds-izzy`, `suds-leon`, `suds-ruby`, `suds-sam` or `suds-sophie`
   (with a different `NTFY_TOPIC_PREFIX`, use that instead of `suds`).
3. Test it: `curl -d "hello from the laundry" https://ntfy.sh/suds-leon`.

On public ntfy.sh anyone who guesses a topic name can read it; pick an unusual
prefix (e.g. `NTFY_TOPIC_PREFIX=suds-7f3k`) or run your own ntfy server.

Delivery is fire-and-forget: if ntfy or the webhook is down the booking still goes
through and the failure is logged. Notifications are always readable from
`GET /api/v1/notifications?person=<name>`.

## Tests

The tests run inside the image (pytest is installed there), against a throwaway
database and a controllable clock:

```sh
docker compose build && docker compose run --rm --no-deps api pytest
```

## Quick checks

```sh
H=http://localhost:8080
curl $H/api/v1/bookings
curl -XPOST $H/api/v1/bookings/chain -H 'content-type: application/json' \
  -d '{"person":"leon","start":"2026-09-28T09:00:00Z","stages":[{"machine":"washer","minutes":120},{"machine":"dryer","minutes":90}]}'
curl -N $H/api/v1/events                 # live change stream; Ctrl-C to stop
```

## Layout

- `app/store.py`: the booking rules (clashes, chains and pushes, start/finish,
  extend) and the SQLite storage. Mirrors `BookingStore` in the app's `Models.swift`.
- `app/main.py`: HTTP routes, token check, the SSE stream, ntfy/webhook delivery.
- `tests/`: pytest suite (`test_events.py` runs a real server to read the SSE stream).
