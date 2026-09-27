import SwiftUI

enum BarAction: Equatable {
    /// `minutesAgo` > 0 logs a load that was put on earlier without pressing Start.
    case start(minutesAgo: Int)
    case finish, cancel
    case extend(minutes: Int)
    /// Slide the session later, pushing whoever's after it along.
    case moveAlong(minutes: Int)
}

/// The choices offered under Move along.
let moveOptions = [15, 30, 45, 60, 120]

/// "Started earlier" choices, up to the 4-hour limit.
let backdateOptions = [15, 30, 45, 60, 90, 120, 180, 240]

func agoLabel(_ minutes: Int) -> String {
    switch minutes {
    case ..<60: return "\(minutes) min ago"
    case 60: return "1 hour ago"
    case 90: return "1½ hours ago"
    default: return "\(minutes / 60) hours ago"
    }
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
        case .extend: return "Extend"
        case .moveAlong: return "Move"
        }
    }

    var question: String {
        let whose = "\(booking.person.name)'s \(booking.machine.name.lowercased())"
        switch action {
        case .start(let ago) where ago > 0: return "log \(whose) session as started \(agoLabel(ago))"
        case .start: return "start \(whose) session"
        case .finish: return "mark \(whose) session as finished"
        case .cancel: return "cancel \(whose) booking"
        case .extend(let minutes): return "extend \(whose) session by \(extendLabel(minutes))"
        case .moveAlong(let minutes): return "move \(whose) session along by \(extendLabel(minutes))"
        }
    }

    /// `moves` are the sessions an extension would push later (empty otherwise).
    func detail(moves: [SessionMove], forgotten: [Booking] = []) -> String {
        switch action {
        case .finish:
            let elapsed = Date().timeIntervalSince(booking.startedAt ?? Date())
            return "Running for \(BookingBar.clock(elapsed)) · \(booking.timeRange)"
        case .start where !forgotten.isEmpty:
            let names = forgotten.map { "\($0.person.name)'s" }.joined(separator: " and ")
            return "\(booking.timeRange)\n\n\(names) load is still marked as running on the \(booking.machine.name.lowercased()), so it'll be marked finished."
        case .start(let ago) where ago > 0:
            let at = Date().addingTimeInterval(TimeInterval(-ago * 60))
            return "Started at \(Booking.timeFormatter.string(from: at)) · booked \(booking.timeRange)"
        case .start, .cancel:
            return booking.timeRange
        case .moveAlong(let minutes):
            let start = booking.start.addingTimeInterval(TimeInterval(minutes * 60))
            let end = start.addingTimeInterval(TimeInterval(booking.minutes * 60))
            var lines = ["Now \(Booking.timeFormatter.string(from: start)) – \(Booking.timeFormatter.string(from: end))."]
            lines += moves.map { Self.moveLine($0, actor: booking.person) }
            return lines.joined(separator: "\n")
        case .extend(let minutes):
            let newEnd = booking.end.addingTimeInterval(TimeInterval(minutes * 60))
            var lines = ["Ends at \(Booking.timeFormatter.string(from: newEnd)) instead."]
            lines += moves.map { Self.moveLine($0, actor: booking.person) }
            lines += ["", "⚠️ " + extendWarning]
            return lines.joined(separator: "\n")
        }
    }
}

/// "tomorrow 12:00 PM – 2:00 PM" (or the weekday) for a night-deferred move.
func nextAfternoon(_ move: SessionMove) -> String {
    let day = Calendar.current.isDateInTomorrow(move.newStart) ? "tomorrow"
        : CalendarView.weekday.string(from: move.newStart)
    return "\(day) \(move.newTimeRange)"
}

extension PendingBarAction {
    /// One line per moved session: other people are told, your own next stage
    /// just follows.
    static func moveLine(_ move: SessionMove, actor: Person?) -> String {
        let name = move.booking.person.name
        let what = move.booking.machine.name.lowercased()
        if move.booking.person == actor {
            return "Your \(what) follows, now \(move.newTimeRange)."
        }
        if move.deferred {
            return "\(name)'s \(what) would run past 10 PM, so it moves to \(nextAfternoon(move)) and they'll be told."
        }
        return "\(name)'s \(what) moves to \(move.newTimeRange) and they'll be told."
    }
}

extension Confirmer {
    /// Ask "Are you sure…" for a Start / Finish / Cancel choice, then do it.
    func ask(_ pending: PendingBarAction, store: BookingStore) {
        var moves: [SessionMove] = []
        var forgotten: [Booking] = []
        switch pending.action {
        case .extend(let minutes):
            moves = store.extensionPlan(for: pending.booking, by: minutes)
        case .moveAlong(let minutes):
            moves = (try? store.movePlan(for: pending.booking, by: minutes)) ?? []
        case .start:
            forgotten = store.forgottenLoads(before: pending.booking)
        default:
            break
        }
        ask(pending.question, detail: pending.detail(moves: moves, forgotten: forgotten),
            confirmTitle: pending.buttonTitle,
            destructive: pending.action == .cancel) {
            switch pending.action {
            case .start(let ago):
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                store.start(pending.booking, at: Date().addingTimeInterval(TimeInterval(-ago * 60)))
            case .finish:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                store.finish(pending.booking)
            case .cancel:
                withAnimation { store.remove(pending.booking) }
            case .extend(let minutes):
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation { store.extend(pending.booking, by: minutes) }
            case .moveAlong(let minutes):
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation {
                    do { try store.move(pending.booking, by: minutes) } catch let e as BookingError {
                        store.syncError = e.errorDescription
                    } catch {}
                }
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
            Menu {
                Button { ask(.start(minutesAgo: 0)) } label: { Label("Now", systemImage: "play.fill") }
                Section("Already running? Started…") {
                    ForEach(backdateOptions, id: \.self) { minutes in
                        Button("\(agoLabel(minutes)) (\(Self.clockTime(minutesAgo: minutes)))") {
                            ask(.start(minutesAgo: minutes))
                        }
                    }
                }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
        }
        if booking.isRunning {
            Button { ask(.finish) } label: { Label("Finished", systemImage: "stop.fill") }
        }
        if booking.finishedAt == nil {
            ExtendMenu(booking: booking)
        }
        if booking.startedAt == nil && booking.finishedAt == nil {
            MoveAlongMenu(booking: booking)
        }
        Button(role: .destructive) { ask(.cancel) } label: {
            Label("Cancel Booking", systemImage: "xmark")
        }
    }

    private func ask(_ action: BarAction) {
        confirmer.ask(PendingBarAction(action: action, booking: booking), store: store)
    }

    static func clockTime(minutesAgo: Int) -> String {
        Booking.timeFormatter.string(from: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }
}

/// "Extend" with its preset lengths and Custom…. Later bookings that would
/// overlap get pushed back; the confirmation says who.
struct ExtendMenu: View {
    let booking: Booking

    var body: some View {
        Menu {
            ExtendMenuItems(booking: booking)
        } label: {
            Label("Extend", systemImage: "clock.arrow.circlepath")
        }
    }
}

/// "Move along" with the lengths that are actually possible (not onto a load
/// that's in, not into the past). Whoever's after it gets pushed along.
struct MoveAlongMenu: View {
    let booking: Booking

    var body: some View {
        Menu {
            MoveAlongItems(booking: booking)
        } label: {
            Label("Move along", systemImage: "arrow.right.to.line")
        }
    }
}

struct MoveAlongItems: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var confirmer: Confirmer
    let booking: Booking

    var body: some View {
        let possible = moveOptions.filter { (try? store.movePlan(for: booking, by: $0)) != nil }
        if possible.isEmpty {
            Text("Can't move: the next slot is taken by a load that's already in")
        }
        ForEach(possible, id: \.self) { minutes in
            let pushes = (try? store.movePlan(for: booking, by: minutes))?.contains { $0.booking.person != booking.person } ?? false
            Button {
                confirmer.ask(PendingBarAction(action: .moveAlong(minutes: minutes), booking: booking), store: store)
            } label: {
                Label("+ \(extendLabel(minutes))", systemImage: pushes ? "arrow.right.circle" : "clock")
            }
        }
    }
}

/// One booking on the timeline. The ⋯ button opens the session menu; only
/// that button is the menu, so the bar itself stays put while it's open.
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

    var body: some View { bar }

    private var bar: some View {
        HStack(spacing: 6) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(booking.person.name)
                        .font(.system(size: compact ? 14 : 17, weight: .bold, design: .rounded))
                        .layoutPriority(1)
                    // A one-line bar in a narrow column only has room for the name.
                    if !twoLine && width >= 240 {
                        timeText
                    }
                }
                if twoLine {
                    timeText
                }
            }
            .lineLimit(1)
            Spacer(minLength: 2)
            Menu {
                SessionMenuItems(booking: booking)
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: compact ? 16 : 20))
                    .foregroundColor(.white)
                    .opacity(0.9)
                    // Generous tap area without making the bar any taller.
                    .frame(width: 44, height: height)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Adjust \(booking.person.name)'s session")
        }
        .foregroundColor(.white.opacity(isDone ? 0.55 : 1))
        .padding(.leading, compact ? 8 : 10)
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
    }

    private var timeText: some View {
        Text(width < 240 ? booking.shortTimeRange : booking.timeRange)
            .font(.system(size: compact ? 11 : width < 240 ? 12 : 13, weight: .medium))
            .monospacedDigit()
            .opacity(0.9)
            .minimumScaleFactor(0.7)
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
