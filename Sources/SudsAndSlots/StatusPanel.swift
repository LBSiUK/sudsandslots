import Combine
import SwiftUI

/// Left panel: what's on each machine now (with its Adjust menu), who's next,
/// and the big + that opens the booking form.
struct StatusPanel: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var form: BookingForm
    @EnvironmentObject var confirmer: Confirmer
    @State private var showingBooking = false
    @State private var showingQuickAdd = false
    @State private var showingServer = false
    @State private var showingNotifications = false
    /// Refreshed every 15 s for "who's next" and "in 5 min". The per-second
    /// timers tick on their own, so an open menu isn't rebuilt every second.
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            // No scrolling: everything is sized to fit an iPad Mini 4 in
            // landscape even with both machines in use.
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Right now")
                ForEach(Machine.allCases) { machine in
                    current(on: machine)
                }
                SectionLabel("Who's next")
                    .padding(.top, 6)
                whosNext
            }
            Spacer(minLength: 10)
            bookButton
        }
        .padding(20)
        .onReceive(tick) { now = $0 }
        .sheet(isPresented: $showingBooking) {
            BookingSheet()
                .environmentObject(store)
                .environmentObject(form)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppBadge(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suds & Slots")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                // Sync state doubles as the way into the server settings.
                Button { showingServer = true } label: { SyncStatusView() }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showingServer) {
                        ServerSettingsView()
                            .environmentObject(store)
                            .preferredColorScheme(.dark)
                    }
            }
            Spacer(minLength: 4)
            if store.syncState != .localOnly {
                Button { showingNotifications = true } label: {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notifications")
                .sheet(isPresented: $showingNotifications) {
                    NotificationsView(person: form.person)
                        .environmentObject(store)
                        .preferredColorScheme(.dark)
                }
            }
        }
        .alert("Couldn't save that", isPresented: Binding(get: { store.syncError != nil },
                                                          set: { if !$0 { store.syncError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.syncError ?? "")
        }
    }

    // MARK: - Right now

    @ViewBuilder
    private func current(on machine: Machine) -> some View {
        if machine == .rack, let booking = store.running(on: machine) ?? store.due(on: machine, at: now) {
            slimCard(booking, state: booking.isRunning ? "in use" : "their turn")
        } else if let booking = store.running(on: machine) {
            card(color: booking.person.color) {
                caption("\(machine.name) · in use", systemImage: machine.systemImage)
                nameLine(booking)
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(booking.startedAt ?? context.date)
                    let remaining = TimeInterval(booking.minutes * 60) - elapsed
                    HStack(spacing: 10) {
                        timerBox("Elapsed", systemImage: "stopwatch", value: BookingBar.clock(elapsed))
                        timerBox(remaining >= 0 ? "Remaining" : "Over time", systemImage: "hourglass",
                                 value: BookingBar.clock(abs(remaining)), warning: remaining < 0)
                    }
                }
                .padding(.top, 2)
                actionButtons(for: booking)
            }
        } else if let booking = store.due(on: machine, at: now) {
            card(color: booking.person.color) {
                caption("\(machine.name) · their turn", systemImage: machine.systemImage)
                nameLine(booking)
                Text("Not started yet · ends \(Self.until(booking.end, from: now))")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.85)
                actionButtons(for: booking)
            }
        } else {
            card(color: Color.white.opacity(0.08)) {
                caption("\(machine.name) · free", systemImage: machine.systemImage)
                Text(freeUntil(on: machine))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    /// One-row card for the drying rack: its sessions are long and need no
    /// live timers, so just who, until when, and the session menu.
    private func slimCard(_ booking: Booking, state: String) -> some View {
        card(color: booking.person.color) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    caption("\(booking.machine.name) · \(state)", systemImage: booking.machine.systemImage)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(booking.person.name)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("until \(Booking.timeFormatter.string(from: booking.end))")
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.85)
                    }
                    // Who has the rack after this one, so they can plan around it.
                    if let next = store.upcoming(after: now).first(where: {
                        $0.machine == booking.machine && $0.id != booking.id
                    }) {
                        Text("Next: \(next.person.name), \(whenText(next))")
                            .font(.system(size: 13, weight: .semibold))
                            .opacity(0.85)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    SessionMenuItems(booking: booking)
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Adjust this session")
            }
        }
    }

    private func nameLine(_ booking: Booking) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(booking.person.name)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(booking.timeRange)
                .font(.system(size: 14, weight: .medium))
                .opacity(0.85)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// One button per action, only the ones that make sense right now:
    /// running → Finished, Extend, Cancel; not started → Start (tap = now,
    /// hold = started earlier), Extend, Reschedule, Cancel.
    private func actionButtons(for booking: Booking) -> some View {
        HStack(spacing: 8) {
            if booking.canStart {
                Menu {
                    Section("Already running? Started…") {
                        ForEach(backdateOptions, id: \.self) { minutes in
                            Button("\(agoLabel(minutes)) (\(SessionMenuItems.clockTime(minutesAgo: minutes)))") {
                                ask(.start(minutesAgo: minutes), booking)
                            }
                        }
                    }
                } label: {
                    actionTile("Start", systemImage: "play.fill", fill: BookingBar.startGreen)
                } primaryAction: {
                    ask(.start(minutesAgo: 0), booking)
                }
                .accessibilityHint("Hold for started earlier")
            }
            if booking.isRunning {
                Button { ask(.finish, booking) } label: {
                    actionTile("Finished", systemImage: "stop.fill", fill: BookingBar.finishRed)
                }
                .buttonStyle(.plain)
            }
            if booking.finishedAt == nil {
                Menu { ExtendMenuItems(booking: booking) } label: {
                    actionTile("Extend", systemImage: "clock.arrow.circlepath", fill: Self.extendBlue)
                }
            }
            if booking.startedAt == nil && booking.finishedAt == nil {
                Menu { MoveAlongItems(booking: booking) } label: {
                    actionTile("Reschedule", systemImage: "calendar.badge.clock", fill: .orange)
                }
            }
            Button { ask(.cancel, booking) } label: {
                actionTile("Cancel", systemImage: "xmark", fill: BookingBar.finishRed)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    static let extendBlue = Color(red: 0.10, green: 0.42, blue: 0.95)

    private func ask(_ action: BarAction, _ booking: Booking) {
        confirmer.ask(PendingBarAction(action: action, booking: booking), store: store)
    }

    private func actionTile(_ title: String, systemImage: String, fill: Color = Color.black.opacity(0.3)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(fill, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.7)))
    }

    private func freeUntil(on machine: Machine) -> String {
        guard let next = store.upcoming(after: now).first(where: { $0.machine == machine }) else {
            return "Nothing booked"
        }
        return "Free until \(next.person.name)'s slot \(Self.until(next.start, from: now))"
    }

    // MARK: - Who's next

    @ViewBuilder
    private var whosNext: some View {
        let upcoming = Array(store.upcoming(after: now).prefix(2))
        if upcoming.isEmpty {
            Text("Nobody's booked in yet.")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        // The very next one in its person's colour, the one after in grey.
        ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, booking in
            HStack(spacing: 8) {
                Text(booking.person.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Image(systemName: booking.machine.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.8)
                Spacer(minLength: 4)
                Text(whenText(booking))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(index == 0 ? 1 : 0.7)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(index == 0 ? booking.person.color : Theme.control,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// "9:00 PM · in 25 min" today, "Tomorrow 9:00 AM" otherwise.
    private func whenText(_ booking: Booking) -> String {
        let time = Booking.timeFormatter.string(from: booking.start)
        if Calendar.current.isDate(booking.start, inSameDayAs: now) {
            return "\(time) · \(Self.until(booking.start, from: now))"
        }
        return "\(Self.dayName(booking.start)) \(time)"
    }

    // MARK: - Book

    /// Quick add (the fast path, big and white) beside Book (the full form).
    private var bookButton: some View {
        HStack(spacing: 10) {
            Button {
                showingQuickAdd = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24, weight: .bold))
                    Text("Quick add")
                        .font(.system(size: 21, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingQuickAdd) {
                QuickAddSheet()
                    .environmentObject(store)
                    .preferredColorScheme(.dark)
            }
            Button {
                showingBooking = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.white.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Book a Slot")
        }
    }

    // MARK: - Pieces

    private func card<Content: View>(color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func caption(_ text: String, systemImage: String) -> some View {
        Label(text.uppercased(), systemImage: systemImage)
            .font(.system(size: 12, weight: .bold))
            .opacity(0.85)
    }

    private func timerBox(_ title: String, systemImage: String, value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.system(size: 10, weight: .bold))
                .opacity(0.85)
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(warning ? .yellow : .white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(BookingBar.runningBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.5)))
    }

    // MARK: - Formatting

    /// "in 45 min", "in 2 h 5 min", or "tomorrow at 9:00 AM" style.
    static func until(_ date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if !Calendar.current.isDate(date, inSameDayAs: now) {
            let day = dayName(date)
            return "\(day == "Tomorrow" ? "tomorrow" : day) at \(Booking.timeFormatter.string(from: date))"
        }
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    static func dayName(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return CalendarView.weekday.string(from: date)
    }
}
