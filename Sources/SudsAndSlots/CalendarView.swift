import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var form: BookingForm

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            Divider().overlay(Theme.panelStroke)
            TimelineGrid(day: form.day, bookings: store.bookings(on: form.day))
        }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(Self.subtitle.string(from: form.day))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
            }
            HStack {
                navButton("Prev", systemImage: "chevron.left", leading: true) { form.dayOffset -= 1 }
                Spacer()
                navButton("Next", systemImage: "chevron.right", leading: false) { form.dayOffset += 1 }
            }
        }
        .foregroundColor(.white)
    }

    private var title: String {
        switch form.dayOffset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return Self.weekday.string(from: form.day)
        }
    }

    private func navButton(_ text: String, systemImage: String, leading: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if leading { Image(systemName: systemImage) }
                Text(text)
                if !leading { Image(systemName: systemImage) }
            }
            .font(.system(size: 19, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .background(Theme.control, in: Capsule())
            .overlay(Capsule().stroke(Theme.controlStroke))
        }
        .buttonStyle(.plain)
    }

    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()

    static let subtitle: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"; return f
    }()
}

/// The scrollable 24-hour column with bookings laid over it.
struct TimelineGrid: View {
    @EnvironmentObject var store: BookingStore
    let day: Date
    let bookings: [Booking]

    @State private var pendingDelete: Booking?

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 64
    private let topInset: CGFloat = 14

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    gridLines
                    GeometryReader { geo in
                        let width = geo.size.width - labelWidth - 28
                        ForEach(bookings) { booking in
                            block(for: booking, width: width)
                        }
                        nowLine(width: width)
                    }
                }
                .frame(height: hourHeight * 24 + topInset * 2)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: day) { _ in scroll(proxy, animated: true) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                              set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Cancel Booking", role: .destructive) {
                if let b = pendingDelete { withAnimation { store.remove(b) } }
            }
            Button("Keep It", role: .cancel) {}
        }
    }

    private var deleteTitle: String {
        guard let b = pendingDelete else { return "" }
        return "Cancel \(b.person.name)'s slot, \(b.timeRange)?"
    }

    private var gridLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24) { hour in
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.hourLabel(hour))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(y: -9)
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1)
                        Spacer()
                        DashedLine()
                            .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(height: 1)
                        Spacer()
                    }
                }
                .frame(height: hourHeight)
                .padding(.trailing, 18)
                .id(hour)
            }
        }
        .padding(.top, topInset)
    }

    private func y(for date: Date) -> CGFloat {
        let minutes = date.timeIntervalSince(day) / 60
        return topInset + CGFloat(minutes) / 60 * hourHeight
    }

    private func block(for booking: Booking, width: CGFloat) -> some View {
        // Clip to this day so slots that cross midnight show on both days.
        let top = max(y(for: booking.start), topInset)
        let bottom = min(y(for: booking.end), topInset + hourHeight * 24)
        let height = max(bottom - top - 3, 22)
        let compact = height < 40

        return Button {
            pendingDelete = booking
        } label: {
            HStack {
                Text(booking.person.name)
                    .font(.system(size: compact ? 16 : 19, weight: .bold, design: .rounded))
                Spacer()
                Text(booking.timeRange)
                    .font(.system(size: compact ? 14 : 16, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(width: width, height: height)
            .background(booking.person.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25)))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .offset(x: labelWidth + 10, y: top + 1.5)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    @ViewBuilder
    private func nowLine(width: CGFloat) -> some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            if Calendar.current.isDate(context.date, inSameDayAs: day) {
                HStack(spacing: 0) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Rectangle().fill(Color.red).frame(width: width, height: 2)
                }
                .offset(x: labelWidth + 6, y: y(for: context.date) - 4.5)
                .allowsHitTesting(false)
            }
        }
    }

    /// Scroll to the current time today, otherwise the first booking (or 7am).
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        var hour = 7
        if Calendar.current.isDateInToday(day) {
            hour = Calendar.current.component(.hour, from: Date())
        } else if let first = bookings.first(where: { $0.start >= day }) {
            hour = Calendar.current.component(.hour, from: first.start)
        }
        let target = max(hour - 1, 0)
        if animated {
            withAnimation { proxy.scrollTo(target, anchor: .top) }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12 AM"
        case 12: return "12 PM"
        default: return "\(hour % 12) \(hour < 12 ? "AM" : "PM")"
        }
    }
}

struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
