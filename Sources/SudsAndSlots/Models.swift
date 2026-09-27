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

struct Booking: Codable, Identifiable, Equatable {
    var id = UUID()
    var person: Person
    var start: Date
    var minutes: Int

    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }

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

enum BookingError: LocalizedError {
    case noPerson
    case inPast
    case clash(Booking)

    var errorDescription: String? {
        switch self {
        case .noPerson: return "Pick who's washing first."
        case .inPast:   return "That start time has already passed."
        case .clash(let b): return "That clashes with \(b.person.name)'s slot (\(b.timeRange))."
        }
    }
}

/// Holds every booking and persists them as JSON in UserDefaults.
final class BookingStore: ObservableObject {
    @Published private(set) var bookings: [Booking] = []

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
        ]
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

    func book(_ person: Person?, start: Date, minutes: Int) throws {
        guard let person = person else { throw BookingError.noPerson }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        // Allow booking the slot that's currently in progress, just not one
        // that has already finished starting.
        guard end > Date() else { throw BookingError.inPast }
        if let clash = bookings.first(where: { $0.overlaps(start: start, end: end) }) {
            throw BookingError.clash(clash)
        }
        bookings.append(Booking(person: person, start: start, minutes: minutes))
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
