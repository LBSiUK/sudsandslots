import SwiftUI

/// Left panel: what's washing now (with its controls), who's next, and the
/// big + that opens the booking form.
struct StatusPanel: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var form: BookingForm
    @EnvironmentObject var confirmer: Confirmer
    @State private var showingBooking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)
            // Ticks every second so timers, "in 5 min" and who's-next stay current.
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Current wash")
                        currentWash(now: context.date)
                        SectionLabel("Who's next")
                            .padding(.top, 12)
                        whosNext(now: context.date)
                    }
                }
            }
            bookButton
                .padding(.top, 12)
        }
        .padding(20)
        .sheet(isPresented: $showingBooking) {
            BookingSheet()
                .environmentObject(store)
                .environmentObject(form)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppBadge(size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suds & Slots")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("LAUNDRY TRACKER")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    // MARK: - Current wash

    @ViewBuilder
    private func currentWash(now: Date) -> some View {
        if let booking = store.running {
            let elapsed = now.timeIntervalSince(booking.startedAt ?? now)
            let remaining = TimeInterval(booking.minutes * 60) - elapsed
            card(color: booking.person.color) {
                caption("Now washing")
                Text(booking.person.name)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(booking.timeRange)
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.85)
                HStack(spacing: 10) {
                    timerBox("Elapsed", systemImage: "stopwatch", value: BookingBar.clock(elapsed))
                    timerBox(remaining >= 0 ? "Remaining" : "Over time", systemImage: "hourglass",
                             value: BookingBar.clock(abs(remaining)), warning: remaining < 0)
                }
                .padding(.top, 6)
                HStack(spacing: 10) {
                    bigButton("Finished", systemImage: "stop.fill", color: BookingBar.finishRed) {
                        confirmer.ask(PendingBarAction(action: .finish, booking: booking), store: store)
                    }
                    cancelButton(for: booking)
                }
                .padding(.top, 4)
            }
        } else if let booking = store.due(at: now) {
            card(color: booking.person.color) {
                caption("It's their turn")
                Text(booking.person.name)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("\(booking.timeRange) · ends \(Self.until(booking.end, from: now))")
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.85)
                HStack(spacing: 10) {
                    bigButton("Start", systemImage: "play.fill", color: BookingBar.startGreen) {
                        confirmer.ask(PendingBarAction(action: .start, booking: booking), store: store)
                    }
                    cancelButton(for: booking)
                }
                .padding(.top, 8)
            }
        } else {
            card(color: Color.white.opacity(0.08)) {
                caption("Machine is free")
                Text("Nothing washing")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(freeUntil(now: now))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    private func freeUntil(now: Date) -> String {
        guard let next = store.upcoming(after: now).first else { return "No bookings coming up" }
        return "Free until \(next.person.name)'s slot \(Self.until(next.start, from: now))"
    }

    // MARK: - Who's next

    @ViewBuilder
    private func whosNext(now: Date) -> some View {
        let upcoming = Array(store.upcoming(after: now).prefix(3))
        if let next = upcoming.first {
            card(color: next.person.color) {
                Text(next.person.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("\(Self.dayName(next.start)) · \(next.timeRange)")
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.9)
                if Calendar.current.isDate(next.start, inSameDayAs: now) {
                    Text("Starts \(Self.until(next.start, from: now))")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            ForEach(upcoming.dropFirst()) { booking in
                HStack(spacing: 10) {
                    Circle().fill(booking.person.color).frame(width: 12, height: 12)
                    Text(booking.person.name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(Self.dayName(booking.start)) \(Booking.timeFormatter.string(from: booking.start))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            Text("Nobody's booked in yet.")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Book

    private var bookButton: some View {
        Button {
            showingBooking = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 30, weight: .bold))
                Text("Book a Slot")
                    .font(.system(size: 21, weight: .semibold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    private func card<Content: View>(color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.8)
            .opacity(0.8)
    }

    private func timerBox(_ title: String, systemImage: String, value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.system(size: 11, weight: .bold))
                .opacity(0.85)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(warning ? .yellow : .white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BookingBar.runningBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.5)))
    }

    private func bigButton(_ title: String, systemImage: String, color: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
    }

    private func cancelButton(for booking: Booking) -> some View {
        bigButton("Cancel", systemImage: "xmark", color: Color.black.opacity(0.3)) {
            confirmer.ask(PendingBarAction(action: .cancel, booking: booking), store: store)
        }
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
