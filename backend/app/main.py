"""Suds & Slots API (docs/API.md)."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from .store import ApiError, Store

log = logging.getLogger("suds")


@dataclass
class Settings:
    db_path: str = "/data/suds.db"
    token: str = ""
    ntfy_url: str = ""
    ntfy_topic_prefix: str = "suds"
    webhook_url: str = ""
    tz: str = "Europe/London"
    ping_seconds: float = 15.0

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        return cls(
            db_path=e("SUDS_DB") or "/data/suds.db",
            token=e("SUDS_TOKEN") or "",
            ntfy_url=e("NTFY_URL") or "",
            ntfy_topic_prefix=e("NTFY_TOPIC_PREFIX") or "suds",
            webhook_url=e("WEBHOOK_URL") or "",
            tz=(e("TZ") or "Europe/London").lstrip(":"),
            ping_seconds=float(e("SUDS_PING_SECONDS") or 15),
        )


def _zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        log.warning("TZ %r not found, using Europe/London", name)
        return ZoneInfo("Europe/London")


class Broker:
    """Fans the version out to every open /events stream."""

    def __init__(self) -> None:
        self.queues: set[asyncio.Queue[int]] = set()

    def subscribe(self) -> asyncio.Queue[int]:
        q: asyncio.Queue[int] = asyncio.Queue()
        self.queues.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[int]) -> None:
        self.queues.discard(q)

    def publish(self, version: int) -> None:
        for q in list(self.queues):
            q.put_nowait(version)


@dataclass
class Delivery:
    """Fire-and-forget ntfy / webhook fan-out. Failures are only logged."""

    settings: Settings
    transport: httpx.AsyncBaseTransport | None = None
    tasks: set = field(default_factory=set)

    def send(self, notes: list[dict]) -> None:
        if not notes or not (self.settings.ntfy_url or self.settings.webhook_url):
            return
        task = asyncio.get_running_loop().create_task(self._send(notes))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def _send(self, notes: list[dict]) -> None:
        s = self.settings
        async with httpx.AsyncClient(timeout=10, transport=self.transport) as client:
            for note in notes:
                if s.ntfy_url:
                    url = f"{s.ntfy_url.rstrip('/')}/{s.ntfy_topic_prefix}-{note['person']}"
                    try:
                        r = await client.post(url, content=note["message"].encode(),
                                              headers={"Title": "Suds & Slots", "Tags": "basket"})
                        r.raise_for_status()
                    except Exception as exc:  # noqa: BLE001 - never fail the request
                        log.warning("ntfy delivery to %s failed: %s", url, exc)
                if s.webhook_url:
                    try:
                        r = await client.post(s.webhook_url, json=note)
                        r.raise_for_status()
                    except Exception as exc:  # noqa: BLE001
                        log.warning("webhook delivery failed: %s", exc)


def create_app(
    settings: Settings | None = None,
    clock: Callable[[], datetime] | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    clock = clock or (lambda: datetime.now(timezone.utc))
    if settings.db_path not in (":memory:", "") and os.path.dirname(settings.db_path):
        os.makedirs(os.path.dirname(settings.db_path), exist_ok=True)
    store = Store(settings.db_path, clock, _zone(settings.tz))
    broker = Broker()
    delivery = Delivery(settings, transport)

    app = FastAPI(title="Suds & Slots", version="1")
    app.state.store, app.state.broker, app.state.delivery, app.state.settings = store, broker, delivery, settings

    # -- errors

    @app.exception_handler(ApiError)
    async def api_error(_: Request, exc: ApiError):
        return JSONResponse(exc.body(), status_code=exc.status)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, exc: RequestValidationError):
        return JSONResponse({"error": "bad_request", "message": str(exc.errors())}, status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_: Request, exc: StarletteHTTPException):
        code = "not_found" if exc.status_code == 404 else "bad_request"
        return JSONResponse({"error": code, "message": str(exc.detail)}, status_code=exc.status_code)

    # -- auth

    @app.middleware("http")
    async def auth(request: Request, call_next):
        if settings.token and request.url.path != "/health":
            given = request.headers.get("x-suds-token") or request.query_params.get("token")
            if given != settings.token:
                return JSONResponse({"error": "unauthorized", "message": "Missing or wrong X-Suds-Token."},
                                    status_code=401)
        return await call_next(request)

    # -- helpers

    async def body(request: Request) -> dict:
        raw = await request.body()
        if not raw.strip():
            return {}
        try:
            data = json.loads(raw)
        except ValueError:
            raise ApiError("bad_request", "Body is not valid JSON.") from None
        if not isinstance(data, dict):
            raise ApiError("bad_request", "Body must be a JSON object.")
        return data

    def changed(version: int | None) -> None:
        if version is not None:
            broker.publish(version)

    # -- routes

    @app.get("/health")
    async def health():
        return {"ok": True, "version": store.version}

    @app.get("/api/v1/version")
    async def version():
        return {"version": store.version}

    @app.get("/api/v1/bookings")
    async def bookings():
        with store.lock:
            return {"version": store.version, "bookings": [b.to_json() for b in store.list_bookings()]}

    @app.post("/api/v1/bookings/chain", status_code=201)
    async def chain(request: Request):
        data = await body(request)
        v, made, moves, notes = store.book_chain(data.get("person"), data.get("start"), data.get("stages"),
                                                 data.get("push", False))
        changed(v)
        delivery.send(notes)
        return {"version": v, "bookings": [b.to_json() for b in made], "moves": [m.to_json() for m in moves]}

    @app.post("/api/v1/bookings/chain-plan")
    async def chain_plan(request: Request):
        data = await body(request)
        _, moves = store.plan_chain(data.get("person"), data.get("start"), data.get("stages"),
                                    data.get("push", False))
        return {"moves": [m.to_json() for m in moves]}

    @app.post("/api/v1/bookings/{booking_id}/start")
    async def start(booking_id: str, request: Request):
        data = await body(request)
        v, b = store.start(booking_id, data.get("at"))
        changed(v)
        return {"version": v, "booking": b.to_json()}

    @app.post("/api/v1/bookings/{booking_id}/finish")
    async def finish(booking_id: str):
        v, b = store.finish(booking_id)
        changed(v)
        return {"version": v, "booking": b.to_json()}

    @app.get("/api/v1/bookings/{booking_id}/extend-plan")
    async def extend_plan(booking_id: str, minutes: str | None = None):
        _, moves = store.extension_plan(booking_id, minutes)
        return {"moves": [m.to_json() for m in moves]}

    @app.post("/api/v1/bookings/{booking_id}/extend")
    async def extend(booking_id: str, request: Request):
        data = await body(request)
        v, b, moves, notes = store.extend(booking_id, data.get("minutes"))
        changed(v)
        delivery.send(notes)
        return {"version": v, "booking": b.to_json(), "moves": [m.to_json() for m in moves]}

    @app.delete("/api/v1/bookings/{booking_id}")
    async def delete(booking_id: str):
        v = store.delete(booking_id)
        changed(v)
        return {"version": v}

    @app.post("/api/v1/import")
    async def import_(request: Request):
        data = await body(request)
        before = store.version
        v, n = store.import_bookings(data.get("bookings"))
        changed(v if v != before else None)
        return {"version": v, "imported": n}

    @app.get("/api/v1/notifications")
    async def notifications(person: str | None = None, unread: str | None = None):
        flag = (unread or "").lower() in ("1", "true", "yes")
        return {"notifications": store.notifications(person, flag)}

    @app.post("/api/v1/notifications/{note_id}/read")
    async def read(note_id: int):
        changed(store.mark_read(note_id))
        return {"ok": True}

    @app.get("/api/v1/events")
    async def events(request: Request):
        async def stream():
            q = broker.subscribe()
            try:
                yield "retry: 3000\n" + _event(store.version)
                while True:
                    if await request.is_disconnected():
                        break
                    try:
                        v = await asyncio.wait_for(q.get(), settings.ping_seconds)
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"
                        continue
                    yield _event(v)
            finally:
                broker.unsubscribe(q)

        return StreamingResponse(stream(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    return app


def _event(version: int) -> str:
    return f"event: changed\ndata: {json.dumps({'version': version})}\n\n"


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
