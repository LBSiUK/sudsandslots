import SwiftUI

enum BarAction {
    case start, finish, cancel
}

/// A session action waiting for confirmation.
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

    var question: String {
        let whose = "\(booking.person.name)'s \(booking.machine.name.lowercased())"
        switch action {
        case .start: return "start \(whose) session"
        case .finish: return "mark \(whose) session as finished"
        case .cancel: return "cancel \(whose) booking"
        }
    }

    var detail: String {
        switch action {
        case .finish:
            let elapsed = Date().timeIntervalSince(booking.startedAt ?? Date())
            return "Running for \(BookingBar.clock(elapsed)) · \(booking.timeRange)"
        case .start, .cancel:
            return booking.timeRange
        }
    }
}

extension Confirmer {
    /// Ask "Are you sure…" for a Start / Finish / Cancel choice, then do it.
    func ask(_ pending: PendingBarAction, store: BookingStore) {
        ask(pending.question, detail: pending.detail, confirmTitle: pending.buttonTitle,
            destructive: pending.action == .cancel) {
            switch pending.action {
            case .start:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                store.start(pending.booking)
            case .finish:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                store.finish(pending.booking)
            case .cancel:
                withAnimation { store.remove(pending.booking) }
            }
        }
    }
}

/// The "Adjust this session" menu contents: only the actions that make sense
/// for the booking right now. Each one still asks for confirmation.
struct SessionMenuItems: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var confirmer: Confirmer
    let booking: Booking

    var body: some View {
        if booking.canStart {
            Button { ask(.start) } label: { Label("Start", systemImage: "play.fill") }
        }
        if booking.isRunning {
            Button { ask(.finish) } label: { Label("Finished", systemImage: "stop.fill") }
        }
        Button(role: .destructive) { ask(.cancel) } label: {
            Label("Cancel Booking", systemImage: "xmark")
        }
    }

    private func ask(_ action: BarAction) {
        confirmer.ask(PendingBarAction(action: action, booking: booking), store: store)
    }
}

/// One booking on the timeline. Tapping anywhere on it opens the session menu.
///   [status] Name  time range ……… (…)
struct BookingBar: View {
    let booking: Booking
    let width: CGFloat
    let height: CGFloat

    /// Short bars (30-minute slots) get a smaller type size.
    private var compact: Bool { height < 30 }
    private var isDone: Bool { booking.finishedAt != nil }
    /// Tall enough to put the time range on its own line.
    private var twoLine: Bool { height >= 48 }

    var body: some View {
        Menu {
            SessionMenuItems(booking: booking)
        } label: {
            bar
        }
        .accessibilityLabel("Adjust \(booking.person.name)'s session")
    }

    private var bar: some View {
        HStack(spacing: 6) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(booking.person.name)
                        .font(.system(size: compact ? 14 : 17, weight: .bold, design: .rounded))
                        .layoutPriority(1)
                    if !twoLine {
                        timeText
                    }
                }
                if twoLine {
                    timeText
                }
            }
            .lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: compact ? 16 : 20))
                .opacity(0.9)
        }
        .foregroundColor(.white.opacity(isDone ? 0.55 : 1))
        .padding(.horizontal, compact ? 8 : 10)
        .frame(width: width, height: height)
        .background(isDone ? Self.doneGrey : booking.person.color,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A finished session keeps a thin stripe of its person's colour.
        .overlay(alignment: .leading) {
            if isDone {
                booking.person.color.opacity(0.6)
                    .frame(width: 4)
                    .padding(.vertical, 6)
                    .clipShape(Capsule())
                    .padding(.leading, 3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(isDone ? 0.12 : 0.25)))
        .shadow(color: .black.opacity(isDone ? 0 : 0.3), radius: 6, y: 3)
        .contentShape(Rectangle())
    }

    private var timeText: some View {
        Text(booking.timeRange)
            .font(.system(size: compact ? 11 : 13, weight: .medium))
            .monospacedDigit()
            .opacity(0.9)
            .minimumScaleFactor(0.8)
    }

    /// In use = stopwatch on blue, done = tick; nothing for a session that hasn't begun.
    @ViewBuilder
    private var statusIcon: some View {
        let size: CGFloat = compact ? 18 : 24
        if booking.finishedAt != nil {
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.3), in: Circle())
        } else if booking.isRunning {
            Image(systemName: "stopwatch")
                .font(.system(size: size * 0.55, weight: .bold))
                .frame(width: size, height: size)
                .background(Self.runningBlue, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
        }
    }

    // MARK: - Helpers

    static let startGreen = Color(red: 0.13, green: 0.72, blue: 0.30)
    static let finishRed = Color(red: 0.90, green: 0.18, blue: 0.18)
    static let runningBlue = Color(red: 0.05, green: 0.32, blue: 0.90)
    static let doneGrey = Color(white: 0.24)

    /// 5:07 under an hour, 1:05:07 over.
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
