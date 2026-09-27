import Foundation
import UIKit

/// How the app is getting on with the laundry server.
enum SyncState: Equatable {
    /// No server configured (or `-demo`): bookings live on this iPad only.
    case localOnly
    case connecting
    case synced
    /// A server is configured but can't be reached right now.
    case offline

    var label: String {
        switch self {
        case .localOnly: return "Local only"
        case .connecting: return "Connecting…"
        case .synced: return "Synced"
        case .offline: return "Offline"
        }
    }
}

/// Keeps a `BookingStore` in step with the server: loads on launch, listens
/// to the event stream (polling /version as a fallback), refreshes on return
/// to the foreground, and sends the store's changes up one at a time.
///
/// Everything here runs on the main thread; network waits happen in tasks.
final class SyncService {
    let client: APIClient
    private weak var store: BookingStore?

    private var version: Int?
    private var eventsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Mutations run one after another so later ones see earlier results.
    private var mutationTail: Task<Void, Never>?
    private var pendingMutations = 0
    private var refreshWanted = false
    /// Optimistic bookings get their own ids; the server hands out new ones.
    private var serverIDs: [UUID: UUID] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private var stopped = false

    private static let importedKey = "sync.importedTo"

    init(config: ServerConfig, store: BookingStore) {
        client = APIClient(config: config)
        self.store = store
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// Uploads this iPad's bookings the first time it meets this server, then
    /// loads and starts listening.
    func start(localBookings: [Booking]) {
        store?.setSyncState(.connecting)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
            self?.startEvents()
        }
        let server = client.config.baseURL.absoluteString
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var imported = UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? []
            if !imported.contains(server) {
                do {
                    if !localBookings.isEmpty {
                        let result = try await self.client.importBookings(localBookings)
                        print("[sync] imported \(result.imported) local booking(s) to \(server)")
                    }
                    imported.append(server)
                    UserDefaults.standard.set(imported, forKey: Self.importedKey)
                } catch {
                    // Try again next launch; carry on syncing meanwhile.
                    print("[sync] import failed: \(error.localizedDescription)")
                }
            }
            guard !self.stopped else { return }
            self.refresh()
            self.startEvents()
            self.startPolling()
        }
    }

    func stop() {
        stopped = true
        eventsTask?.cancel()
        pollTask?.cancel()
        refreshTask?.cancel()
        if let o = foregroundObserver { NotificationCenter.default.removeObserver(o) }
        foregroundObserver = nil
    }

    // MARK: Staying fresh

    /// Fetches every booking and hands them to the store. Held off while
    /// changes are still on their way up, so it can't undo them on screen.
    func refresh() {
        guard !stopped else { return }
        guard pendingMutations == 0 else { refreshWanted = true; return }
        guard refreshTask == nil else { refreshWanted = true; return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let list = try await self.client.bookings()
                if self.pendingMutations == 0 && !self.stopped {
                    self.version = list.version
                    self.store?.adoptServerBookings(list.bookings.map(\.booking))
                    self.store?.setSyncState(.synced)
                    if case .unauthorized? = self.lastConnectionError { self.store?.syncError = nil }
                    self.lastConnectionError = nil
                } else {
                    self.refreshWanted = true
                }
            } catch is CancellationError {
            } catch {
                self.connectionFailed(error)
            }
            self.refreshTask = nil
            if self.refreshWanted && self.pendingMutations == 0 && !self.stopped {
                self.refreshWanted = false
                self.refresh()
            }
        }
    }

    private var lastConnectionError: APIError?

    private func connectionFailed(_ error: Error) {
        guard !stopped else { return }
        store?.setSyncState(.offline)
        if case .unauthorized? = error as? APIError {
            lastConnectionError = .unauthorized
            store?.syncError = APIError.unauthorized.errorDescription
        }
    }

    private func versionSeen(_ v: Int) {
        if v != version { refresh() }
    }

    /// Server-sent events, reconnecting with backoff (1 s doubling to 30 s).
    private func startEvents() {
        guard !stopped, eventsTask == nil else { return }
        eventsTask = Task { @MainActor [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let client = self?.client else { return }
                do {
                    for try await v in client.events() {
                        delay = 1
                        self?.versionSeen(v)
                    }
                } catch {
                    if Task.isCancelled { break }
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
                // Catch anything missed while disconnected.
                self?.refresh()
            }
            self?.eventsTask = nil
        }
    }

    /// Cheap /version check every 10 s in case the event stream is down.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                guard !Task.isCancelled, let self = self else { return }
                do {
                    let v = try await self.client.version()
                    if self.store?.syncState == .offline { self.refresh() } else { self.versionSeen(v) }
                } catch is CancellationError {
                } catch {
                    if self.pendingMutations == 0 { self.connectionFailed(error) }
                }
            }
        }
    }

    // MARK: Changes

    private func serverID(_ id: UUID) -> UUID { serverIDs[id] ?? id }

    /// Queues a server call. The store has already changed its own copy.
    private func mutate(_ what: String, _ operation: @escaping (APIClient) async throws -> Void) {
        pendingMutations += 1
        let previous = mutationTail
        mutationTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self = self, !self.stopped else { return }
            do {
                try await operation(self.client)
                self.store?.syncError = nil
                self.store?.setSyncState(.synced)
            } catch {
                print("[sync] \(what) failed: \(error.localizedDescription)")
                let message = error.localizedDescription
                if case .unreachable? = error as? APIError {
                    self.store?.syncError = "Can't reach the laundry server, so that change wasn't saved."
                    self.store?.setSyncState(.offline)
                } else {
                    self.store?.syncError = message
                }
            }
            self.pendingMutations -= 1
            if self.pendingMutations == 0 {
                // Adopt the server's full picture (undoes a failed change).
                self.refreshWanted = false
                self.refresh()
            }
        }
    }

    func bookChain(person: Person, start: Date, stages: [(Machine, Int)], push: Bool, optimistic: [Booking]) {
        mutate("booking") { [weak self] client in
            let result = try await client.bookChain(person: person, start: start, stages: stages, push: push)
            let made = result.bookings.map(\.booking)
            for (local, server) in zip(optimistic, made) { self?.serverIDs[local.id] = server.id }
            self?.store?.replaceOptimistic(optimistic.map(\.id), with: made)
            for move in result.moves ?? [] {
                var moved = move.booking.booking
                moved.start = move.newStart
                self?.store?.adoptServerBooking(moved)
            }
        }
    }

    func start(_ booking: Booking, at date: Date) {
        let id = booking.id
        mutate("start") { [weak self] client in
            guard let self = self else { return }
            let result = try await client.start(self.serverID(id), at: date)
            self.store?.adoptServerBooking(result.booking.booking)
        }
    }

    func finish(_ booking: Booking) {
        let id = booking.id
        mutate("finish") { [weak self] client in
            guard let self = self else { return }
            let result = try await client.finish(self.serverID(id))
            self.store?.adoptServerBooking(result.booking.booking)
        }
    }

    func extend(_ booking: Booking, by minutes: Int) {
        let id = booking.id
        mutate("extend") { [weak self] client in
            guard let self = self else { return }
            let result = try await client.extend(self.serverID(id), minutes: minutes)
            self.store?.adoptServerBooking(result.booking.booking)
            for move in result.moves {
                var moved = move.booking.booking
                moved.start = move.newStart
                self.store?.adoptServerBooking(moved)
            }
        }
    }

    func remove(_ booking: Booking) {
        let id = booking.id
        mutate("cancel") { [weak self] client in
            guard let self = self else { return }
            do {
                _ = try await client.remove(self.serverID(id))
            } catch APIError.server(404, _, _) {
                // Already gone on the server: that's what we wanted.
            }
        }
    }
}
