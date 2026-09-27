import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var form: BookingForm
    @EnvironmentObject var confirmer: Confirmer
    @State private var error: BookingError?

    private let durations = [30, 60, 90, 120, 150, 180]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var tint: Color { form.person?.color ?? Color.white.opacity(0.25) }

    var body: some View {
        VStack(spacing: 0) {
            // Everything scrolls if the screen is short, but Book stays pinned.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 11) {
                    header
                    people
                    startTime
                    duration
                    days
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 10)
            }
            bookButton
                .padding([.horizontal, .bottom], 20)
        }
        .alert("Can't book that slot", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.errorDescription ?? "")
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
            Spacer()
        }
    }

    private var people: some View {
        VStack(spacing: 6) {
            SectionLabel("Who's washing?")
            ForEach(Person.allCases) { person in
                let selected = form.person == person
                Button {
                    form.person = person
                } label: {
                    Text(person.name)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 33)
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

    private var startTime: some View {
        VStack(spacing: 6) {
            SectionLabel("Start time")
            Menu {
                Picker("Start time", selection: $form.startMinutes) {
                    ForEach(0..<48) { slot in
                        Text(BookingForm.label(forMinutes: slot * 30)).tag(slot * 30)
                    }
                }
            } label: {
                HStack {
                    Text(BookingForm.label(forMinutes: form.startMinutes))
                        .font(.system(size: 20, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Theme.control, in: Capsule())
                .overlay(Capsule().stroke(Theme.controlStroke))
            }
        }
    }

    private var duration: some View {
        VStack(spacing: 6) {
            SectionLabel("Duration")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(durations, id: \.self) { minutes in
                    Button {
                        form.durationMinutes = minutes
                    } label: {
                        Text(String(format: "%d:%02d", minutes / 60, minutes % 60))
                            .font(.system(size: 18, weight: .semibold))
                            .monospacedDigit()
                            .frame(height: 36)
                    }
                    .buttonStyle(TileButtonStyle(selected: form.durationMinutes == minutes, tint: tint))
                }
            }
        }
    }

    private var days: some View {
        VStack(spacing: 6) {
            SectionLabel("Which day?")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<6) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset,
                                                     to: Calendar.current.startOfDay(for: Date()))!
                    Button {
                        form.dayOffset = offset
                    } label: {
                        VStack(spacing: 1) {
                            Text(Self.dayTitle(offset: offset, date: date))
                                .font(.system(size: 16, weight: .bold))
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

    private var bookButton: some View {
        Button {
            do {
                let booking = try store.check(form.person, start: form.startDate, minutes: form.durationMinutes)
                confirmer.ask("book \(booking.person.name) in",
                              detail: "\(Self.longDay.string(from: booking.start)), \(booking.timeRange)",
                              confirmTitle: "Book") { confirmBooking(booking) }
            } catch let e as BookingError {
                showError(e)
            } catch {}
        } label: {
            Label("Book Slot", systemImage: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func confirmBooking(_ booking: Booking) {
        do {
            try store.book(booking.person, start: booking.start, minutes: booking.minutes)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
