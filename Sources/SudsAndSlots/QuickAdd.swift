import SwiftUI

/// Lightning-quick booking: when (Now or +N minutes, on a 5-minute grid),
/// what (washer on by default), then tap a name. Tapping the name is the
/// booking, so a wash starting now is Quick add → name → confirm.
struct QuickAddSheet: View {
    @EnvironmentObject var store: BookingStore
    @Environment(\.dismiss) private var dismiss
    /// Its own, because iOS 15 can't show the main screen's alert over a sheet.
    @StateObject private var confirmer = Confirmer()
    @State private var error: BookingError?

    /// Minutes after the 5-minute-aligned "now". nil = the suggested next free time.
    @State private var offset: Int? = 0
    @State private var uses: Set<Machine> = [.washer]
    /// Captured when the sheet opens so the chips don't shift under a finger.
    @State private var base = QuickAddSheet.alignedNow()

    private let offsets = [0, 5, 10, 15, 30, 60]

    private var stages: [(Machine, Int)] {
        Machine.allCases.filter { uses.contains($0) }.map { ($0, $0.defaultMinutes) }
    }

    /// Whether the chain fits at a given start, using the synced bookings.
    private func fits(_ start: Date) -> Bool {
        (try? store.checkChain(.leon, start: start, stages: stages)) != nil
    }

    /// If the chosen start clashes, the earliest 5-minute slot (within a day)
    /// where every chosen stage fits back to back.
    private var nextFree: Date? {
        guard !stages.isEmpty else { return nil }
        for step in 1...(24 * 12) {
            let candidate = base.addingTimeInterval(TimeInterval(step * 5 * 60))
            if fits(candidate) { return candidate }
        }
        return nil
    }

    private var start: Date {
        if let offset = offset { return base.addingTimeInterval(TimeInterval(offset * 60)) }
        return nextFree ?? base
    }

    var body: some View {
        let clashes = !stages.isEmpty && !fits(start)
        let suggestion = clashes || offset == nil ? nextFree : nil
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                section("When?") {
                    HStack(spacing: 8) {
                        ForEach(offsets, id: \.self) { minutes in
                            let at = base.addingTimeInterval(TimeInterval(minutes * 60))
                            chip(title: minutes == 0 ? "Now" : "+\(minutes < 60 ? "\(minutes)" : "1 h")",
                                 subtitle: Self.time(at), selected: offset == minutes,
                                 dimmed: !stages.isEmpty && !fits(at)) { offset = minutes }
                        }
                    }
                    if let suggestion = suggestion {
                        chip(title: "Next free", subtitle: Self.time(suggestion), selected: offset == nil,
                             highlight: true) { offset = nil }
                            .frame(maxWidth: 170)
                    }
                    if clashes && offset != nil {
                        Label("Something's booked then. Pick another time, or Next free.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.yellow)
                    }
                }
                section("What?") {
                    HStack(spacing: 8) {
                        ForEach(Machine.allCases) { machine in
                            chip(title: machine.name, subtitle: extendLabel(machine.defaultMinutes),
                                 systemImage: machine.systemImage, selected: uses.contains(machine)) {
                                if uses.contains(machine) { uses.remove(machine) } else { uses.insert(machine) }
                            }
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
                Spacer(minLength: 0)
            }
            .padding(20)
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
        .confirmationAlert(confirmer)
        .onAppear {
            base = Self.alignedNow()
            // Machine busy right now? Start on the next free time instead, so
            // tapping a name still books straight away.
            if !fits(base) { offset = nil }
        }
    }

    private func book(for person: Person) {
        let start = start
        do {
            let chain = try store.checkChain(person, start: start, stages: stages)
            let lines = chain.map { "\($0.machine.name): \($0.timeRange)" }
            confirmer.ask("book \(person.name) in", detail: lines.joined(separator: "\n"), confirmTitle: "Book") {
                do {
                    try store.bookChain(person, start: start, stages: stages)
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

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
    }

    private func chip(title: String, subtitle: String, systemImage: String? = nil, selected: Bool,
                      highlight: Bool = false, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
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
        // Still tappable (the warning explains), just visibly worse.
        .opacity(dimmed && !selected ? 0.4 : 1)
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
