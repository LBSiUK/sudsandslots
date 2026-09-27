"""Bookings, their rules and the SQLite they live in.

Mirrors BookingStore in Sources/SudsAndSlots/Models.swift: check / checkChain /
start / finish / extensionPlan / extend / remove, plus Booking.canStart.
"""

from __future__ import annotations

import sqlite3
import threading
import uuid
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from typing import Any, Callable
from zoneinfo import ZoneInfo

PEOPLE = ("izzy", "leon", "ruby", "sam", "sophie")
MACHINES = ("washer", "dryer", "rack")  # also the order stages run in
MACHINE_NAMES = {"washer": "Washer", "dryer": "Dryer", "rack": "Drying rack"}
MAX_MINUTES = {"washer": 6 * 60, "dryer": 6 * 60, "rack": 24 * 60}
MAX_BACKDATE = timedelta(hours=4)
KEEP_FOR = timedelta(days=30)
MAX_EXTEND = 1440
# "…because Sam quick-added a wash."
QUICK_ADD_WHAT = {"washer": "a wash", "dryer": "a dryer load", "rack": "a drying rack slot"}

UTC = timezone.utc


class ApiError(Exception):
    """An error the API turns into {"error", "message", "clash"?}."""

    def __init__(self, code: str, message: str, status: int = 422, clash: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.clash = code, message, status, clash

    def body(self) -> dict:
        out: dict[str, Any] = {"error": self.code, "message": self.message}
        if self.clash is not None:
            out["clash"] = self.clash
        return out


def bad(message: str) -> ApiError:
    return ApiError("bad_request", message, 422)


# ---------------------------------------------------------------- time


def parse_time(value: Any, field: str) -> datetime:
    """ISO-8601 -> aware UTC datetime, whole seconds. Naive means UTC."""
    if not isinstance(value, str) or not value:
        raise bad(f"'{field}' must be an ISO-8601 date string.")
    try:
        dt = datetime.fromisoformat(value.strip().replace("z", "Z"))
    except ValueError:
        raise bad(f"'{field}' is not a valid ISO-8601 date: {value!r}.") from None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC).replace(microsecond=0)


def fmt_time(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _from_db(value: str | None) -> datetime | None:
    return None if value is None else datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


# ---------------------------------------------------------------- model


@dataclass(frozen=True)
class Booking:
    id: str
    person: str
    machine: str
    start: datetime
    minutes: int
    started_at: datetime | None = None
    finished_at: datetime | None = None
    updated_at: datetime | None = None

    @property
    def end(self) -> datetime:
        return self.start + timedelta(minutes=self.minutes)

    def overlaps(self, start: datetime, end: datetime) -> bool:
        return self.start < end and start < self.end

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "person": self.person,
            "machine": self.machine,
            "start": fmt_time(self.start),
            "minutes": self.minutes,
            "startedAt": fmt_time(self.started_at),
            "finishedAt": fmt_time(self.finished_at),
            "updatedAt": fmt_time(self.updated_at),
        }


@dataclass(frozen=True)
class Move:
    booking: Booking  # as it was before moving
    new_start: datetime
    deferred: bool = False  # the night rule sent it to the next afternoon

    @property
    def new_end(self) -> datetime:
        return self.new_start + timedelta(minutes=self.booking.minutes)

    def to_json(self) -> dict:
        return {"booking": self.booking.to_json(), "newStart": fmt_time(self.new_start),
                "deferred": self.deferred}


# ---------------------------------------------------------------- store

SCHEMA = """
CREATE TABLE IF NOT EXISTS bookings (
    id          TEXT PRIMARY KEY COLLATE NOCASE,
    person      TEXT NOT NULL,
    machine     TEXT NOT NULL,
    start       TEXT NOT NULL,
    minutes     INTEGER NOT NULL,
    started_at  TEXT,
    finished_at TEXT,
    updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bookings_machine_start ON bookings (machine, start);
CREATE TABLE IF NOT EXISTS notifications (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    person      TEXT NOT NULL,
    kind        TEXT NOT NULL,
    message     TEXT NOT NULL,
    booking_id  TEXT,
    old_start   TEXT,
    new_start   TEXT,
    created_at  TEXT NOT NULL,
    read_at     TEXT
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT OR IGNORE INTO meta (key, value) VALUES ('version', 0);
"""


class Store:
    def __init__(self, path: str, clock: Callable[[], datetime], tz: ZoneInfo):
        self.clock = clock
        self.tz = tz
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self.lock = threading.RLock()

    # -- helpers

    def now(self) -> datetime:
        now = self.clock()
        if now.tzinfo is None:
            now = now.replace(tzinfo=UTC)
        return now.astimezone(UTC).replace(microsecond=0)

    def local_time(self, dt: datetime) -> str:
        # "10:30 PM", as Booking.timeFormatter prints it.
        return dt.astimezone(self.tz).strftime("%I:%M %p").lstrip("0")

    def time_range(self, start: datetime, end: datetime) -> str:
        return f"{self.local_time(start)} – {self.local_time(end)}"

    def night_deferral(self, start: datetime, original: datetime) -> datetime | None:
        """Night rule: a push that would start a booking at or after 10 PM, or in
        the small hours of a later day, sends it to 12:00 PM the next day."""
        local = start.astimezone(self.tz)
        if local.hour >= 22:
            noon = (local + timedelta(days=1)).replace(hour=12, minute=0, second=0, microsecond=0)
            return noon.astimezone(UTC)
        if local.hour < 12 and local.date() > original.astimezone(self.tz).date():
            return local.replace(hour=12, minute=0, second=0, microsecond=0).astimezone(UTC)
        return None

    def cascade(self, placed: list[tuple[datetime, datetime]], candidates: list[Booking],
                block_started: bool) -> list[Move]:
        """Push `candidates` (one machine, start order) off everything placed so
        far: one that overlaps moves to when what it overlaps ends, keeping its
        length (night rule applied); one that doesn't stays and counts as placed.
        Mirrors BookingStore.cascade in the app."""
        placed = list(placed)
        moves: list[Move] = []

        def overlap_end(start: datetime, end: datetime) -> datetime | None:
            ends = [e for (s, e) in placed if start < e and s < end]
            return max(ends) if ends else None

        for b in candidates:
            first = overlap_end(b.start, b.end)
            if first is None:
                placed.append((b.start, b.end))
                continue
            if block_started and (b.started_at or b.finished_at):
                raise self._clash(b)
            length = timedelta(minutes=b.minutes)
            start, deferred = first, False
            while True:
                later = self.night_deferral(start, b.start)
                if later is not None:
                    start, deferred = later, True
                end = overlap_end(start, start + length)
                if end is None:
                    break
                start = end
            moves.append(Move(b, start, deferred))
            placed.append((start, start + length))
        return moves

    @property
    def version(self) -> int:
        return self.db.execute("SELECT value FROM meta WHERE key='version'").fetchone()[0]

    def _bump(self) -> int:
        self.db.execute("UPDATE meta SET value = value + 1 WHERE key='version'")
        return self.version

    @staticmethod
    def _row(r: sqlite3.Row) -> Booking:
        return Booking(
            id=r["id"], person=r["person"], machine=r["machine"], start=_from_db(r["start"]),
            minutes=r["minutes"], started_at=_from_db(r["started_at"]),
            finished_at=_from_db(r["finished_at"]), updated_at=_from_db(r["updated_at"]),
        )

    def _all(self, machine: str | None = None) -> list[Booking]:
        if machine:
            rows = self.db.execute("SELECT * FROM bookings WHERE machine=? ORDER BY start, id", (machine,))
        else:
            rows = self.db.execute("SELECT * FROM bookings ORDER BY start, id")
        return [self._row(r) for r in rows]

    def get(self, booking_id: str) -> Booking:
        r = self.db.execute("SELECT * FROM bookings WHERE id=?", (booking_id,)).fetchone()
        if r is None:
            raise ApiError("not_found", "No booking with that id.", 404)
        return self._row(r)

    def _write(self, b: Booking) -> None:
        self.db.execute(
            "INSERT OR REPLACE INTO bookings (id, person, machine, start, minutes, started_at, finished_at, updated_at)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (b.id, b.person, b.machine, fmt_time(b.start), b.minutes,
             fmt_time(b.started_at), fmt_time(b.finished_at), fmt_time(b.updated_at)),
        )

    # -- reads

    def list_bookings(self) -> list[Booking]:
        cutoff = self.now() - KEEP_FOR
        return [b for b in self._all() if b.end > cutoff]

    # -- chain booking

    def _clash(self, other: Booking) -> ApiError:
        return ApiError(
            "clash",
            f"That clashes with {other.person.capitalize()}'s {MACHINE_NAMES[other.machine].lower()} slot"
            f" ({self.time_range(other.start, other.end)}).",
            409, clash=other.to_json(),
        )

    def _place(self, person: str, machine: str, start: datetime, minutes: int, now: datetime,
               push: bool) -> tuple[Booking, list[Move]]:
        """One stage: the booking it makes, plus the not-started bookings it shoves along."""
        booking = Booking(id=str(uuid.uuid4()).upper(), person=person, machine=machine,
                          start=start, minutes=minutes, updated_at=now)
        # The slot in progress can be booked, just not one that's already over.
        if booking.end <= now:
            raise ApiError("in_past", "That start time has already passed.", 422)
        others = self._all(machine)
        if not push:
            for other in others:
                if other.overlaps(booking.start, booking.end):
                    raise self._clash(other)
            return booking, []
        # Push: anything started/finished in the way is a clash; the rest move back
        # in start order, each to when the previous one now ends (like extend).
        for other in others:
            if other.overlaps(booking.start, booking.end) and (other.started_at or other.finished_at):
                raise self._clash(other)
        later = sorted((o for o in others if o.end > booking.start), key=lambda o: o.start)
        return booking, self.cascade([(booking.start, booking.end)], later, block_started=True)

    def _parse_chain(self, person: Any, start: Any, stages: Any) -> tuple[str, datetime, dict[str, int]]:
        if stages is None:
            stages = []
        if not isinstance(stages, list):
            raise bad("'stages' must be a list of {machine, minutes}.")
        if not stages:
            raise ApiError("nothing_chosen",
                           "Say yes to at least one of the washing machine, dryer or drying rack.", 422)
        if person is None or person == "":
            raise ApiError("no_person", "Pick who's washing first.", 422)
        if person not in PEOPLE:
            raise bad(f"Unknown person {person!r}.")
        start_dt = parse_time(start, "start")
        parsed: dict[str, int] = {}
        for s in stages:
            if not isinstance(s, dict):
                raise bad("Each stage must be {machine, minutes}.")
            machine, minutes = s.get("machine"), s.get("minutes")
            if machine not in MACHINES:
                raise bad(f"Unknown machine {machine!r}.")
            if machine in parsed:
                raise bad(f"{machine} is in the stages twice.")
            if not isinstance(minutes, int) or isinstance(minutes, bool) or not 1 <= minutes <= MAX_MINUTES[machine]:
                raise bad(f"{machine} minutes must be a whole number from 1 to {MAX_MINUTES[machine]}.")
            parsed[machine] = minutes
        return person, start_dt, parsed

    def plan_chain(self, person: Any, start: Any, stages: Any, push: Any = False) -> tuple[list[Booking], list[Move]]:
        """The bookings a chain would make and the moves it would cause, or the error."""
        if not isinstance(push, bool) and push is not None:
            raise bad("'push' must be true or false.")
        person, at, parsed = self._parse_chain(person, start, stages)
        now = self.now()
        made, moves = [], []
        for machine in MACHINES:  # washer -> dryer -> rack, back to back
            if machine in parsed:
                b, m = self._place(person, machine, at, parsed[machine], now, bool(push))
                made.append(b)
                moves += m
                at = b.end
        return made, moves

    def book_chain(self, person: Any, start: Any, stages: Any,
                   push: Any = False) -> tuple[int, list[Booking], list[Move], list[dict]]:
        with self.lock:
            made, moves = self.plan_chain(person, start, stages, push)
            now = self.now()
            notes = []
            with self.db:
                self.db.execute("BEGIN")
                for b in made:
                    self._write(b)
                for m in moves:
                    reason = f"{made[0].person.capitalize()} quick-added {QUICK_ADD_WHAT[m.booking.machine]}"
                    notes.append(self._apply_move(m, reason, now))
                version = self._bump()
            return version, made, moves, [self.notification(i) for i in notes]

    def _apply_move(self, m: Move, reason: str, now: datetime) -> int:
        """Store a move and the moved person's notification; returns the notification id."""
        self._write(replace(m.booking, start=m.new_start, updated_at=now))
        slot = f"Your {MACHINE_NAMES[m.booking.machine].lower()} slot"
        if m.deferred:
            day = m.new_start.astimezone(self.tz).strftime("%A")
            message = (f"{slot} would have run past 10 PM after {reason}, so it's moved to"
                       f" {day} {self.time_range(m.new_start, m.new_end)}.")
        else:
            message = f"{slot} moved to {self.time_range(m.new_start, m.new_end)} because {reason}."
        cur = self.db.execute(
            "INSERT INTO notifications (person, kind, message, booking_id, old_start, new_start, created_at)"
            " VALUES (?,?,?,?,?,?,?)",
            (m.booking.person, "moved", message, m.booking.id,
             fmt_time(m.booking.start), fmt_time(m.new_start), fmt_time(now)),
        )
        return cur.lastrowid

    # -- start / finish

    def can_start(self, b: Booking, now: datetime) -> bool:
        today = b.start.astimezone(self.tz).date() == now.astimezone(self.tz).date()
        return b.started_at is None and (today or b.start <= now) and now < b.end + MAX_BACKDATE

    def start(self, booking_id: str, at: Any = None) -> tuple[int, Booking]:
        with self.lock:
            b, now = self.get(booking_id), self.now()
            if not self.can_start(b, now):
                reason = ("It's already been started." if b.started_at is not None
                          else "It can only be started on the day, until 4 hours after it ends.")
                raise ApiError("cannot_start", f"That booking can't be started now. {reason}", 409)
            when = now if at is None else parse_time(at, "at")
            when = max(when, now - MAX_BACKDATE)
            b = replace(b, started_at=when, finished_at=None, updated_at=now)
            return self._save(b), b

    def finish(self, booking_id: str) -> tuple[int, Booking]:
        with self.lock:
            b, now = self.get(booking_id), self.now()
            b = replace(b, finished_at=now, updated_at=now)
            return self._save(b), b

    def _save(self, b: Booking) -> int:
        with self.db:
            self.db.execute("BEGIN")
            self._write(b)
            return self._bump()

    # -- extend

    @staticmethod
    def _minutes(value: Any) -> int:
        if isinstance(value, str) and value.strip().lstrip("-").isdigit():
            value = int(value)
        if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= MAX_EXTEND:
            raise bad(f"'minutes' must be a whole number from 1 to {MAX_EXTEND}.")
        return value

    def extension_plan(self, booking_id: str, minutes: Any) -> tuple[Booking, list[Move]]:
        minutes = self._minutes(minutes)
        b = self.get(booking_id)
        end = b.end + timedelta(minutes=minutes)
        later = [o for o in self._all(b.machine) if o.id.upper() != b.id.upper() and o.start >= b.start]
        later.sort(key=lambda o: o.start)
        return b, self.cascade([(b.start, end)], later, block_started=False)

    def extend(self, booking_id: str, minutes: Any) -> tuple[int, Booking, list[Move], list[dict]]:
        with self.lock:
            b, moves = self.extension_plan(booking_id, minutes)
            now = self.now()
            extended = replace(b, minutes=b.minutes + self._minutes(minutes), updated_at=now)
            notes = []
            with self.db:
                self.db.execute("BEGIN")
                self._write(extended)
                for m in moves:
                    notes.append(self._apply_move(m, f"{extended.person.capitalize()} extended their session", now))
                version = self._bump()
            return version, extended, moves, [self.notification(i) for i in notes]

    # -- delete / import

    def delete(self, booking_id: str) -> int:
        with self.lock:
            self.get(booking_id)
            with self.db:
                self.db.execute("BEGIN")
                self.db.execute("DELETE FROM bookings WHERE id=?", (booking_id,))
                return self._bump()

    def import_bookings(self, items: Any) -> tuple[int, int]:
        if not isinstance(items, list):
            raise bad("'bookings' must be a list of Booking.")
        parsed: list[Booking] = []
        for i, it in enumerate(items):
            if not isinstance(it, dict):
                raise bad(f"bookings[{i}] must be an object.")
            bid = it.get("id")
            try:
                uuid.UUID(str(bid))
            except ValueError:
                raise bad(f"bookings[{i}].id must be a UUID.") from None
            if it.get("person") not in PEOPLE:
                raise bad(f"bookings[{i}].person is not one of {', '.join(PEOPLE)}.")
            machine = it.get("machine") or "washer"  # pre-dryer bookings were washes
            if machine not in MACHINES:
                raise bad(f"bookings[{i}].machine is not one of {', '.join(MACHINES)}.")
            minutes = it.get("minutes")
            if not isinstance(minutes, int) or isinstance(minutes, bool) or minutes < 1:
                raise bad(f"bookings[{i}].minutes must be a positive whole number.")
            started = it.get("startedAt")
            finished = it.get("finishedAt")
            parsed.append(Booking(
                id=bid, person=it["person"], machine=machine,
                start=parse_time(it.get("start"), f"bookings[{i}].start"), minutes=minutes,
                started_at=None if started is None else parse_time(started, f"bookings[{i}].startedAt"),
                finished_at=None if finished is None else parse_time(finished, f"bookings[{i}].finishedAt"),
            ))
        with self.lock:
            now = self.now()
            with self.db:
                self.db.execute("BEGIN")
                count = 0
                for b in parsed:
                    cur = self.db.execute(
                        "INSERT OR IGNORE INTO bookings (id, person, machine, start, minutes, started_at, finished_at, updated_at)"
                        " VALUES (?,?,?,?,?,?,?,?)",
                        (b.id, b.person, b.machine, fmt_time(b.start), b.minutes,
                         fmt_time(b.started_at), fmt_time(b.finished_at), fmt_time(now)),
                    )
                    count += cur.rowcount
                version = self._bump() if count else self.version
            return version, count

    # -- notifications

    @staticmethod
    def _note(r: sqlite3.Row) -> dict:
        return {
            "id": r["id"], "person": r["person"], "kind": r["kind"], "message": r["message"],
            "bookingId": r["booking_id"], "oldStart": r["old_start"], "newStart": r["new_start"],
            "createdAt": r["created_at"], "readAt": r["read_at"],
        }

    def notification(self, note_id: int) -> dict:
        r = self.db.execute("SELECT * FROM notifications WHERE id=?", (note_id,)).fetchone()
        if r is None:
            raise ApiError("not_found", "No notification with that id.", 404)
        return self._note(r)

    def notifications(self, person: str | None, unread: bool) -> list[dict]:
        sql, args = "SELECT * FROM notifications WHERE 1=1", []
        if person:
            sql += " AND person=?"
            args.append(person)
        if unread:
            sql += " AND read_at IS NULL"
        sql += " ORDER BY id DESC"
        return [self._note(r) for r in self.db.execute(sql, args)]

    def mark_read(self, note_id: int) -> int | None:
        """Returns the new version if something changed."""
        with self.lock:
            note = self.notification(note_id)
            if note["readAt"] is not None:
                return None
            with self.db:
                self.db.execute("BEGIN")
                self.db.execute("UPDATE notifications SET read_at=? WHERE id=?", (fmt_time(self.now()), note_id))
                return self._bump()
