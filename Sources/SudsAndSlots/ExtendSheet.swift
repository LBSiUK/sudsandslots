import SwiftUI

/// The choices offered under Extend, before "Custom…".
let extendOptions = [15, 30, 45, 60, 90, 120, 150, 180]

let extendWarning = "The time remaining stated on the washing machine is likely incorrect. "
    + "Please be sure of what you're choosing. "
    + "We'd recommend up to 45m beyond what the machine states."

func extendLabel(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m) min" }
    if m == 0 { return h == 1 ? "1 hour" : "\(h) hours" }
    return "\(h) h \(m) min"
}

/// Which booking the "Custom…" extend sheet is open for. Lives at the root so
/// the sheet survives the menu that opened it closing.
final class CustomExtend: ObservableObject {
    @Published var booking: Booking?
}

/// The Extend menu's contents: the preset lengths, then Custom….
struct ExtendMenuItems: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var confirmer: Confirmer
    @EnvironmentObject var customExtend: CustomExtend
    let booking: Booking

    var body: some View {
        ForEach(extendOptions, id: \.self) { minutes in
            Button("+ \(extendLabel(minutes))") {
                confirmer.ask(PendingBarAction(action: .extend(minutes: minutes), booking: booking), store: store)
            }
        }
        Divider()
        Button { customExtend.booking = booking } label: {
            Label("Custom…", systemImage: "slider.horizontal.3")
        }
    }
}

/// Pick any extension from 5 minutes to 3 hours, see who it would push back,
/// then confirm.
struct ExtendSheet: View {
    @EnvironmentObject var store: BookingStore
    @Environment(\.dismiss) private var dismiss
    /// Its own, because iOS 15 can't show the main screen's alert over a sheet.
    @StateObject private var confirmer = Confirmer()
    let booking: Booking

    @State private var minutes = 30

    private var pending: PendingBarAction {
        PendingBarAction(action: .extend(minutes: minutes), booking: booking)
    }

    var body: some View {
        let moves = store.extensionPlan(for: booking, by: minutes)
        let newEnd = booking.end.addingTimeInterval(TimeInterval(minutes * 60))
        NavigationView {
            Form {
                Section {
                    Label(extendWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.yellow)
                        .padding(.vertical, 4)
                }
                Section {
                    Stepper(value: $minutes, in: 5...180, step: 5) {
                        Text("Extend by \(extendLabel(minutes))")
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Ends at")
                        Spacer()
                        Text("\(Booking.timeFormatter.string(from: newEnd)) instead of \(Booking.timeFormatter.string(from: booking.end))")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("\(booking.person.name)'s \(booking.machine.name.lowercased()) session")
                }
                if !moves.isEmpty {
                    Section {
                        ForEach(moves, id: \.booking.id) { move in
                            HStack {
                                Circle().fill(move.booking.person.color).frame(width: 10, height: 10)
                                Text(move.booking.person.name)
                                Spacer()
                                Text(move.deferred ? nextAfternoon(move) : move.newTimeRange)
                                    .foregroundColor(move.deferred ? .orange : .secondary)
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        Text("These will be pushed back")
                    } footer: {
                        Text("They'll be told their session has moved.")
                    }
                }
            }
            .navigationTitle("Extend Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Extend") {
                        let pending = pending
                        confirmer.ask(pending.question, detail: pending.detail(moves: moves),
                                      confirmTitle: pending.buttonTitle) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            store.extend(booking, by: pending.minutes)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .confirmationAlert(confirmer)
    }
}

private extension PendingBarAction {
    var minutes: Int {
        if case .extend(let m) = action { return m }
        return 0
    }
}
