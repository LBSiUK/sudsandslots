import SwiftUI

/// The five people who share the washing machine. Order here is the order
/// they appear in the sidebar.
enum Person: String, CaseIterable, Codable, Identifiable {
    case izzy, leon, ruby, sam, sophie

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .izzy:   return Color(red: 0.84, green: 0.20, blue: 0.53)
        case .leon:   return Color(red: 0.15, green: 0.44, blue: 0.84)
        case .ruby:   return Color(red: 0.84, green: 0.25, blue: 0.24)
        case .sam:    return Color(red: 0.21, green: 0.64, blue: 0.33)
        case .sophie: return Color(red: 0.61, green: 0.29, blue: 0.81)
        }
    }
}

enum Machine: String, CaseIterable, Codable, Identifiable {
    case washer, dryer

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var systemImage: String { self == .washer ? "drop.fill" : "wind" }
}

struct Booking: Codable, Identifiable, Equatable {
    var id = UUID()
    var person: Person
    var start: Date
    var minutes: Int
    var machine: Machine = .washer
    /// Set when someone taps Start / Finished on the bar. Optional so older
    /// saved bookings still decode.
    var startedAt: Date?
    var finishedAt: Date?

    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }

    var isRunning: Bool { startedAt != nil && finishedAt == nil }

    /// How far back a Start can be logged, for loads that went on without
    /// anyone pressing Start at the time.
    static let maxBackdate: TimeInterval = 4 * 3600

    /// Today's bookings can be started, and so can one whose slot has begun,
    /// until 4 hours after it ended (to log a load that was never started).
    var canStart: Bool {
        let now = Date()
        return startedAt == nil
            && (Calendar.current.isDateInToday(start) || start <= now)
            && now < end.addingTimeInterval(Booking.maxBackdate)
    }

    func overlaps(start otherStart: Date, end otherEnd: Date) -> Bool {
        start < otherEnd && otherStart < end
    }

    var timeRange: String {
        "\(Booking.timeFormatter.string(from: start)) – \(Booking.timeFormatter.string(from: end))"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        // en_GB would give "am"/"pm"; the design uses capitals.
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()
}

extension Booking {
    private enum CodingKeys: String, CodingKey {
        case id, person, start, minutes, machine, startedAt, finishedAt
    }

    /// Bookings saved before there was a dryer have no machine: they're washes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        person = try c.decode(Person.self, forKey: .person)
        start = try c.decode(Date.self, forKey: .start)
        minutes = try c.decode(Int.self, forKey: .minutes)
        machine = try c.decodeIfPresent(Machine.self, forKey: .machine) ?? .washer
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

enum BookingError: LocalizedError {
    case noPerson
    case inPast
    case clash(Booking)

    var errorDescription: String? {
        switch self {
        case .noPerson: return "Pick who's washing first."
        case .inPast:   return "That start time has already passed."
        case .clash(let b): return "That clashes with \(b.person.name)'s \(b.machine.name.lowercased()) slot (\(b.timeRange))."
        }
    }
}

/// A later booking that has to shift because an earlier session was extended.
struct SessionMove {
    /// The booking as it was before moving.
    let booking: Booking
    let newStart: Date

    var newEnd: Date { newStart.addingTimeInterval(TimeInterval(booking.minutes * 60)) }
    var newTimeRange: String {
        "\(Booking.timeFormatter.string(from: newStart)) – \(Booking.timeFormatter.string(from: newEnd))"
    }
}

/// Told whenever an extension pushes other people's sessions later, so they
/// can be notified. Swap in the backend implementation once it exists.
protocol SessionMoveNotifier {
    func sessionsMoved(_ moves: [SessionMove], by extended: Booking)
}

/// Stand-in until the backend is ready: just logs the moves.
struct LogSessionMoveNotifier: SessionMoveNotifier {
    func sessionsMoved(_ moves: [SessionMove], by extended: Booking) {
        for move in moves {
            print("[moves] \(move.booking.person.name)'s \(move.booking.machine.rawValue) slot",
                  "\(move.booking.timeRange) → \(move.newTimeRange)",
                  "(pushed by \(extended.person.name)'s extension)")
        }
    }
}

/// Holds every booking and persists them as JSON in UserDefaults.
final class BookingStore: ObservableObject {
    @Published private(set) var bookings: [Booking] = []
    var moveNotifier: SessionMoveNotifier = LogSessionMoveNotifier()

    private let key = "bookings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Booking].self, from: data) {
            // Drop anything older than a month so the store doesn't grow forever.
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            bookings = saved.filter { $0.end > cutoff }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") { seedDemo() }
        #endif
    }

    #if DEBUG
    /// Sample bookings for simulator screenshots (launch with -demo).
    private func seedDemo() {
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
            let d = Calendar.current.date(byAdding: .day, value: day, to: today)!
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
        }
        bookings = [
            Booking(person: .izzy, start: at(8), minutes: 90),
            Booking(person: .sophie, start: at(12), minutes: 150),
            Booking(person: .leon, start: at(14, 30), minutes: 90),
            Booking(person: .sam, start: at(18), minutes: 60),
            Booking(person: .ruby, start: at(21), minutes: 30),
            Booking(person: .ruby, start: at(9, day: 1), minutes: 120),
            Booking(person: .izzy, start: at(9, 30), minutes: 60, machine: .dryer),
            Booking(person: .sophie, start: at(14, 30), minutes: 90, machine: .dryer),
            Booking(person: .ruby, start: at(10, day: 1), minutes: 60, machine: .dryer),
        ]
        // Show every bar state: Izzy's load is done, and Leon has one running
        // now (clearing any sample booking it would overlap).
        bookings[0].startedAt = at(8, 2)
        bookings[0].finishedAt = at(9, 21)
        let now = Date()
        let slot = Calendar.current.dateComponents([.hour, .minute], from: now)
        let running = Booking(person: .leon, start: at(slot.hour!, slot.minute! < 30 ? 0 : 30), minutes: 90,
                              startedAt: now.addingTimeInterval(-17 * 60 - 42))
        bookings.removeAll { $0.machine == .washer && $0.overlaps(start: running.start, end: running.end) }
        bookings.append(running)
        // …and Leon's load goes in the dryer straight after.
        let drying = Booking(person: .leon, start: running.end, minutes: 60, machine: .dryer)
        bookings.removeAll { $0.machine == .dryer && $0.overlaps(start: drying.start, end: drying.end) }
        bookings.append(drying)
    }
    #endif

    /// Bookings that touch the given day, earliest first.
    func bookings(on day: Date) -> [Booking] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return bookings
            .filter { $0.overlaps(start: start, end: end) }
            .sorted { $0.start < $1.start }
    }

    /// The session on this machine that's been started and not finished yet.
    func running(on machine: Machine) -> Booking? {
        bookings.filter { $0.machine == machine && $0.isRunning }.max { $0.startedAt! < $1.startedAt! }
    }

    /// A booking on this machine whose slot is happening now but hasn't been started.
    func due(on machine: Machine, at now: Date = Date()) -> Booking? {
        bookings.first { $0.machine == machine && $0.startedAt == nil && $0.start <= now && now < $0.end }
    }

    /// Bookings still to come, soonest first.
    func upcoming(after now: Date = Date()) -> [Booking] {
        bookings.filter { $0.startedAt == nil && $0.start > now }.sorted { $0.start < $1.start }
    }

    /// The booking that would be made, or the reason it can't be.
    func check(_ person: Person?, machine: Machine, start: Date, minutes: Int) throws -> Booking {
        guard let person = person else { throw BookingError.noPerson }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        // Allow booking the slot that's currently in progress, just not one
        // that has already finished starting.
        guard end > Date() else { throw BookingError.inPast }
        if let clash = bookings.first(where: { $0.machine == machine && $0.overlaps(start: start, end: end) }) {
            throw BookingError.clash(clash)
        }
        return Booking(person: person, start: start, minutes: minutes, machine: machine)
    }

    func book(_ person: Person?, machine: Machine, start: Date, minutes: Int) throws {
        bookings.append(try check(person, machine: machine, start: start, minutes: minutes))
        save()
    }

    /// `at` can be in the past (up to 4 hours) when logging a load late.
    func start(_ booking: Booking, at date: Date = Date()) {
        let earliest = Date().addingTimeInterval(-Booking.maxBackdate)
        update(booking) { $0.startedAt = max(date, earliest); $0.finishedAt = nil }
    }

    func finish(_ booking: Booking) {
        update(booking) { $0.finishedAt = Date() }
    }

    /// Which later bookings on the same machine would have to move if this
    /// session ran `minutes` longer. Each is pushed to start when the one before
    /// it now ends, keeping its length, until the chain no longer overlaps.
    func extensionPlan(for booking: Booking, by minutes: Int) -> [SessionMove] {
        var end = booking.end.addingTimeInterval(TimeInterval(minutes * 60))
        var moves: [SessionMove] = []
        let later = bookings
            .filter { $0.machine == booking.machine && $0.id != booking.id && $0.start >= booking.start }
            .sorted { $0.start < $1.start }
        for next in later {
            guard next.start < end else { break }
            let move = SessionMove(booking: next, newStart: end)
            moves.append(move)
            end = move.newEnd
        }
        return moves
    }

    func extend(_ booking: Booking, by minutes: Int) {
        let moves = extensionPlan(for: booking, by: minutes)
        update(booking) { $0.minutes += minutes }
        for move in moves {
            update(move.booking) { $0.start = move.newStart }
        }
        guard let extended = bookings.first(where: { $0.id == booking.id }) else { return }
        if !moves.isEmpty { moveNotifier.sessionsMoved(moves, by: extended) }
    }

    private func update(_ booking: Booking, _ change: (inout Booking) -> Void) {
        guard let i = bookings.firstIndex(where: { $0.id == booking.id }) else { return }
        change(&bookings[i])
        save()
    }

    func remove(_ booking: Booking) {
        bookings.removeAll { $0.id == booking.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The sidebar's current selections, shared with the calendar so that picking
/// a day on the left shows that day on the right.
final class BookingForm: ObservableObject {
    @Published var person: Person? {
        didSet { UserDefaults.standard.set(person?.rawValue, forKey: "lastPerson") }
    }
    /// Minutes after midnight, in 30-minute steps.
    @Published var startMinutes: Int
    @Published var durationMinutes = 60
    @Published var machine: Machine = .washer
    /// Days from today of the day being viewed and booked.
    @Published var dayOffset = 0

    init() {
        person = UserDefaults.standard.string(forKey: "lastPerson").flatMap(Person.init(rawValue:))
        // Default to the next half hour.
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let next = (now.hour! * 60 + now.minute!) / 30 * 30 + 30
        startMinutes = min(next, 23 * 60 + 30)
    }

    var day: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: Date()))!
    }

    var startDate: Date {
        // Set the clock time rather than adding seconds, so DST days still work.
        Calendar.current.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: day)!
    }

    static func label(forMinutes minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())!
        return Booking.timeFormatter.string(from: date)
    }
}
