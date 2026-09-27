import Combine
import SwiftUI

/// Left panel: what's on each machine now (with its Adjust menu), who's next,
/// and the big + that opens the booking form.
struct StatusPanel: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var form: BookingForm
    @State private var showingBooking = false
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
            VStack(alignment: .leading, spacing: 1) {
                Text("Suds & Slots")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("LAUNDRY TRACKER")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    // MARK: - Right now

    @ViewBuilder
    private func current(on machine: Machine) -> some View {
        if let booking = store.running(on: machine) {
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
                adjustButton(for: booking)
            }
        } else if let booking = store.due(on: machine, at: now) {
            card(color: booking.person.color) {
                caption("\(machine.name) · their turn", systemImage: machine.systemImage)
                nameLine(booking)
                Text("Not started yet · ends \(Self.until(booking.end, from: now))")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.85)
                adjustButton(for: booking)
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

    /// "Adjust this session" (Start / Finished / Extend / Cancel) beside a
    /// direct "Extend session" menu.
    private func adjustButton(for booking: Booking) -> some View {
        HStack(spacing: 10) {
            Menu {
                SessionMenuItems(booking: booking)
            } label: {
                cardButtonLabel("Adjust this session", systemImage: "slider.horizontal.3")
            }
            Menu {
                ExtendMenuItems(booking: booking)
            } label: {
                cardButtonLabel("Extend", systemImage: "clock.arrow.circlepath")
            }
            .frame(maxWidth: 104)
            .accessibilityLabel("Extend session")
        }
        .padding(.top, 6)
    }

    private func cardButtonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.7)))
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

    private var bookButton: some View {
        Button {
            showingBooking = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .bold))
                Text("Book a Slot")
                    .font(.system(size: 21, weight: .semibold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
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
