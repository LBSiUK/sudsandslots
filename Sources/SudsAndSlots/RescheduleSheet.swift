import SwiftUI

/// Which booking the "Set new time and date" sheet is open for. Lives at the
/// root so the sheet survives the menu that opened it closing.
final class Rescheduler: ObservableObject {
    @Published var booking: Booking?
}

/// Pick a new day and start time for a session that hasn't started. Shows who
/// would be pushed along before you confirm.
struct RescheduleSheet: View {
    @EnvironmentObject var store: BookingStore
    @Environment(\.dismiss) private var dismiss
    /// Its own, because iOS 15 can't show the main screen's alert over a sheet.
    @StateObject private var confirmer = Confirmer()
    let booking: Booking

    @State private var dayOffset: Int
    @State private var startMinutes: Int

    /// Starts from where the session is now. Set here rather than in onAppear
    /// so the time strip opens on the right day and time straight away.
    init(booking: Booking) {
        self.booking = booking
        let today = Calendar.current.startOfDay(for: Date())
        _dayOffset = State(initialValue: max(0, Calendar.current.dateComponents(
            [.day], from: today, to: Calendar.current.startOfDay(for: booking.start)).day ?? 0))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: booking.start)
        // The time row is half-hourly: round up to the next one (a 9:55
        // slot opens on 10:00, not on 9:30, which may have passed).
        let exact = parts.hour! * 60 + parts.minute!
        _startMinutes = State(initialValue: min((exact + 29) / 30 * 30, 23 * 60 + 30))
    }

    private var newStart: Date {
        let today = Calendar.current.startOfDay(for: Date())
        let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: today)!
        return Calendar.current.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: day)!
    }

    private var tint: Color { booking.person.color }

    var body: some View {
        let plan = Result { try store.movePlan(for: booking, to: newStart) }
        let newEnd = newStart.addingTimeInterval(TimeInterval(booking.minutes * 60))
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(booking.person.name)'s \(booking.machine.name.lowercased()) session, now \(booking.timeRange)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                    VStack(spacing: 6) {
                        SectionLabel("New day")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                            ForEach(0..<6) { offset in
                                let date = Calendar.current.date(byAdding: .day, value: offset,
                                                                 to: Calendar.current.startOfDay(for: Date()))!
                                Button { dayOffset = offset } label: {
                                    VStack(spacing: 1) {
                                        Text(BookingSheet.dayTitle(offset: offset, date: date))
                                            .font(.system(size: 15, weight: .bold))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                        Text(BookingSheet.shortDate.string(from: date))
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.white.opacity(0.7))
                                    }
                                    .frame(height: 44)
                                }
                                .buttonStyle(TileButtonStyle(selected: dayOffset == offset, tint: tint))
                            }
                        }
                    }
                    VStack(spacing: 6) {
                        SectionLabel("New start time")
                        TimeStrip(selection: $startMinutes, isToday: dayOffset == 0, tint: tint)
                    }
                    outcome(plan, newEnd: newEnd)
                }
                .padding(20)
            }
            .navigationTitle("Set New Time and Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reschedule") {
                        let pending = PendingBarAction(action: .moveTo(newStart), booking: booking)
                        let moves = (try? plan.get()) ?? []
                        confirmer.ask(pending.question, detail: pending.detail(moves: moves),
                                      confirmTitle: pending.buttonTitle) {
                            do {
                                try store.move(booking, to: pending.newStart!)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            } catch let e as BookingError {
                                store.syncError = e.errorDescription
                            } catch {}
                        }
                    }
                    .disabled((try? plan.get()) == nil || newStart == booking.start)
                }
            }
        }
        .navigationViewStyle(.stack)
        .confirmationAlert(confirmer)
    }

    /// What the new time would do: free, who moves, or why it can't.
    @ViewBuilder
    private func outcome(_ plan: Result<[SessionMove], Error>, newEnd: Date) -> some View {
        let when = "\(Booking.timeFormatter.string(from: newStart)) – \(Booking.timeFormatter.string(from: newEnd))"
        switch plan {
        case .success(let moves) where moves.isEmpty:
            Label("Free: \(when)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(BookingBar.startGreen)
        case .success(let moves):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(when) pushes these along:", systemImage: "arrow.right.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                ForEach(moves, id: \.booking.id) { move in
                    Text("• " + PendingBarAction.moveLine(move, actor: booking.person))
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundColor(.orange)
        case .failure(let error):
            Label((error as? BookingError)?.errorDescription ?? "That time won't work.",
                  systemImage: "xmark.octagon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.red)
        }
    }
}
