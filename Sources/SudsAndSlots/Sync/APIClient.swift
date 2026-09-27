import Foundation

/// Where the laundry server lives, and the shared secret if it wants one.
struct ServerConfig: Equatable {
    /// Root of the server, e.g. `http://192.168.0.139:8080` (no `/api/v1`).
    var baseURL: URL
    var token: String?

    static let urlKey = "serverURL"
    static let tokenKey = "serverToken"

    /// `-server <url>` (and optionally `-token <secret>`) on the command line
    /// win over what's saved. Nil means local-only.
    static var current: ServerConfig? {
        let args = ProcessInfo.processInfo.arguments
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let defaults = UserDefaults.standard
        let urlText = arg("-server") ?? defaults.string(forKey: urlKey)
        let token = arg("-token") ?? defaults.string(forKey: tokenKey)
        return urlText.flatMap { ServerConfig(urlText: $0, token: token) }
    }

    /// Accepts what people type: `192.168.0.139:8080`, `http://host:8080/`,
    /// even a pasted `…/api/v1`.
    init?(urlText: String, token: String?) {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api/v1") { text.removeLast("/api/v1".count) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        baseURL = url
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func save() {
        UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.urlKey)
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }
}

/// A booking as the server sends it. Kept apart from `Booking` so the app's
/// saved-data format doesn't change.
struct WireBooking: Codable {
    var id: UUID
    var person: Person
    var machine: Machine
    var start: Date
    var minutes: Int
    var startedAt: Date?
    var finishedAt: Date?

    init(_ b: Booking) {
        id = b.id; person = b.person; machine = b.machine; start = b.start
        minutes = b.minutes; startedAt = b.startedAt; finishedAt = b.finishedAt
    }

    var booking: Booking {
        Booking(id: id, person: person, start: start, minutes: minutes, machine: machine,
                startedAt: startedAt, finishedAt: finishedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, person, machine, start, minutes, startedAt, finishedAt
    }

    // Written by hand so unset times go out as `null` rather than missing.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(person, forKey: .person)
        try c.encode(machine, forKey: .machine)
        try c.encode(start, forKey: .start)
        try c.encode(minutes, forKey: .minutes)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
    }
}

struct WireMove: Decodable {
    var booking: WireBooking
    var newStart: Date
    /// True when the night rule sent it to the next afternoon. Older servers omit it.
    var deferred: Bool?
    var move: SessionMove { SessionMove(booking: booking.booking, newStart: newStart, deferred: deferred ?? false) }
}

/// A stored "your slot moved" message from the server.
struct ServerNotification: Decodable, Identifiable, Equatable {
    var id: Int
    var person: Person
    var kind: String
    var message: String
    var bookingId: String?
    var oldStart: Date?
    var newStart: Date?
    var createdAt: Date
    var readAt: Date?
}

/// Everything that can go wrong talking to the server, worded for people.
enum APIError: LocalizedError {
    case unreachable
    case unauthorized
    case server(status: Int, code: String?, message: String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Can't reach the laundry server."
        case .unauthorized: return "The laundry server didn't accept the token."
        case let .server(status, _, message):
            return message ?? "The laundry server had a problem (error \(status))."
        case .badResponse: return "The laundry server sent something the app didn't understand."
        }
    }
}

/// Thin async/await wrapper over the v1 API in docs/API.md.
final class APIClient {
    let config: ServerConfig
    private let session: URLSession
    private let streamSession: URLSession

    init(config: ServerConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
        // The event stream is quiet between changes (a ping every 15 s).
        let s = URLSessionConfiguration.default
        s.timeoutIntervalForRequest = 45
        s.timeoutIntervalForResource = 7 * 24 * 3600
        s.requestCachePolicy = .reloadIgnoringLocalCacheData
        streamSession = URLSession(configuration: s)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    // MARK: JSON

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = isoFormatter.date(from: text) ?? isoFractionalFormatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO-8601 date: \(text)")
        }
        return d
    }()

    /// UTC, whole seconds: `2026-09-27T20:30:00Z`.
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Requests

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         api: Bool = true) -> URLRequest {
        var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path + (api ? "/api/v1" : "") + path
        if !query.isEmpty { components.queryItems = query }
        var r = URLRequest(url: components.url!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = config.token { r.setValue(token, forHTTPHeaderField: "X-Suds-Token") }
        return r
    }

    private struct ErrorBody: Decodable { var error: String?; var message: String? }

    private func send<T: Decodable>(_ r: URLRequest, body: Encodable? = nil, as: T.Type) async throws -> T {
        var r = r
        if let body = body {
            r.httpBody = try Self.encoder.encode(AnyEncodable(body))
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let err = try? Self.decoder.decode(ErrorBody.self, from: data)
            throw APIError.server(status: http.statusCode, code: err?.error, message: err?.message)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            print("[sync] couldn't decode \(r.url?.path ?? ""): \(error)")
            throw APIError.badResponse
        }
    }

    // MARK: Endpoints

    struct Health: Decodable { var ok: Bool; var version: Int? }
    struct Version: Decodable { var version: Int }
    struct BookingList: Decodable { var version: Int; var bookings: [WireBooking] }
    struct OneBooking: Decodable { var version: Int; var booking: WireBooking }
    struct Extended: Decodable { var version: Int; var booking: WireBooking; var moves: [WireMove] }
    struct Imported: Decodable { var version: Int; var imported: Int }
    struct Moves: Decodable { var moves: [WireMove] }
    struct Notifications: Decodable { var notifications: [ServerNotification] }
    private struct OK: Decodable { var ok: Bool? }

    func health() async throws -> Health {
        try await send(request("GET", "/health", api: false), as: Health.self)
    }

    func version() async throws -> Int {
        try await send(request("GET", "/version"), as: Version.self).version
    }

    func bookings() async throws -> BookingList {
        try await send(request("GET", "/bookings"), as: BookingList.self)
    }

    struct ChainResult: Decodable { var version: Int; var bookings: [WireBooking]; var moves: [WireMove]? }

    private struct ChainBody: Encodable {
        struct Stage: Encodable { var machine: Machine; var minutes: Int }
        var person: Person; var start: Date; var stages: [Stage]; var push: Bool
        init(_ person: Person, _ start: Date, _ stages: [(Machine, Int)], _ push: Bool) {
            self.person = person; self.start = start; self.push = push
            self.stages = stages.map { Stage(machine: $0.0, minutes: $0.1) }
        }
    }

    func bookChain(person: Person, start: Date, stages: [(Machine, Int)], push: Bool = false) async throws -> ChainResult {
        try await send(request("POST", "/bookings/chain"), body: ChainBody(person, start, stages, push), as: ChainResult.self)
    }

    /// Dry run of `bookChain`: the moves it would make, or the error it would get.
    func chainPlan(person: Person, start: Date, stages: [(Machine, Int)], push: Bool) async throws -> [SessionMove] {
        try await send(request("POST", "/bookings/chain-plan"), body: ChainBody(person, start, stages, push), as: Moves.self)
            .moves.map(\.move)
    }

    func start(_ id: UUID, at: Date) async throws -> OneBooking {
        struct Body: Encodable { var at: Date }
        return try await send(request("POST", "/bookings/\(id.uuidString)/start"), body: Body(at: at), as: OneBooking.self)
    }

    func finish(_ id: UUID) async throws -> OneBooking {
        try await send(request("POST", "/bookings/\(id.uuidString)/finish"), as: OneBooking.self)
    }

    func extensionPlan(_ id: UUID, minutes: Int) async throws -> [SessionMove] {
        let r = request("GET", "/bookings/\(id.uuidString)/extend-plan",
                        query: [URLQueryItem(name: "minutes", value: String(minutes))])
        return try await send(r, as: Moves.self).moves.map(\.move)
    }

    func move(_ id: UUID, minutes: Int) async throws -> Extended {
        struct Body: Encodable { var minutes: Int }
        return try await send(request("POST", "/bookings/\(id.uuidString)/move"), body: Body(minutes: minutes), as: Extended.self)
    }

    func extend(_ id: UUID, minutes: Int) async throws -> Extended {
        struct Body: Encodable { var minutes: Int }
        return try await send(request("POST", "/bookings/\(id.uuidString)/extend"), body: Body(minutes: minutes), as: Extended.self)
    }

    func remove(_ id: UUID) async throws -> Int {
        try await send(request("DELETE", "/bookings/\(id.uuidString)"), as: Version.self).version
    }

    func importBookings(_ bookings: [Booking]) async throws -> Imported {
        struct Body: Encodable { var bookings: [WireBooking] }
        return try await send(request("POST", "/import"), body: Body(bookings: bookings.map(WireBooking.init)), as: Imported.self)
    }

    func notifications(for person: Person, unreadOnly: Bool = false) async throws -> [ServerNotification] {
        var query = [URLQueryItem(name: "person", value: person.rawValue)]
        if unreadOnly { query.append(URLQueryItem(name: "unread", value: "1")) }
        return try await send(request("GET", "/notifications", query: query), as: Notifications.self).notifications
    }

    func markRead(_ id: Int) async throws {
        _ = try await send(request("POST", "/notifications/\(id)/read"), as: OK.self)
    }

    /// Server-sent events: yields the version from each `changed` event. Ends
    /// (or throws) when the connection drops; the caller reconnects.
    func events() -> AsyncThrowingStream<Int, Error> {
        var r = request("GET", "/events")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 45
        let session = streamSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: r)
                    guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
                    if http.statusCode == 401 { throw APIError.unauthorized }
                    guard http.statusCode == 200 else { throw APIError.server(status: http.statusCode, code: nil, message: nil) }
                    var event = "message", data = ""
                    // `lines` skips blank lines, so an event is dispatched when its data arrives.
                    for try await line in bytes.lines {
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if event == "changed" || event == "message",
                               let v = try? Self.decoder.decode(Version.self, from: Data(data.utf8)) {
                                continuation.yield(v.version)
                            }
                            event = "message"; data = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Lets `send` take any Encodable body.
private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
