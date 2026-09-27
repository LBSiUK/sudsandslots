import SwiftUI

/// Lightning-quick booking: when (Now or +N minutes, on a 5-minute grid),
/// what (washer on by default, each with −/+ for its time), then tap a name.
/// Tapping the name is the booking, so a wash starting now is
/// Quick add → name → confirm. If the time overlaps bookings that haven't
/// started, it can shove them along (with a warning, and they're told).
struct QuickAddSheet: View {
    @EnvironmentObject var store: BookingStore
    @Environment(\.dismiss) private var dismiss
    /// Its own, because iOS 15 can't show the main screen's alert over a sheet.
    @StateObject private var confirmer = Confirmer()
    @State private var error: BookingError?

    /// Minutes after the 5-minute-aligned "now". nil = the suggested next free time.
    @State private var offset: Int? = 0
    @State private var uses: Set<Machine> = [.washer]
    @State private var minutes: [Machine: Int] = Dictionary(uniqueKeysWithValues:
        Machine.allCases.map { ($0, $0.defaultMinutes) })
    /// Wash at the chosen time but put the dryer/rack later, when they're free.
    @State private var dryLater = false
    /// Captured when the sheet opens so the chips don't shift under a finger.
    @State private var base = QuickAddSheet.alignedNow()

    private let offsets = [0, 5, 10, 15, 30, 60]

    private var stages: [(Machine, Int)] {
        Machine.allCases.filter { uses.contains($0) }.map { ($0, minutes[$0] ?? $0.defaultMinutes) }
    }

    /// What booking at `start` would do to everyone else.
    private enum Outcome {
        case free
        case shoves([SessionMove])
        case blocked
    }

    private func outcome(at start: Date) -> Outcome {
        guard let moves = try? store.pushPlan(.leon, start: start, stages: stages) else { return .blocked }
        return moves.isEmpty ? .free : .shoves(moves)
    }

    /// The earliest 5-minute slot (within a day) where every chosen stage fits
    /// back to back without moving anyone.
    private var nextFree: Date? {
        guard !stages.isEmpty else { return nil }
        for step in 1...(24 * 12) {
            let candidate = base.addingTimeInterval(TimeInterval(step * 5 * 60))
            if case .free = outcome(at: candidate) { return candidate }
        }
        return nil
    }

    /// When the washer is free at the chosen time but the dryer/rack straight
    /// after isn't: the first time the rest of the chain fits after the wash,
    /// and whether anyone has the washer booked in between (so the washing
    /// must come out the moment it's done).
    private struct LaterPlan {
        let wash: (Machine, Int)
        let washEnd: Date
        let rest: [(Machine, Int)]
        let restStart: Date
        let washerNeededInGap: Bool
    }

    private var laterPlan: LaterPlan? {
        guard offset != nil, let wash = stages.first, wash.0 == .washer, stages.count > 1 else { return nil }
        guard let moves = try? store.pushPlan(.leon, start: start, stages: [wash]), moves.isEmpty else { return nil }
        let washEnd = start.addingTimeInterval(TimeInterval(wash.1 * 60))
        let rest = Array(stages.dropFirst())
        let first = Self.alignedNow(washEnd)
        for step in 0...(24 * 12) {
            let candidate = first.addingTimeInterval(TimeInterval(step * 5 * 60))
            if (try? store.checkChain(.leon, start: candidate, stages: rest)) != nil {
                let needed = store.bookings.contains {
                    $0.machine == .washer && $0.overlaps(start: washEnd, end: candidate)
                }
                return LaterPlan(wash: wash, washEnd: washEnd, rest: rest, restStart: candidate,
                                 washerNeededInGap: needed)
            }
        }
        return nil
    }

    private var start: Date {
        if let offset = offset { return base.addingTimeInterval(TimeInterval(offset * 60)) }
        return nextFree ?? base
    }

    var body: some View {
        let current = stages.isEmpty ? Outcome.free : outcome(at: start)
        let busy: Bool = { if case .free = current { return false }; return true }()
        let suggestion = busy || offset == nil ? nextFree : nil
        // The clash banner sits above everything, title bar included, and
        // pushes the whole sheet down rather than covering any of it.
        VStack(spacing: 0) {
        if let blocker = blocker(at: base) {
            nowBanner(blocker)
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        NavigationView {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("When?") {
                    HStack(spacing: 8) {
                        ForEach(offsets, id: \.self) { minutes in
                            let at = base.addingTimeInterval(TimeInterval(minutes * 60))
                            let result = stages.isEmpty ? Outcome.free : outcome(at: at)
                            chip(title: minutes == 0 ? "Now" : "+\(minutes < 60 ? "\(minutes)" : "1 h")",
                                 subtitle: Self.time(at), selected: offset == minutes,
                                 marker: Self.marker(result)) { offset = minutes }
                        }
                    }
                    if let suggestion = suggestion {
                        chip(title: "Next free", subtitle: Self.time(suggestion), selected: offset == nil,
                             highlight: true) { offset = nil }
                            // Green edge even when not chosen, so it reads as the way out.
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(BookingBar.startGreen, lineWidth: offset == nil ? 0 : 2.5))
                            .frame(maxWidth: 170)
                    }
                    warning(for: current)
                    if busy, let plan = laterPlan {
                        laterCard(plan)
                    }
                }
                section("What? Tap to include, −/+ for the time") {
                    HStack(spacing: 8) {
                        ForEach(Machine.allCases) { machine in
                            machineTile(machine)
                        }
                    }
                }
                section("Who? Tap your name to book") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(Person.allCases) { person in
                            Button { book(for: person) } label: {
                                Text(person.name)
                                    .font(.system(size: 21, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 56)
                                    .background(person.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(stages.isEmpty)
                            .opacity(stages.isEmpty ? 0.4 : 1)
                        }
                    }
                }
            }
            .padding(20)
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Can't book that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error?.errorDescription ?? "")
            }
        }
        .navigationViewStyle(.stack)
        }
        .animation(.easeOut(duration: 0.2), value: blocker(at: base)?.id)
        .background(Color(.systemBackground).ignoresSafeArea())
        .confirmationAlert(confirmer)
        .onChange(of: offset) { _ in dryLater = false }
        .onChange(of: uses) { _ in dryLater = false }
        .onAppear {
            base = Self.alignedNow()
            // Busy right now? Start on the next free time; shoving people
            // along should be a deliberate choice.
            if case .free = outcome(at: base) {} else { offset = nil }
        }
    }

    @ViewBuilder
    private func warning(for outcome: Outcome) -> some View {
        switch outcome {
        case .free:
            EmptyView()
        case .shoves(let moves):
            Label {
                Text("This shoves along " + moves.map { "\($0.booking.person.name) (to \(Self.time($0.newStart)))" }
                    .joined(separator: ", ") + ". They'll be told.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.orange)
        case .blocked:
            Label("Someone's load is already in then, so it can't be moved. Pick Next free.",
                  systemImage: "xmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
        }
    }

    /// The first unfinished booking in the way if the chosen stages started at
    /// `start`, checking each stage's machine for its stretch of the chain.
    private func blocker(at start: Date) -> Booking? {
        var at = start
        for (machine, length) in stages {
            let end = at.addingTimeInterval(TimeInterval(length * 60))
            if let b = store.bookings
                .filter({ $0.machine == machine && $0.finishedAt == nil && $0.overlaps(start: at, end: end) })
                .min(by: { $0.start < $1.start }) {
                return b
            }
            at = end
        }
        return nil
    }

    /// Red banner at the very top when "Now" would clash with someone's cycle.
    private func nowBanner(_ blocker: Booking) -> some View {
        let until = Self.time(blocker.end)
        let green = Text("Next free").bold().foregroundColor(BookingBar.startGreen)
        let message: Text = blocker.startedAt == nil
            ? Text("Someone else already has a cycle running until \(until). You can start one now but it will move their cycle, or use ") + green + Text(".")
            : Text("Someone else already has a cycle running until \(until). It's already in, so it can't be moved: use ") + green + Text(".")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 20))
            message
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(.red)
        .padding(12)
        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.6)))
    }

    /// "Wash now, dry later": a selectable card under the When warning.
    private func laterCard(_ plan: LaterPlan) -> some View {
        let rest = plan.rest.map { $0.0.name.lowercased() }.joined(separator: " then ")
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { dryLater.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: dryLater ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wash at \(Self.time(start)), \(rest) later at \(Self.time(plan.restStart))")
                        .font(.system(size: 16, weight: .bold))
                    Text(plan.washerNeededInGap
                         ? "Someone needs the washer before then, so take your washing out as soon as it finishes (\(Self.time(plan.washEnd)))."
                         : "Nobody needs the washer in between, but please empty it when it's done (\(Self.time(plan.washEnd))).")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(plan.washerNeededInGap ? .yellow : Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(12)
            .background(dryLater ? BookingBar.startGreen.opacity(0.35) : Theme.control, in: shape)
            .overlay(shape.stroke(dryLater ? BookingBar.startGreen : Theme.controlStroke, lineWidth: dryLater ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func book(for person: Person) {
        if dryLater, let plan = laterPlan {
            bookSplit(for: person, plan: plan)
            return
        }
        let start = start, stages = stages
        do {
            let moves = try store.pushPlan(person, start: start, stages: stages)
            // The stages back to back from the start, as they'll be booked.
            var at = start
            var lines: [String] = stages.map { machine, minutes in
                let stage = Booking(person: person, start: at, minutes: minutes, machine: machine)
                at = stage.end
                return "\(machine.name): \(stage.timeRange)"
            }
            if !moves.isEmpty {
                lines += [""] + moves.map { "⚠️ \($0.booking.person.name)'s \($0.booking.machine.name.lowercased()) moves to \($0.newTimeRange) and they'll be told." }
            }
            confirmer.ask("book \(person.name) in", detail: lines.joined(separator: "\n"),
                          confirmTitle: moves.isEmpty ? "Book" : "Book & Shove") {
                do {
                    try store.bookChain(person, start: start, stages: stages, push: !moves.isEmpty)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                } catch let e as BookingError {
                    error = e
                } catch {}
            }
        } catch let e as BookingError {
            error = e
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } catch {}
    }

    /// Wash at the chosen time, the rest of the chain later.
    private func bookSplit(for person: Person, plan: LaterPlan) {
        let start = start
        do {
            let wash = try store.checkChain(person, start: start, stages: [plan.wash])
            let rest = try store.checkChain(person, start: plan.restStart, stages: plan.rest)
            var lines = (wash + rest).map { "\($0.machine.name): \($0.timeRange)" }
            if plan.washerNeededInGap {
                lines += ["", "⚠️ Someone needs the washer after you: take your washing out as soon as it finishes at \(Self.time(plan.washEnd))."]
            }
            confirmer.ask("book \(person.name) in", detail: lines.joined(separator: "\n"), confirmTitle: "Book") {
                do {
                    try store.bookChain(person, start: start, stages: [plan.wash], push: false)
                    try store.bookChain(person, start: plan.restStart, stages: plan.rest, push: false)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                } catch let e as BookingError {
                    error = e
                } catch {}
            }
        } catch let e as BookingError {
            error = e
        } catch {}
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
    }

    /// Big tile: tap the top half to include/leave out, −/+ adjust the time
    /// (and switch it on).
    private func machineTile(_ machine: Machine) -> some View {
        let on = uses.contains(machine)
        let value = minutes[machine] ?? machine.defaultMinutes
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: 6) {
            Button {
                if on { uses.remove(machine) } else { uses.insert(machine) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    Image(systemName: machine.systemImage)
                    Text(machine.name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                stepButton("minus", machine: machine, up: false)
                VStack(spacing: 0) {
                    Text(extendLabel(value))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                    if machine.showsEndTime(value) {
                        Text("until \(Self.time(stageEnd(machine)))")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .opacity(0.8)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                stepButton("plus", machine: machine, up: true)
            }
        }
        .foregroundColor(.white)
        .padding(6)
        .background(on ? Color.accentColor : Theme.control, in: shape)
        .overlay(shape.stroke(on ? Color.white.opacity(0.9) : Theme.controlStroke, lineWidth: on ? 2 : 1))
    }

    /// When this machine's stage would end: stages run back to back from the
    /// chosen start, counting this one as included.
    private func stageEnd(_ machine: Machine) -> Date {
        var at = start
        for m in Machine.allCases where uses.contains(m) || m == machine {
            at = at.addingTimeInterval(TimeInterval((minutes[m] ?? m.defaultMinutes) * 60))
            if m == machine { break }
        }
        return at
    }

    private func stepButton(_ symbol: String, machine: Machine, up: Bool) -> some View {
        let value = minutes[machine] ?? machine.defaultMinutes
        let disabled = !machine.canStep(value, up: up)
        return Button {
            minutes[machine] = machine.step(value, up: up)
            uses.insert(machine)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 32)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel("\(up ? "More" : "Less") time on the \(machine.name.lowercased())")
    }

    private func chip(title: String, subtitle: String, systemImage: String? = nil, selected: Bool,
                      highlight: Bool = false, marker: Marker? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if let systemImage = systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.75)
            }
            .frame(height: 50)
        }
        .buttonStyle(TileButtonStyle(selected: selected, tint: highlight ? BookingBar.startGreen : Color.accentColor))
        // A small corner badge: orange = would shove someone, red = blocked.
        .overlay(alignment: .topTrailing) {
            if let marker = marker {
                Image(systemName: marker.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(marker.color)
                    .padding(4)
            }
        }
        .opacity(marker == .blocked && !selected ? 0.4 : 1)
    }

    private enum Marker {
        case shoves, blocked
        var symbol: String { self == .shoves ? "arrow.right.circle.fill" : "xmark.circle.fill" }
        var color: Color { self == .shoves ? .orange : .red }
    }

    private static func marker(_ outcome: Outcome) -> Marker? {
        switch outcome {
        case .free: return nil
        case .shoves: return .shoves
        case .blocked: return .blocked
        }
    }

    /// Now, rounded up to the next 5 minutes (unchanged if already on one).
    static func alignedNow(_ now: Date = Date()) -> Date {
        let step: TimeInterval = 5 * 60
        return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    static func time(_ date: Date) -> String {
        Booking.timeFormatter.string(from: date)
    }
}
