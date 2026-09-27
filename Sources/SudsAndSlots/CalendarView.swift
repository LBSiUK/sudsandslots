import Combine
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

/// The scrollable 24-hour column with bookings laid over it. Hours are sized
/// so 8 AM to midnight exactly fills the visible area.
struct TimelineGrid: View {
    @EnvironmentObject var idle: IdleMonitor
    let day: Date
    let bookings: [Booking]

    @State private var viewportHeight: CGFloat = 0
    /// Hour last scrolled to automatically; cleared by any touch so the next
    /// idle spell scrolls again.
    @State private var autoScrolledTo: Int?
    @State private var lastSeenInteraction = Date.distantPast

    /// First hour of the part of the day that should always fit on screen.
    private static let dayStartHour = 8
    private static let minBarHeight: CGFloat = 32
    private let labelWidth: CGFloat = 64
    private let topInset: CGFloat = 14
    private let idleCheck = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var hourHeight: CGFloat {
        let visibleHours = CGFloat(24 - Self.dayStartHour)
        return max((viewportHeight - topInset * 2) / visibleHours, 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            columnHeaders
            timeline
        }
    }

    /// Where the washer and dryer columns sit, given the grid's full width.
    private struct Columns {
        let x: CGFloat, width: CGFloat, gap: CGFloat

        init(totalWidth: CGFloat, leading: CGFloat) {
            gap = 8
            x = leading
            width = (totalWidth - leading - 28 - gap) / 2
        }

        func x(for machine: Machine) -> CGFloat {
            machine == .washer ? x : x + width + gap
        }

        var all: CGFloat { width * 2 + gap }
    }

    private func columns(for width: CGFloat) -> Columns {
        Columns(totalWidth: width, leading: labelWidth + 10)
    }

    private var columnHeaders: some View {
        GeometryReader { geo in
            let cols = columns(for: geo.size.width)
            ForEach(Machine.allCases) { machine in
                Label(machine.name, systemImage: machine.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: cols.width, height: 34)
                    .offset(x: cols.x(for: machine))
            }
        }
        .frame(height: 34)
        .overlay(Divider().overlay(Theme.panelStroke), alignment: .bottom)
    }

    private var timeline: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        scrollAnchors
                        gridLines
                        GeometryReader { geo in
                            let cols = columns(for: geo.size.width)
                            // Faint rule between the washer and dryer columns.
                            Rectangle()
                                .fill(Theme.panelStroke)
                                .frame(width: 1, height: geo.size.height)
                                .offset(x: cols.x + cols.width + cols.gap / 2)
                            // Drawn before the bars so they sit on top of it.
                            nowLine(width: cols.all)
                            ForEach(bookings) { booking in
                                block(for: booking, columns: cols)
                            }
                        }
                    }
                    .frame(height: hourHeight * 24 + topInset * 2)
                }
                .onAppear {
                    viewportHeight = outer.size.height
                    DispatchQueue.main.async { scroll(proxy, to: defaultHour(), animated: false) }
                }
                .onChange(of: outer.size.height) { viewportHeight = $0 }
                .onChange(of: day) { _ in scroll(proxy, to: defaultHour(), animated: true) }
                .onReceive(idleCheck) { _ in autoScrollIfIdle(proxy) }
            }
        }
    }

    /// Invisible markers one per hour, sitting a little above each hour line so
    /// scrolling to them leaves room for the hour label.
    private var scrollAnchors: some View {
        VStack(spacing: 0) {
            ForEach(0..<24) { hour in
                Color.clear.frame(height: hourHeight).id(hour)
            }
        }
    }

    /// Before 8 AM today, show the start of the day; otherwise 8 AM, unless
    /// this day has a booking earlier than that.
    private func defaultHour() -> Int {
        if Calendar.current.isDateInToday(day) {
            return Calendar.current.component(.hour, from: Date()) < Self.dayStartHour ? 0 : Self.dayStartHour
        }
        let firstHour = bookings.first(where: { $0.start >= day })
            .map { Calendar.current.component(.hour, from: $0.start) } ?? Self.dayStartHour
        return min(firstHour, Self.dayStartHour)
    }

    /// Once nobody has touched the iPad for five minutes, scroll back to the
    /// default position. Runs again whenever the default changes (e.g. the
    /// clock reaching 8 AM) or someone has used it since.
    private func autoScrollIfIdle(_ proxy: ScrollViewProxy) {
        if idle.lastInteraction != lastSeenInteraction {
            lastSeenInteraction = idle.lastInteraction
            autoScrolledTo = nil
        }
        guard idle.isIdle else { return }
        let target = defaultHour()
        guard autoScrolledTo != target else { return }
        autoScrolledTo = target
        scroll(proxy, to: target, animated: true)
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
            }
        }
        .padding(.top, topInset)
    }

    private func y(for date: Date) -> CGFloat {
        let minutes = date.timeIntervalSince(day) / 60
        return topInset + CGFloat(minutes) / 60 * hourHeight
    }

    private func block(for booking: Booking, columns cols: Columns) -> some View {
        // Clip to this day so slots that cross midnight show on both days.
        let top = max(y(for: booking.start), topInset)
        let bottom = min(y(for: booking.end), topInset + hourHeight * 24)
        // 30-minute slots are too thin for their buttons, so let a bar grow into
        // the free time below it, but never over the next booking.
        let nextTop = bookings.first(where: { $0.machine == booking.machine && $0.start >= booking.end })
            .map { y(for: $0.start) }
            ?? .greatestFiniteMagnitude
        let height = min(max(bottom - top - 3, Self.minBarHeight), max(nextTop - top - 3, 16))

        return BookingBar(booking: booking, width: cols.width, height: height)
            .offset(x: cols.x(for: booking.machine), y: top + 1.5)
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

    private func scroll(_ proxy: ScrollViewProxy, to hour: Int, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(hour, anchor: .top) }
        } else {
            proxy.scrollTo(hour, anchor: .top)
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
