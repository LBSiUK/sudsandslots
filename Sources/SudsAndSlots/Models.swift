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

/// Something that can be booked. Order here is the calendar's column order
/// and the order a booking's stages run in.
enum Machine: String, CaseIterable, Codable, Identifiable {
    case washer, dryer, rack

    var id: String { rawValue }

    var name: String {
        switch self {
        case .washer: return "Washer"
        case .dryer: return "Dryer"
        case .rack: return "Drying rack"
        }
    }

    var systemImage: String {
        switch self {
        case .washer: return "drop.fill"
        case .dryer: return "wind"
        case .rack: return "tshirt"
        }
    }

    /// The booking form's yes/no question.
    var question: String {
        switch self {
        case .washer: return "Are you using the washing machine?"
        case .dryer: return "Are you using the dryer?"
        case .rack: return "Are you using the drying rack?"
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .washer: return 120
        case .dryer: return 90
        case .rack: return 360
        }
    }

    /// Longest estimate the form allows.
    var maxMinutes: Int { self == .rack ? 24 * 60 : 6 * 60 }

    /// The rack goes 1-6 h an hour at a time, then 2 hours at a time to 24 h;
    /// the machines go in 15-minute steps.
    private var stops: [Int] {
        self == .rack
            ? Array(stride(from: 60, through: 360, by: 60)) + Array(stride(from: 480, through: 1440, by: 120))
            : Array(stride(from: 15, through: maxMinutes, by: 15))
    }

    /// The next estimate up (or down) from `minutes`, snapping onto the steps.
    func step(_ minutes: Int, up: Bool) -> Int {
        up ? (stops.first { $0 > minutes } ?? stops.last!)
           : (stops.last { $0 < minutes } ?? stops.first!)
    }

    func canStep(_ minutes: Int, up: Bool) -> Bool {
        up ? minutes < stops.last! : minutes > stops.first!
    }

    /// Long enough that the finish time is worth showing next to the length.
    func showsEndTime(_ minutes: Int) -> Bool { self == .rack && minutes > 360 }
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

    /// "8:00 – 9:30 AM", or "11:30 AM – 1:00 PM" across noon: for narrow spaces.
    var shortTimeRange: String {
        let f = Booking.timeFormatter
        let startText = f.string(from: start), endText = f.string(from: end)
        let sameHalf = startText.suffix(2) == endText.suffix(2)
        return sameHalf ? "\(startText.dropLast(3)) – \(endText)" : "\(startText) – \(endText)"
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
    case nothingChosen
    case inPast
    case clash(Booking)

    var errorDescription: String? {
        switch self {
        case .noPerson: return "Pick who's washing first."
        case .nothingChosen: return "Say yes to at least one of the washing machine, dryer or drying rack."
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
    /// Pushed past 10 PM, so moved to the next afternoon instead.
    var deferred = false

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
///
/// With a laundry server configured (Settings, or `-server <url>`) it also
/// keeps in step with the server through `SyncService`: changes apply here at
/// once, then go up; the server's answer wins. Without one it's local-only.
final class BookingStore: ObservableObject {
    @Published private(set) var bookings: [Booking] = []
    /// localOnly / connecting / synced / offline.
    @Published private(set) var syncState: SyncState = .localOnly
    /// The last thing that went wrong talking to the server, worded for people.
    @Published var syncError: String?
    var moveNotifier: SessionMoveNotifier = LogSessionMoveNotifier()

    /// Set while talking to a server.
    private(set) var sync: SyncService?
    private(set) var serverConfig: ServerConfig?

    /// This iPad's own bookings (local-only mode).
    private let localKey = "bookings.v1"
    /// Last copy of the server's bookings, so the screen isn't empty at launch.
    private let serverCacheKey = "bookings.server.v1"
    private var key: String { sync == nil ? localKey : serverCacheKey }

    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        if !demo, let config = ServerConfig.current {
            connect(to: config)
        } else {
            bookings = load(localKey)
        }
        #if DEBUG
        if demo { seedDemo() }
        #endif
    }

    private func load(_ key: String) -> [Booking] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Booking].self, from: data) else { return [] }
        // Drop anything older than a month so the store doesn't grow forever.
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return saved.filter { $0.end > cutoff }
    }

    // MARK: Server mode

    /// Starts syncing with a server (the first time, this iPad's own bookings
    /// are uploaded to it). Pass nil to go back to local-only.
    func connect(to config: ServerConfig?) {
        sync?.stop()
        sync = nil
        serverConfig = config
        syncError = nil
        guard let config = config else {
            syncState = .localOnly
            bookings = load(localKey)
            return
        }
        let local = load(localKey)
        let service = SyncService(config: config, store: self)
        sync = service
        bookings = load(serverCacheKey)
        service.start(localBookings: local)
    }

    /// Saves the server settings and switches to them (nil disconnects).
    func useServer(_ config: ServerConfig?) {
        if let config = config { config.save() } else { ServerConfig.clearSaved() }
        connect(to: config)
    }

    /// Fetch everything again now (e.g. a pull to refresh).
    func refreshFromServer() { sync?.refresh() }

    func setSyncState(_ state: SyncState) {
        if syncState != state { syncState = state }
    }

    /// The server's full list replaces ours.
    func adoptServerBookings(_ list: [Booking]) {
        guard sync != nil else { return }
        if list != bookings { bookings = list }
        save()
    }

    /// One booking as the server now has it.
    func adoptServerBooking(_ booking: Booking) {
        guard sync != nil else { return }
        if let i = bookings.firstIndex(where: { $0.id == booking.id }) {
            if bookings[i] != booking { bookings[i] = booking }
        } else {
            bookings.append(booking)
        }
        save()
    }

    /// Swaps bookings made optimistically for the server's copies (new ids).
    func replaceOptimistic(_ ids: [UUID], with made: [Booking]) {
        guard sync != nil else { return }
        bookings.removeAll { ids.contains($0.id) || made.map(\.id).contains($0.id) }
        bookings += made
        save()
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
            Booking(person: .izzy, start: at(10, 30), minutes: 360, machine: .rack),
            Booking(person: .sophie, start: at(16), minutes: 360, machine: .rack),
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
        // A one-stage chain: same checks, and it syncs.
        try bookChain(person, start: start, stages: [(machine, minutes)])
    }

    /// One booking per chosen machine, run back to back: the washer starts at
    /// `start`, the dryer when the washer ends, the rack when the one before
    /// it ends. Checks every stage before adding any, so it's all or nothing.
    func checkChain(_ person: Person?, start: Date, stages: [(Machine, Int)]) throws -> [Booking] {
        guard !stages.isEmpty else { throw BookingError.nothingChosen }
        var at = start
        return try stages.map { machine, minutes in
            let booking = try check(person, machine: machine, start: at, minutes: minutes)
            at = booking.end
            return booking
        }
    }

    func bookChain(_ person: Person?, start: Date, stages: [(Machine, Int)]) throws {
        let chain = try checkChain(person, start: start, stages: stages)
        bookings += chain
        save()
        if let person = person {
            sync?.bookChain(person: person, start: start, stages: stages, push: false, optimistic: chain)
        }
    }

    /// Dry run of a chain that may shove other people's bookings along
    /// (Quick add): which not-yet-started bookings would move. Stages go back
    /// to back as in `checkChain`; on each stage's machine, overlapping
    /// bookings are pushed, in start order, to begin when the one before them
    /// now ends, keeping their length. Overlapping a started (or finished)
    /// booking is still a clash.
    func pushPlan(_ person: Person?, start: Date, stages: [(Machine, Int)]) throws -> [SessionMove] {
        try placePushing(person, start: start, stages: stages).moves
    }

    /// `push: false` is plain `bookChain`; `push: true` shoves bookings along
    /// as `pushPlan` describes, and their people are told.
    func bookChain(_ person: Person?, start: Date, stages: [(Machine, Int)], push: Bool) throws {
        guard push, let person = person else {
            try bookChain(person, start: start, stages: stages)
            return
        }
        let (chain, moves) = try placePushing(person, start: start, stages: stages)
        for move in moves {
            update(move.booking) { $0.start = move.newStart }
        }
        bookings += chain
        save()
        if let sync = sync {
            // The server notifies the people who were moved.
            sync.bookChain(person: person, start: start, stages: stages, push: true, optimistic: chain)
        } else if !moves.isEmpty, let first = chain.first {
            moveNotifier.sessionsMoved(moves, by: first)
        }
    }

    private func placePushing(_ person: Person?, start: Date, stages: [(Machine, Int)]) throws
        -> (bookings: [Booking], moves: [SessionMove]) {
        guard !stages.isEmpty else { throw BookingError.nothingChosen }
        guard let person = person else { throw BookingError.noPerson }
        var at = start
        var chain: [Booking] = []
        var moves: [SessionMove] = []
        for (machine, minutes) in stages {
            let stage = Booking(person: person, start: at, minutes: minutes, machine: machine)
            guard stage.end > Date() else { throw BookingError.inPast }
            at = stage.end
            chain.append(stage)
            let others = bookings
                .filter { $0.machine == machine && $0.end > stage.start }
                .sorted { $0.start < $1.start }
            moves += try Self.cascade(placed: [(stage.start, stage.end)], candidates: others, blockStarted: true)
        }
        return (chain, moves)
    }

    /// `at` can be in the past (up to 4 hours) when logging a load late.
    func start(_ booking: Booking, at date: Date = Date()) {
        let earliest = Date().addingTimeInterval(-Booking.maxBackdate)
        let at = max(date, earliest)
        update(booking) { $0.startedAt = at; $0.finishedAt = nil }
        sync?.start(booking, at: at)
    }

    func finish(_ booking: Booking) {
        update(booking) { $0.finishedAt = Date() }
        sync?.finish(booking)
    }

    /// Which later bookings on the same machine would have to move if this
    /// session ran `minutes` longer. Each is pushed to start when the one before
    /// it now ends, keeping its length, until the chain no longer overlaps.
    func extensionPlan(for booking: Booking, by minutes: Int) -> [SessionMove] {
        let end = booking.end.addingTimeInterval(TimeInterval(minutes * 60))
        let later = bookings
            .filter { $0.machine == booking.machine && $0.id != booking.id && $0.start >= booking.start }
            .sorted { $0.start < $1.start }
        return (try? Self.cascade(placed: [(booking.start, end)], candidates: later, blockStarted: false)) ?? []
    }

    /// Pushes `candidates` (one machine, in start order) off everything placed
    /// so far: a candidate that overlaps is moved to when what it overlaps
    /// ends, keeping its length; one that doesn't stays put and counts as
    /// placed. Night rule: a push that would start it at or after 10 PM, or in
    /// the small hours of a later day, sends it to 12:00 PM the next day
    /// instead (then it's checked for overlaps again). Mirrors the backend.
    static func cascade(placed initial: [(Date, Date)], candidates: [Booking],
                        blockStarted: Bool) throws -> [SessionMove] {
        var placed = initial
        var moves: [SessionMove] = []
        func overlapEnd(_ start: Date, _ end: Date) -> Date? {
            placed.filter { start < $0.1 && $0.0 < end }.map { $0.1 }.max()
        }
        for booking in candidates {
            guard let firstEnd = overlapEnd(booking.start, booking.end) else {
                placed.append((booking.start, booking.end))
                continue
            }
            if blockStarted && (booking.startedAt != nil || booking.finishedAt != nil) {
                throw BookingError.clash(booking)
            }
            let length = TimeInterval(booking.minutes * 60)
            var start = firstEnd
            var deferred = false
            while true {
                if let later = nightDeferral(start, original: booking.start) {
                    start = later
                    deferred = true
                }
                guard let end = overlapEnd(start, start.addingTimeInterval(length)) else { break }
                start = end
            }
            moves.append(SessionMove(booking: booking, newStart: start, deferred: deferred))
            placed.append((start, start.addingTimeInterval(length)))
        }
        return moves
    }

    /// Where the night rule sends a pushed start, or nil if it's fine.
    static func nightDeferral(_ start: Date, original: Date) -> Date? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: start)
        let day = cal.startOfDay(for: start)
        if hour >= 22 {
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            return cal.date(bySettingHour: 12, minute: 0, second: 0, of: next)
        }
        if hour < 12 && day > cal.startOfDay(for: original) {
            return cal.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }
        return nil
    }

    func extend(_ booking: Booking, by minutes: Int) {
        let moves = extensionPlan(for: booking, by: minutes)
        update(booking) { $0.minutes += minutes }
        for move in moves {
            update(move.booking) { $0.start = move.newStart }
        }
        // A server tells the people whose sessions moved itself.
        if let sync = sync { sync.extend(booking, by: minutes); return }
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
        sync?.remove(booking)
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
    /// The form's yes/no answers and time estimates, per machine.
    @Published var uses: [Machine: Bool] = [.washer: true, .dryer: false, .rack: false]
    @Published var minutes: [Machine: Int] = Dictionary(uniqueKeysWithValues: Machine.allCases.map { ($0, $0.defaultMinutes) })

    /// Back to yes for the washer, no for the rest, and the default estimates.
    func resetUsage() {
        uses = [.washer: true, .dryer: false, .rack: false]
        minutes = Dictionary(uniqueKeysWithValues: Machine.allCases.map { ($0, $0.defaultMinutes) })
    }

    /// The chosen machines in the order they run, with their estimates.
    var stages: [(Machine, Int)] {
        Machine.allCases.filter { uses[$0] == true }.map { ($0, minutes[$0] ?? $0.defaultMinutes) }
    }
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
