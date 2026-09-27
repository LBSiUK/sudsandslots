import SwiftUI

enum BarAction {
    case start, finish, cancel
}

/// A bar button tap waiting for "Are you sure you want to:" confirmation.
struct PendingBarAction {
    let action: BarAction
    let booking: Booking

    var buttonTitle: String {
        switch action {
        case .start: return "Start"
        case .finish: return "Finish"
        case .cancel: return "Cancel Booking"
        }
    }

    var message: String {
        let name = booking.person.name
        switch action {
        case .start:
            return "Start \(name)'s wash (\(booking.timeRange))?"
        case .finish:
            let elapsed = Date().timeIntervalSince(booking.startedAt ?? Date())
            return "Mark \(name)'s wash as finished after \(BookingBar.clock(elapsed))?"
        case .cancel:
            return "Cancel \(name)'s booking (\(booking.timeRange))?"
        }
    }
}

enum ConfirmCopy {
    static let title = "Are you sure you want to:"
}

/// One booking on the timeline:
/// [Start | running timers + Finished | Done] [Cancel] Name ……… time range
struct BookingBar: View {
    let booking: Booking
    let width: CGFloat
    let height: CGFloat
    /// Called when a button is tapped; the calendar asks for confirmation.
    let onAction: (BarAction) -> Void

    /// Short bars (30-minute slots) get icon-only controls so they still fit.
    private var compact: Bool { height < 30 }
    private var controlHeight: CGFloat { compact ? max(height - 4, 12) : min(height - 10, 32) }
    private var controlFont: Font { .system(size: compact ? 11 : 14, weight: .semibold) }

    /// Only today's bookings that haven't ended yet can be started.
    private var canStart: Bool {
        booking.startedAt == nil && Calendar.current.isDateInToday(booking.start) && Date() < booking.end
    }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            if booking.finishedAt != nil {
                doneBadge
            } else if booking.startedAt != nil {
                runningTimers
            } else if canStart {
                pill("Start", systemImage: "play.fill", color: Self.startGreen) { onAction(.start) }
            }
            if booking.finishedAt == nil {
                pill("Cancel", systemImage: "xmark", color: Color.black.opacity(0.3)) { onAction(.cancel) }
            }
            Text(booking.person.name)
                .font(.system(size: compact ? 14 : 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(booking.timeRange)
                .font(.system(size: compact ? 12 : 15, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(.white)
        .padding(.horizontal, compact ? 8 : 10)
        .frame(width: width, height: height)
        .background(booking.person.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    // MARK: - Pieces

    private var runningTimers: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(booking.startedAt ?? context.date)
            let remaining = TimeInterval(booking.minutes * 60) - elapsed
            HStack(spacing: compact ? 5 : 8) {
                timer(systemImage: "stopwatch", value: Self.clock(elapsed))
                timer(systemImage: "hourglass",
                      value: remaining >= 0 ? Self.clock(remaining) : "+" + Self.clock(-remaining))
                    .foregroundColor(remaining >= 0 ? .white : Color.yellow)
                pill("Finished", systemImage: "stop.fill", color: Self.finishRed) { onAction(.finish) }
            }
            .padding(.leading, compact ? 6 : 10)
            .padding(.trailing, compact ? 2 : 3)
            .frame(height: compact ? controlHeight : controlHeight + 6)
            .background(Self.runningBlue, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1))
        }
    }

    private var doneBadge: some View {
        let taken = (booking.finishedAt ?? Date()).timeIntervalSince(booking.startedAt ?? Date())
        return HStack(spacing: 4) {
            Image(systemName: "checkmark")
            if !compact { Text("Done") }
            Text(Self.clock(taken)).monospacedDigit()
        }
        .font(controlFont)
        .padding(.horizontal, compact ? 6 : 10)
        .frame(height: controlHeight)
        .background(Color.black.opacity(0.3), in: Capsule())
    }

    private func timer(systemImage: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 10 : 13, weight: .semibold))
            Text(value)
                .font(.system(size: compact ? 12 : 15, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func pill(_ title: String, systemImage: String, color: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 9 : 11, weight: .bold))
                if !compact { Text(title) }
            }
            .font(controlFont)
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 6 : 10)
            .frame(minWidth: compact ? controlHeight + 8 : nil)
            .frame(height: controlHeight)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Helpers

    static let startGreen = Color(red: 0.13, green: 0.72, blue: 0.30)
    static let finishRed = Color(red: 0.90, green: 0.18, blue: 0.18)
    static let runningBlue = Color(red: 0.05, green: 0.32, blue: 0.90)

    /// 5:07 under an hour, 1:05:07 over.
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
