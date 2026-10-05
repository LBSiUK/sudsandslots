import SwiftUI

/// The booking form, shown as a sheet from the big + button.
struct BookingSheet: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var form: BookingForm
    @Environment(\.dismiss) private var dismiss
    /// The sheet's own, because iOS 15 can't show the main screen's alert
    /// over a sheet.
    @StateObject private var confirmer = Confirmer()
    @State private var error: BookingError?


    private var tint: Color { form.person?.color ?? Color.white.opacity(0.25) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    people
                    days
                    startTime
                    usage
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .alert("Can't book that slot", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(error?.errorDescription ?? "")
                }
            }
            .navigationTitle("Book a Slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Book", action: book)
                }
            }
        }
        .navigationViewStyle(.stack)
        .confirmationAlert(confirmer)
        .onAppear(perform: form.resetUsage)
    }

    /// The three yes/no questions, each with a time estimate when it's a yes.
    private var usage: some View {
        VStack(spacing: 6) {
            SectionLabel("What are you using?")
            VStack(spacing: 0) {
                ForEach(Machine.allCases) { machine in
                    if machine != Machine.allCases.first {
                        Divider().overlay(Theme.controlStroke)
                    }
                    usageRow(machine)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.controlStroke))
        }
    }

    /// When this machine's stage would end, with the chosen stages back to back.
    private func stageEnd(_ machine: Machine) -> Date {
        var at = form.startDate
        for (m, length) in form.stages {
            at = at.addingTimeInterval(TimeInterval(length * 60))
            if m == machine { break }
        }
        return at
    }

    private func usageRow(_ machine: Machine) -> some View {
        let using = Binding(get: { form.uses[machine] ?? false }, set: { form.uses[machine] = $0 })
        let minutes = Binding(get: { form.minutes[machine] ?? machine.defaultMinutes },
                              set: { form.minutes[machine] = $0 })
        return VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: machine.systemImage)
                    .frame(width: 20)
                    .foregroundColor(using.wrappedValue ? .white : Theme.secondaryText)
                Text(machine.question)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Picker(machine.question, selection: using) {
                    Text("No").tag(false)
                    Text("Yes").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            .frame(minHeight: 40)
            if using.wrappedValue {
                Stepper {
                    HStack {
                        Text("Estimated time")
                            .foregroundColor(Theme.secondaryText)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(extendLabel(minutes.wrappedValue))
                                .font(.system(size: 16, weight: .semibold))
                                .monospacedDigit()
                            if machine.showsEndTime(minutes.wrappedValue) {
                                Text("until \(Booking.timeFormatter.string(from: stageEnd(machine)))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.secondaryText)
                                    .monospacedDigit()
                            }
                        }
                    }
                } onIncrement: {
                    minutes.wrappedValue = machine.step(minutes.wrappedValue, up: true)
                } onDecrement: {
                    minutes.wrappedValue = machine.step(minutes.wrappedValue, up: false)
                }
                .padding(.leading, 30)
                .padding(.bottom, 6)
            }
        }
    }

    private var people: some View {
        VStack(spacing: 6) {
            SectionLabel("Who's it for?")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Person.allCases) { person in
                    let selected = form.person == person
                    Button {
                        form.person = person
                    } label: {
                        Text(person.name)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(alignment: .trailing) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 20))
                                        .padding(.trailing, 12)
                                }
                            }
                            .background(person.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white, lineWidth: selected ? 3 : 0))
                            .opacity(form.person == nil || selected ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A row of half-hour chips (one tap to pick), opened scrolled so the
    /// current half hour is the second chip.
    private var startTime: some View {
        VStack(spacing: 6) {
            SectionLabel("Start time")
            TimeStrip(selection: $form.startMinutes, isToday: form.dayOffset == 0, tint: tint)
        }
    }

    private var days: some View {
        VStack(spacing: 6) {
            SectionLabel("Which day?")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                ForEach(0..<6) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset,
                                                     to: Calendar.current.startOfDay(for: Date()))!
                    Button {
                        form.dayOffset = offset
                    } label: {
                        VStack(spacing: 1) {
                            Text(Self.dayTitle(offset: offset, date: date))
                                .font(.system(size: 15, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(Self.shortDate.string(from: date))
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.7))
                        }
                        .frame(height: 44)
                    }
                    .buttonStyle(TileButtonStyle(selected: form.dayOffset == offset, tint: tint))
                }
            }
        }
    }

    private func book() {
        do {
            let chain = try store.checkChain(form.person, start: form.startDate, stages: form.stages)
            let lines = chain.map { "\($0.machine.name): \($0.timeRange)" }
            confirmer.ask("book \(chain[0].person.name) in",
                          detail: ([Self.longDay.string(from: chain[0].start)] + lines).joined(separator: "\n"),
                          confirmTitle: "Book") { confirmBooking() }
        } catch let e as BookingError {
            showError(e)
        } catch {}
    }

    private func confirmBooking() {
        do {
            try store.bookChain(form.person, start: form.startDate, stages: form.stages)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch let e as BookingError {
            showError(e)
        } catch {}
    }

    private func showError(_ e: BookingError) {
        error = e
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static let longDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"; return f
    }()

    static func dayTitle(offset: Int, date: Date) -> String {
        switch offset {
        case 0: return "TODAY"
        case 1: return "TMRW"
        default: return weekday.string(from: date).uppercased()
        }
    }

    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()
}

/// Every half hour of the day as a horizontal row of chips. Opens scrolled so
/// the current half hour is the second chip (the one before it sits first for
/// context), so nobody has to scroll from midnight. Earlier times today are
/// dimmed.
struct TimeStrip: View {
    @Binding var selection: Int
    let isToday: Bool
    let tint: Color

    private var currentSlot: Int {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return now.hour! * 2 + now.minute! / 30
    }

    /// The chip the strip opens on (one before it, so it isn't at the very
    /// edge): now, unless the chosen time is on another day or more than a
    /// few hours away (e.g. rescheduling a session tomorrow morning), when
    /// it opens on the chosen time so it's in view.
    private var openingSlot: Int {
        let chosen = selection / 30
        let nearNow = isToday && chosen < currentSlot + 6
        return max((nearNow ? currentSlot : chosen) - 1, 0)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<48, id: \.self) { slot in
                        chip(slot)
                    }
                }
            }
            .onAppear {
                // Again once the sheet has finished presenting; scrolling only
                // during the animation lands a few chips off.
                let target = openingSlot
                for delay in [0.0, 0.35, 0.7] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        proxy.scrollTo(target, anchor: .leading)
                    }
                }
            }
        }
    }

    private func chip(_ slot: Int) -> some View {
        let minutes = slot * 30
        let past = isToday && slot < currentSlot
        return Button {
            selection = minutes
        } label: {
            // "9:30" on top, "PM" (or "PM · Now") underneath keeps chips narrow.
            let label = BookingForm.label(forMinutes: minutes)
            VStack(spacing: 0) {
                Text(label.dropLast(3))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                Text(slot == currentSlot && isToday ? "\(label.suffix(2)) · Now" : String(label.suffix(2)))
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.75)
            }
            .frame(minWidth: 44)
            .padding(.horizontal, 6)
            .frame(height: 44)
        }
        .buttonStyle(TileButtonStyle(selected: selection == minutes, tint: tint))
        .fixedSize()
        .opacity(past ? 0.4 : 1)
        .id(slot)
    }
}
