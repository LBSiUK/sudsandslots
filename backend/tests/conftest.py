from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import Settings, create_app

UTC = timezone.utc
# 13:00 in London (BST), a Sunday.
NOON = datetime(2026, 9, 27, 12, 0, tzinfo=UTC)


class Clock:
    def __init__(self, now: datetime = NOON):
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **kw) -> None:
        self.now += timedelta(**kw)


def iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def at(hours: float = 0, minutes: int = 0, base: datetime = NOON) -> str:
    """ISO time `hours`/`minutes` after the test clock's noon."""
    return iso(base + timedelta(hours=hours, minutes=minutes))


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def make_client(tmp_path, clock):
    opened = []

    def make(**overrides) -> TestClient:
        transport = overrides.pop("transport", None)
        settings = Settings(db_path=str(tmp_path / "suds.db"), **overrides)
        c = TestClient(create_app(settings, clock=clock, transport=transport))
        c.__enter__()
        opened.append(c)
        return c

    yield make
    for c in opened:
        c.__exit__(None, None, None)


@pytest.fixture
def client(make_client) -> TestClient:
    return make_client()


@pytest.fixture
def book(client):
    """Book a chain and return its bookings (asserting success)."""

    def _book(person: str, start: str, *stages: tuple[str, int]) -> list[dict]:
        r = client.post("/api/v1/bookings/chain", json={
            "person": person, "start": start,
            "stages": [{"machine": m, "minutes": n} for m, n in stages],
        })
        assert r.status_code == 201, r.text
        return r.json()["bookings"]

    return _book
