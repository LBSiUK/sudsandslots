from __future__ import annotations

import time

import httpx

from .conftest import NOON, at, iso

API = "/api/v1"


def version(client) -> int:
    return client.get(f"{API}/version").json()["version"]


def listed(client) -> list[dict]:
    return client.get(f"{API}/bookings").json()["bookings"]


# ---------------------------------------------------------------- chains


def test_chain_runs_back_to_back_in_machine_order(client):
    # Array order is ignored: stages always run washer -> dryer -> rack.
    r = client.post(f"{API}/bookings/chain", json={
        "person": "leon", "start": at(1),
        "stages": [{"machine": "rack", "minutes": 360}, {"machine": "washer", "minutes": 120},
                   {"machine": "dryer", "minutes": 90}],
    })
    assert r.status_code == 201
    body = r.json()
    assert body["version"] == 1
    got = [(b["machine"], b["start"], b["minutes"]) for b in body["bookings"]]
    assert got == [("washer", at(1), 120), ("dryer", at(3), 90), ("rack", at(4, 30), 360)]
    for b in body["bookings"]:
        assert b["person"] == "leon" and b["startedAt"] is None and b["finishedAt"] is None
        assert b["updatedAt"] == iso(NOON)
        assert b["id"] == b["id"].upper() and len(b["id"]) == 36
    assert len(listed(client)) == 3


def test_chain_is_all_or_nothing_on_clash(client, book):
    ruby = book("ruby", at(3), ("dryer", 60))[0]
    v = version(client)
    r = client.post(f"{API}/bookings/chain", json={
        "person": "leon", "start": at(1),
        "stages": [{"machine": "washer", "minutes": 120}, {"machine": "dryer", "minutes": 90}],
    })
    assert r.status_code == 409
    err = r.json()
    assert err["error"] == "clash"
    assert err["clash"]["id"] == ruby["id"]
    assert "Ruby's dryer slot" in err["message"]
    # The washer stage, which was free, was not stored either.
    assert [b["id"] for b in listed(client)] == [ruby["id"]]
    assert version(client) == v


def test_clashes_are_per_machine(client, book):
    book("leon", at(1), ("washer", 120))
    # Same time, different machine: fine.
    book("ruby", at(1), ("dryer", 120))
    book("sam", at(1), ("rack", 120))
    # Back to back on the same machine: fine (end == start is not an overlap).
    book("sophie", at(3), ("washer", 60))
    # Overlapping on the same machine: clash.
    r = client.post(f"{API}/bookings/chain", json={
        "person": "izzy", "start": at(2, 59), "stages": [{"machine": "washer", "minutes": 30}]})
    assert r.status_code == 409 and r.json()["error"] == "clash"
    assert r.json()["clash"]["person"] in ("leon", "sophie")
    # Rack uses its own max (24h).
    book("izzy", at(10), ("rack", 1440))


def test_in_past(client, book):
    r = client.post(f"{API}/bookings/chain", json={
        "person": "leon", "start": at(-3), "stages": [{"machine": "washer", "minutes": 120}]})
    assert r.status_code == 422 and r.json()["error"] == "in_past"
    # Ending exactly now counts as past.
    r = client.post(f"{API}/bookings/chain", json={
        "person": "leon", "start": at(-2), "stages": [{"machine": "washer", "minutes": 120}]})
    assert r.json()["error"] == "in_past"
    # The slot in progress can still be booked.
    book("leon", at(-1), ("washer", 120))


def test_nothing_chosen_no_person_and_bad_requests(client):
    def post(payload):
        return client.post(f"{API}/bookings/chain", json=payload)

    r = post({"person": "leon", "start": at(1), "stages": []})
    assert (r.status_code, r.json()["error"]) == (422, "nothing_chosen")
    assert post({"person": "leon", "start": at(1)}).json()["error"] == "nothing_chosen"
    r = post({"person": None, "start": at(1), "stages": [{"machine": "washer", "minutes": 60}]})
    assert (r.status_code, r.json()["error"]) == (422, "no_person")
    for payload in [
        {"person": "bob", "start": at(1), "stages": [{"machine": "washer", "minutes": 60}]},
        {"person": "leon", "start": at(1), "stages": [{"machine": "iron", "minutes": 60}]},
        {"person": "leon", "start": at(1), "stages": [{"machine": "washer", "minutes": 0}]},
        {"person": "leon", "start": at(1), "stages": [{"machine": "washer", "minutes": 361}]},
        {"person": "leon", "start": "not a date", "stages": [{"machine": "washer", "minutes": 60}]},
        {"person": "leon", "start": at(1), "stages": [{"machine": "washer", "minutes": 60},
                                                     {"machine": "washer", "minutes": 60}]},
    ]:
        r = post(payload)
        assert (r.status_code, r.json()["error"]) == (422, "bad_request"), payload
    r = client.post(f"{API}/bookings/chain", content=b"{nope", headers={"content-type": "application/json"})
    assert (r.status_code, r.json()["error"]) == (422, "bad_request")
    assert version(client) == 0


def test_times_accept_offsets_and_fractions(client):
    r = client.post(f"{API}/bookings/chain", json={
        "person": "sam", "start": "2026-09-27T14:00:00.750+01:00",
        "stages": [{"machine": "washer", "minutes": 60}]})
    assert r.json()["bookings"][0]["start"] == "2026-09-27T13:00:00Z"


# ---------------------------------------------------------------- start / finish


def test_start_now_and_backdate_clamp(client, book, clock):
    b = book("leon", at(0), ("washer", 120))[0]
    r = client.post(f"{API}/bookings/{b['id']}/start")
    assert r.status_code == 200
    assert r.json()["booking"]["startedAt"] == iso(NOON)
    assert r.json()["version"] == 2
    # Already started.
    r = client.post(f"{API}/bookings/{b['id']}/start")
    assert (r.status_code, r.json()["error"]) == (409, "cannot_start")

    # A load logged late: `at` in the past is kept, but no earlier than now - 4h.
    old = book("ruby", at(0, 30), ("dryer", 60))[0]
    clock.advance(hours=3)  # slot ended 1.5h ago
    r = client.post(f"{API}/bookings/{old['id']}/start", json={"at": at(-10)})
    assert r.json()["booking"]["startedAt"] == at(-1)  # now(15:00) - 4h = 11:00

    other = book("sam", at(3, 30), ("rack", 60))[0]
    r = client.post(f"{API}/bookings/{other['id']}/start", json={"at": at(2, 15)})
    assert r.json()["booking"]["startedAt"] == at(2, 15)


def test_start_later_today_but_not_tomorrow(client, book):
    # 23:30 London today (22:30Z) can be started now; 00:30 London tomorrow (23:30Z
    # the same UTC day) cannot: "today" is the server's local day.
    tonight = book("izzy", "2026-09-27T22:30:00Z", ("washer", 30))[0]
    after_midnight = book("izzy", "2026-09-27T23:30:00Z", ("washer", 30))[0]
    assert client.post(f"{API}/bookings/{tonight['id']}/start").status_code == 200
    r = client.post(f"{API}/bookings/{after_midnight['id']}/start")
    assert (r.status_code, r.json()["error"]) == (409, "cannot_start")


def test_cannot_start_more_than_4h_after_end(client, book, clock):
    b = book("leon", at(0), ("washer", 60))[0]
    clock.advance(hours=5)  # ended 4h ago exactly
    r = client.post(f"{API}/bookings/{b['id']}/start")
    assert (r.status_code, r.json()["error"]) == (409, "cannot_start")


def test_start_404(client):
    r = client.post(f"{API}/bookings/3F2504E0-4F89-11D3-9A0C-0305E82C3301/start")
    assert (r.status_code, r.json()["error"]) == (404, "not_found")


def test_finish(client, book, clock):
    b = book("leon", at(0), ("washer", 120))[0]
    client.post(f"{API}/bookings/{b['id']}/start")
    clock.advance(minutes=95)
    r = client.post(f"{API}/bookings/{b['id']}/finish")
    assert r.status_code == 200
    got = r.json()["booking"]
    assert got["startedAt"] == iso(NOON) and got["finishedAt"] == at(1, 35)
    assert got["updatedAt"] == at(1, 35)
    assert r.json()["version"] == 3
    assert client.post(f"{API}/bookings/nope/finish").status_code == 404


# ---------------------------------------------------------------- extend


def _extend_setup(book):
    a = book("leon", at(0), ("washer", 120))[0]       # 12:00-14:00
    b = book("ruby", at(2), ("washer", 60))[0]        # 14:00-15:00
    c = book("sam", at(3, 30), ("washer", 60))[0]     # 15:30-16:30 (30 min gap before)
    d = book("sophie", at(6), ("washer", 60))[0]      # 18:00-19:00
    e = book("izzy", at(2), ("dryer", 60))[0]         # other machine, same time as b
    return a, b, c, d, e


def test_extend_plan_pushes_chain_and_gap_absorbs(client, book):
    a, b, c, d, e = _extend_setup(book)
    v = version(client)
    r = client.get(f"{API}/bookings/{a['id']}/extend-plan", params={"minutes": 90})
    assert r.status_code == 200
    moves = r.json()["moves"]
    # a now ends 15:30: b -> 15:30-16:30; c pushed only 60 of the 90 (gap took 30)
    # -> 16:30-17:30; d at 18:00 no longer overlaps; e is on the dryer.
    assert [(m["booking"]["id"], m["booking"]["start"], m["newStart"]) for m in moves] == [
        (b["id"], at(2), at(3, 30)),
        (c["id"], at(3, 30), at(4, 30)),
    ]
    assert version(client) == v  # planning changes nothing


def test_extend_applies_moves_and_notifies(client, book):
    a, b, c, d, e = _extend_setup(book)
    v = version(client)
    r = client.post(f"{API}/bookings/{a['id']}/extend", json={"minutes": 90})
    assert r.status_code == 200
    body = r.json()
    assert body["version"] == v + 1
    assert body["booking"]["minutes"] == 210
    assert [m["booking"]["id"] for m in body["moves"]] == [b["id"], c["id"]]

    by_id = {x["id"]: x for x in listed(client)}
    assert by_id[b["id"]]["start"] == at(3, 30)
    assert by_id[c["id"]]["start"] == at(4, 30)
    assert by_id[d["id"]]["start"] == at(6)
    assert by_id[e["id"]]["start"] == at(2) and by_id[e["id"]]["machine"] == "dryer"
    assert by_id[b["id"]]["minutes"] == 60 and by_id[c["id"]]["minutes"] == 60

    notes = client.get(f"{API}/notifications").json()["notifications"]
    assert [n["person"] for n in notes] == ["sam", "ruby"]  # newest first
    ruby = notes[1]
    assert ruby["kind"] == "moved" and ruby["bookingId"] == b["id"]
    assert ruby["oldStart"] == at(2) and ruby["newStart"] == at(3, 30)
    assert ruby["readAt"] is None and ruby["createdAt"] == iso(NOON)
    # 15:30Z is 4:30 PM in London (BST).
    assert ruby["message"] == ("Your washer slot moved to 4:30 PM – 5:30 PM because Leon "
                               "extended their session.")
    assert not client.get(f"{API}/notifications", params={"person": "sophie"}).json()["notifications"]


def test_extend_without_moves_and_validation(client, book):
    a = book("leon", at(0), ("rack", 60))[0]
    r = client.post(f"{API}/bookings/{a['id']}/extend", json={"minutes": 30})
    assert r.json()["moves"] == [] and r.json()["booking"]["minutes"] == 90
    assert client.get(f"{API}/notifications").json()["notifications"] == []
    for bad in (0, 1441, "lots", None):
        r = client.post(f"{API}/bookings/{a['id']}/extend", json={"minutes": bad})
        assert (r.status_code, r.json()["error"]) == (422, "bad_request"), bad
    assert client.get(f"{API}/bookings/{a['id']}/extend-plan").status_code == 422
    assert client.get(f"{API}/bookings/{a['id']}/extend-plan?minutes=0").status_code == 422
    assert client.post(f"{API}/bookings/nope/extend", json={"minutes": 5}).status_code == 404
    assert client.get(f"{API}/bookings/nope/extend-plan?minutes=5").status_code == 404


# ---------------------------------------------------------------- notifications


def test_notifications_filter_and_read(client, book):
    a, b, c, *_ = _extend_setup(book)
    client.post(f"{API}/bookings/{a['id']}/extend", json={"minutes": 90})
    ruby = client.get(f"{API}/notifications", params={"person": "ruby", "unread": 1}).json()["notifications"]
    assert len(ruby) == 1
    v = version(client)
    r = client.post(f"{API}/notifications/{ruby[0]['id']}/read")
    assert r.json() == {"ok": True}
    assert version(client) == v + 1
    assert client.get(f"{API}/notifications", params={"person": "ruby", "unread": 1}).json()["notifications"] == []
    all_ruby = client.get(f"{API}/notifications", params={"person": "ruby"}).json()["notifications"]
    assert all_ruby[0]["readAt"] == iso(NOON)
    # Reading twice is fine and changes nothing.
    assert client.post(f"{API}/notifications/{ruby[0]['id']}/read").status_code == 200
    assert version(client) == v + 1
    assert client.post(f"{API}/notifications/999/read").status_code == 404


# ---------------------------------------------------------------- delete / import


def test_delete(client, book):
    b = book("leon", at(1), ("washer", 60))[0]
    r = client.delete(f"{API}/bookings/{b['id'].lower()}")  # any case
    assert r.status_code == 200 and r.json() == {"version": 2}
    assert listed(client) == []
    r = client.delete(f"{API}/bookings/{b['id']}")
    assert (r.status_code, r.json()["error"]) == (404, "not_found")


def test_import_is_idempotent_and_never_overwrites(client, book):
    mine = book("leon", at(1), ("washer", 60))[0]
    payload = {"bookings": [
        {"id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301", "person": "ruby", "start": at(-2),
         "minutes": 60, "startedAt": at(-2), "finishedAt": at(-1)},              # no machine: a wash
        {"id": "9A0C0305-E82C-3301-3F25-04E04F8911D3", "person": "sam", "machine": "dryer",
         "start": at(24), "minutes": 90, "startedAt": None, "finishedAt": None},
        {"id": mine["id"], "person": "sophie", "machine": "rack", "start": at(5), "minutes": 5},
        {"id": "11111111-2222-3333-4444-555555555555", "person": "izzy", "machine": "washer",
         "start": iso(NOON.replace(month=8)), "minutes": 60},                     # >30 days old
    ]}
    r = client.post(f"{API}/import", json=payload)
    assert r.status_code == 200
    assert r.json() == {"version": 2, "imported": 3}
    by_id = {b["id"]: b for b in listed(client)}
    assert "3f2504e0-4f89-11d3-9a0c-0305e82c3301" in by_id  # echoed as stored
    assert by_id["3f2504e0-4f89-11d3-9a0c-0305e82c3301"]["machine"] == "washer"
    assert by_id["3f2504e0-4f89-11d3-9a0c-0305e82c3301"]["finishedAt"] == at(-1)
    assert by_id[mine["id"]]["person"] == "leon"  # not overwritten
    assert "11111111-2222-3333-4444-555555555555" not in by_id  # outside the 30-day window
    assert len(by_id) == 3

    again = client.post(f"{API}/import", json=payload)
    assert again.json() == {"version": 2, "imported": 0}
    # Upper-case copy of an existing lower-case id is still the same booking.
    payload["bookings"][0]["id"] = payload["bookings"][0]["id"].upper()
    assert client.post(f"{API}/import", json=payload).json()["imported"] == 0

    r = client.post(f"{API}/import", json={"bookings": [{"id": "x", "person": "leon"}]})
    assert (r.status_code, r.json()["error"]) == (422, "bad_request")


# ---------------------------------------------------------------- version / health / auth


def test_version_bumps_on_every_change(client, book):
    assert client.get("/health").json() == {"ok": True, "version": 0}
    b = book("leon", at(1), ("washer", 60), ("dryer", 60))
    assert version(client) == 1  # one chain, one bump
    client.post(f"{API}/bookings/{b[0]['id']}/start")
    client.post(f"{API}/bookings/{b[0]['id']}/finish")
    client.post(f"{API}/bookings/{b[0]['id']}/extend", json={"minutes": 10})
    client.delete(f"{API}/bookings/{b[1]['id']}")
    assert version(client) == 5
    assert client.get(f"{API}/bookings").json()["version"] == 5
    assert client.get("/health").json()["version"] == 5


def test_token_auth_off_by_default(client):
    assert client.get(f"{API}/version").status_code == 200


def test_token_auth_on(make_client):
    c = make_client(token="s3cret")
    assert c.get("/health").status_code == 200
    r = c.get(f"{API}/version")
    assert (r.status_code, r.json()["error"]) == (401, "unauthorized")
    assert c.get(f"{API}/bookings", headers={"X-Suds-Token": "wrong"}).status_code == 401
    assert c.post(f"{API}/import", json={"bookings": []}).status_code == 401
    assert c.get(f"{API}/version", headers={"X-Suds-Token": "s3cret"}).status_code == 200


def test_unknown_route_uses_error_body(client):
    r = client.get(f"{API}/nothing-here")
    assert (r.status_code, r.json()["error"]) == (404, "not_found")


# ---------------------------------------------------------------- ntfy / webhook


def test_moves_are_delivered_to_ntfy_and_webhook(make_client, clock):
    sent = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(request)
        return httpx.Response(200)

    c = make_client(ntfy_url="http://ntfy.test/", ntfy_topic_prefix="suds", webhook_url="http://hook.test/in",
                    transport=httpx.MockTransport(handler))
    a = c.post(f"{API}/bookings/chain", json={"person": "leon", "start": at(0),
                                              "stages": [{"machine": "washer", "minutes": 60}]}).json()
    c.post(f"{API}/bookings/chain", json={"person": "ruby", "start": at(1),
                                          "stages": [{"machine": "washer", "minutes": 60}]})
    c.post(f"{API}/bookings/{a['bookings'][0]['id']}/extend", json={"minutes": 30})
    deadline = time.time() + 5
    while len(sent) < 2 and time.time() < deadline:
        time.sleep(0.02)
    urls = sorted(str(r.url) for r in sent)
    assert urls == ["http://hook.test/in", "http://ntfy.test/suds-ruby"]
    ntfy = next(r for r in sent if "ntfy" in str(r.url))
    assert ntfy.content.decode().startswith("Your washer slot moved to 2:30 PM")
    hook = next(r for r in sent if "hook" in str(r.url))
    assert b'"person":"ruby"' in hook.content.replace(b" ", b"")


def test_delivery_failure_never_fails_the_request(make_client):
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down")

    c = make_client(ntfy_url="http://ntfy.test", transport=httpx.MockTransport(handler))
    a = c.post(f"{API}/bookings/chain", json={"person": "leon", "start": at(0),
                                              "stages": [{"machine": "washer", "minutes": 60}]}).json()
    c.post(f"{API}/bookings/chain", json={"person": "ruby", "start": at(1),
                                          "stages": [{"machine": "washer", "minutes": 60}]})
    r = c.post(f"{API}/bookings/{a['bookings'][0]['id']}/extend", json={"minutes": 30})
    assert r.status_code == 200
    time.sleep(0.2)


# ---------------------------------------------------------------- push (quick add shoves along)


def _chain(client, path, person, start, *stages, push=None):
    payload = {"person": person, "start": start, "stages": [{"machine": m, "minutes": n} for m, n in stages]}
    if push is not None:
        payload["push"] = push
    return client.post(f"{API}/bookings/{path}", json=payload)


def _push_setup(book):
    a = book("ruby", at(1), ("washer", 60))[0]         # 13:00-14:00
    b = book("sam", at(2), ("washer", 60))[0]          # 14:00-15:00
    c = book("sophie", at(4, 15), ("washer", 60))[0]   # 16:15-17:15 (gap before it)
    d = book("izzy", at(6), ("washer", 60))[0]         # 18:00-19:00
    e = book("izzy", at(2), ("dryer", 60))[0]          # other machine
    return a, b, c, d, e


def test_chain_plan_push_is_a_dry_run(client, book):
    a, b, c, d, e = _push_setup(book)
    v = version(client)
    # Leon quick-adds a wash 13:30-14:30: a -> 14:30, b -> 15:30, c pushed only 15 min
    # (the gap took the rest) -> 16:30, d untouched, dryer untouched.
    r = _chain(client, "chain-plan", "leon", at(1, 30), ("washer", 60), push=True)
    assert r.status_code == 200
    assert [(m["booking"]["id"], m["booking"]["start"], m["newStart"]) for m in r.json()["moves"]] == [
        (a["id"], at(1), at(2, 30)),
        (b["id"], at(2), at(3, 30)),
        (c["id"], at(4, 15), at(4, 30)),
    ]
    assert version(client) == v and len(listed(client)) == 5
    # Without push the plan is the same error the booking would get.
    r = _chain(client, "chain-plan", "leon", at(1, 30), ("washer", 60))
    assert (r.status_code, r.json()["error"], r.json()["clash"]["id"]) == (409, "clash", a["id"])
    # A free slot plans to no moves.
    assert _chain(client, "chain-plan", "leon", at(8), ("washer", 60), push=True).json() == {"moves": []}
    r = _chain(client, "chain-plan", "leon", at(8))
    assert (r.status_code, r.json()["error"]) == (422, "nothing_chosen")


def test_chain_push_moves_and_notifies(client, book):
    a, b, c, d, e = _push_setup(book)
    v = version(client)
    r = _chain(client, "chain", "leon", at(1, 30), ("washer", 60), push=True)
    assert r.status_code == 201
    body = r.json()
    assert body["version"] == v + 1
    assert [x["start"] for x in body["bookings"]] == [at(1, 30)]
    assert [m["booking"]["id"] for m in body["moves"]] == [a["id"], b["id"], c["id"]]
    by_id = {x["id"]: x for x in listed(client)}
    assert [by_id[x["id"]]["start"] for x in (a, b, c, d)] == [at(2, 30), at(3, 30), at(4, 30), at(6)]
    assert by_id[e["id"]]["start"] == at(2)
    notes = client.get(f"{API}/notifications").json()["notifications"]
    assert sorted(n["person"] for n in notes) == ["ruby", "sam", "sophie"]
    ruby = next(n for n in notes if n["person"] == "ruby")
    # 14:30Z is 3:30 PM in London.
    assert ruby["message"] == "Your washer slot moved to 3:30 PM – 4:30 PM because Leon quick-added a wash."
    assert ruby["oldStart"] == at(1) and ruby["newStart"] == at(2, 30)


def test_chain_without_push_still_clashes_and_default_has_no_moves(client, book):
    a, *_ = _push_setup(book)
    r = _chain(client, "chain", "leon", at(1, 30), ("washer", 60))
    assert (r.status_code, r.json()["error"]) == (409, "clash")
    r = _chain(client, "chain", "leon", at(1, 30), ("washer", 60), push=False)
    assert r.status_code == 409
    ok = _chain(client, "chain", "leon", at(8), ("washer", 60))
    assert ok.status_code == 201 and ok.json()["moves"] == []
    r = _chain(client, "chain", "leon", at(9), ("washer", 60), push="yes")
    assert (r.status_code, r.json()["error"]) == (422, "bad_request")


def test_push_never_moves_started_or_finished_bookings(client, book):
    running = book("ruby", at(0), ("washer", 60))[0]     # 12:00-13:00, started
    client.post(f"{API}/bookings/{running['id']}/start")
    v = version(client)
    r = _chain(client, "chain", "leon", at(0, 30), ("washer", 60), push=True)
    assert (r.status_code, r.json()["error"], r.json()["clash"]["id"]) == (409, "clash", running["id"])

    # A pushed chain that would run into a started booking further along is a clash too.
    x = book("sam", at(1, 30), ("dryer", 60))[0]          # 13:30-14:30, not started
    y = book("sophie", at(2, 30), ("dryer", 60))[0]       # 14:30-15:30, started
    client.post(f"{API}/bookings/{y['id']}/start")
    v = version(client)
    r = _chain(client, "chain", "leon", at(1), ("dryer", 60), push=True)  # x -> 14:00, hits y
    assert (r.status_code, r.json()["clash"]["id"]) == (409, y["id"])
    assert version(client) == v
    assert {b["id"]: b["start"] for b in listed(client)}[x["id"]] == at(1, 30)


def test_push_is_per_machine_across_stages(client, book):
    w = book("ruby", at(1), ("washer", 60))[0]    # 13:00-14:00
    d = book("sam", at(2), ("dryer", 60))[0]      # 14:00-15:00
    r = book("sophie", at(2), ("rack", 60))[0]    # 14:00-15:00, overlaps Leon's rack stage
    # Leon: washer 12:30-13:30, dryer 13:30-14:30, rack 14:30-15:30.
    resp = _chain(client, "chain", "leon", at(0, 30), ("washer", 60), ("dryer", 60), ("rack", 60), push=True)
    assert resp.status_code == 201
    moves = {m["booking"]["id"]: m["newStart"] for m in resp.json()["moves"]}
    assert moves[w["id"]] == at(1, 30)    # after Leon's wash
    assert moves[d["id"]] == at(2, 30)    # after Leon's dryer stage, not his wash
    assert moves[r["id"]] == at(3, 30)    # after Leon's rack stage
    notes = client.get(f"{API}/notifications", params={"person": "sam"}).json()["notifications"]
    assert notes[0]["message"].endswith("because Leon quick-added a dryer load.")


def test_push_still_rejects_in_past(client, book):
    r = _chain(client, "chain", "leon", at(-3), ("washer", 60), push=True)
    assert (r.status_code, r.json()["error"]) == (422, "in_past")


# -- night rule: pushed past 10 PM -> next day 12:00 PM (London, BST = UTC+1)

def test_extend_past_10pm_defers_to_next_afternoon_and_says_so(client, book):
    leon = book("leon", "2026-09-27T18:30:00Z", ("washer", 90))[0]    # 7:30-9:00 PM
    ruby = book("ruby", "2026-09-27T20:00:00Z", ("washer", 60))[0]    # 9:00-10:00 PM
    sam = book("sam", "2026-09-28T11:30:00Z", ("washer", 60))[0]      # tomorrow 12:30-1:30 PM
    r = client.post(f"{API}/bookings/{leon['id']}/extend", json={"minutes": 60})
    assert r.status_code == 200
    moves = r.json()["moves"]
    # Ruby would start at 10 PM, so she goes to 12:00 PM tomorrow (11:00Z) instead,
    # and that pushes Sam along to when she finishes (12:00Z = 1 PM), not deferred.
    assert [(m["booking"]["id"], m["newStart"], m["deferred"]) for m in moves] == [
        (ruby["id"], "2026-09-28T11:00:00Z", True),
        (sam["id"], "2026-09-28T12:00:00Z", False),
    ]
    notes = {n["person"]: n["message"] for n in client.get(f"{API}/notifications").json()["notifications"]}
    assert notes["ruby"] == ("Your washer slot would have run past 10 PM after Leon extended their "
                             "session, so it's moved to Monday 12:00 PM – 1:00 PM.")
    assert notes["sam"] == "Your washer slot moved to 1:00 PM – 2:00 PM because Leon extended their session."


def test_push_into_small_hours_defers_too(client, book):
    book("ruby", "2026-09-27T20:30:00Z", ("washer", 60))                # 9:30-10:30 PM, not started
    plan = client.post(f"{API}/bookings/chain-plan", json={
        "person": "sam", "start": "2026-09-27T20:00:00Z",               # 9:00 PM for 4 h -> 1:00 AM
        "stages": [{"machine": "washer", "minutes": 240}], "push": True,
    })
    assert plan.status_code == 200, plan.text
    [move] = plan.json()["moves"]
    assert move["deferred"] is True and move["newStart"] == "2026-09-28T11:00:00Z"


def test_push_before_10pm_is_not_deferred(client, book):
    ruby = book("ruby", "2026-09-27T17:00:00Z", ("washer", 60))[0]      # 6-7 PM
    plan = client.post(f"{API}/bookings/chain-plan", json={
        "person": "sam", "start": "2026-09-27T16:30:00Z",               # 5:30-7:00 PM
        "stages": [{"machine": "washer", "minutes": 90}], "push": True,
    }).json()
    assert [(m["booking"]["id"], m["newStart"], m["deferred"]) for m in plan["moves"]] == [
        (ruby["id"], "2026-09-27T18:00:00Z", False)]                    # 7:00 PM
