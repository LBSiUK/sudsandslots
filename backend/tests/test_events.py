"""SSE: run the app under a real uvicorn on a free port and read the stream."""

from __future__ import annotations

import queue
import socket
import threading
import time

import httpx
import pytest
import uvicorn

from app.main import Settings, create_app

from .conftest import at


@pytest.fixture
def server(tmp_path, clock):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    app = create_app(Settings(db_path=str(tmp_path / "sse.db"), ping_seconds=0.3), clock=clock)
    srv = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning",
                                        timeout_graceful_shutdown=1))
    t = threading.Thread(target=srv.run, daemon=True)
    t.start()
    deadline = time.time() + 10
    while not srv.started and time.time() < deadline:
        time.sleep(0.02)
    yield f"http://127.0.0.1:{port}"
    srv.should_exit = True
    t.join(timeout=5)


def test_events_stream_changes_and_pings(server):
    lines: queue.Queue[str] = queue.Queue()
    stop = threading.Event()

    def reader():
        with httpx.Client(timeout=10) as c, c.stream("GET", f"{server}/api/v1/events") as r:
            assert r.headers["content-type"].startswith("text/event-stream")
            for line in r.iter_lines():
                lines.put(line)
                if stop.is_set():
                    return

    threading.Thread(target=reader, daemon=True).start()

    def next_matching(pred, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = lines.get(timeout=0.1)
            except queue.Empty:
                continue
            if pred(line):
                return line
        raise AssertionError("no matching SSE line")

    # One 'changed' on connect with the current version.
    next_matching(lambda l: l == "event: changed")
    assert next_matching(lambda l: l.startswith("data:")) == 'data: {"version": 0}'

    r = httpx.post(f"{server}/api/v1/bookings/chain", json={
        "person": "leon", "start": at(1), "stages": [{"machine": "washer", "minutes": 60}]})
    assert r.status_code == 201
    next_matching(lambda l: l == "event: changed")
    assert next_matching(lambda l: l.startswith("data:")) == 'data: {"version": 1}'

    # Keep-alive comment.
    next_matching(lambda l: l == ": ping", timeout=3)
    stop.set()
