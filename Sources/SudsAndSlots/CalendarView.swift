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
            TimelineGrid(day: form.day, bookings: store.bookings(on: form.day)) { form.dayOffset += $0 }
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
    /// Pull past midnight at either end: +1 = next day, -1 = previous day.
    var changeDay: (Int) -> Void = { _ in }

    /// How far past the top (+) or bottom (−) of the day the list is pulled.
    @State private var pull: CGFloat = 0
    /// Set once pulled past the threshold; acted on when the finger lifts.
    @State private var armed: Int?
    /// Where to land after a pull changes the day (0 = midnight, 23 = 11 PM).
    @State private var landOn: Int?
    private let pullThreshold: CGFloat = 80

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

    /// Where each machine's column sits, given the grid's full width.
    private struct Columns {
        let x: CGFloat, width: CGFloat, gap: CGFloat
        let count = CGFloat(Machine.allCases.count)

        init(totalWidth: CGFloat, leading: CGFloat) {
            gap = 8
            x = leading
            width = (totalWidth - leading - 28 - gap * (count - 1)) / count
        }

        func x(for machine: Machine) -> CGFloat {
            x + CGFloat(Machine.allCases.firstIndex(of: machine)!) * (width + gap)
        }

        var all: CGFloat { width * count + gap * (count - 1) }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
                            // Faint rules between the machine columns.
                            ForEach(Machine.allCases.dropFirst()) { machine in
                                Rectangle()
                                    .fill(Theme.panelStroke)
                                    .frame(width: 1, height: geo.size.height)
                                    .offset(x: cols.x(for: machine) - cols.gap / 2)
                            }
                            // Drawn before the bars so they sit on top of it.
                            nowLine(width: cols.all)
                            ForEach(bookings) { booking in
                                block(for: booking, columns: cols)
                            }
                        }
                    }
                    .frame(height: hourHeight * 24 + topInset * 2)
                    .background(ScrollPullWatcher(onPull: pulled, onRelease: released))
                }
                .overlay(alignment: .top) { pullHint(direction: -1) }
                .overlay(alignment: .bottom) { pullHint(direction: 1) }
                .onAppear {
                    viewportHeight = outer.size.height
                    DispatchQueue.main.async { scroll(proxy, to: defaultHour(), animated: false) }
                }
                .onChange(of: outer.size.height) { viewportHeight = $0 }
                .onChange(of: day) { _ in
                    // Pulled past midnight: carry on from the edge you came through.
                    if let edge = landOn {
                        landOn = nil
                        scroll(proxy, to: edge, animated: false)
                    } else {
                        scroll(proxy, to: defaultHour(), animated: true)
                    }
                }
                .onReceive(idleCheck) { _ in autoScrollIfIdle(proxy) }
            }
        }
    }

    /// Tracks overscroll at either end while the finger is down (+ = past
    /// the top, − = past the bottom). Past the threshold it arms, with a tap
    /// of haptics; easing back off disarms it.
    private func pulled(_ distance: CGFloat) {
        pull = distance
        let direction = distance > 0 ? -1 : 1
        if abs(distance) >= pullThreshold {
            if armed != direction {
                armed = direction
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } else if armed != nil, abs(distance) < pullThreshold * 0.6 {
            armed = nil
        }
    }

    /// The finger lifted: change day if it let go while armed.
    private func released(_ distance: CGFloat) {
        pull = 0
        defer { armed = nil }
        guard abs(distance) >= pullThreshold * 0.6, let direction = armed else { return }
        landOn = direction > 0 ? 0 : 23
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        changeDay(direction)
    }

    /// "Pull for Monday" / "Release for Monday", shown while pulling.
    @ViewBuilder
    private func pullHint(direction: Int) -> some View {
        let distance = direction < 0 ? max(pull, 0) : max(-pull, 0)
        if distance > 8 {
            let target = Calendar.current.date(byAdding: .day, value: direction, to: day)!
            let name = Calendar.current.isDateInToday(target) ? "Today"
                : Calendar.current.isDateInTomorrow(target) ? "Tomorrow"
                : Calendar.current.isDateInYesterday(target) ? "Yesterday"
                : CalendarView.weekday.string(from: target)
            let ready = armed == direction
            Label(ready ? "Release for \(name)"
                        : "Drag a little harder to go to the \(direction < 0 ? "previous" : "next") day",
                  systemImage: direction < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ready ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ready ? Color.white : Color.white.opacity(0.18 + 0.3 * min(distance / pullThreshold, 1)),
                            in: Capsule())
                .padding(12)
                .allowsHitTesting(false)
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

/// Finds the UIScrollView SwiftUI puts behind the timeline and reports how
/// far it is dragged past either end, and the moment the finger lets go.
/// (SwiftUI on iOS 15 has no way to see overscroll or the end of a drag.)
private struct ScrollPullWatcher: UIViewRepresentable {
    let onPull: (CGFloat) -> Void
    let onRelease: (CGFloat) -> Void

    func makeUIView(context: Context) -> WatcherView { WatcherView() }

    func updateUIView(_ view: WatcherView, context: Context) {
        view.onPull = onPull
        view.onRelease = onRelease
    }

    final class WatcherView: UIView {
        var onPull: (CGFloat) -> Void = { _ in }
        var onRelease: (CGFloat) -> Void = { _ in }
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastReported: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            guard window != nil, scrollView == nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let found = ancestor as? UIScrollView else { return }
            scrollView = found
            found.alwaysBounceVertical = true
            found.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
            observation = found.observe(\.contentOffset) { [weak self] _, _ in self?.offsetChanged() }
        }

        /// + past the top, − past the bottom, 0 in between.
        private var overscroll: CGFloat {
            guard let s = scrollView else { return 0 }
            let top = -(s.contentOffset.y + s.adjustedContentInset.top)
            if top > 0 { return top }
            let maxY = s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.height
            let bottom = s.contentOffset.y - max(maxY, -s.adjustedContentInset.top)
            return bottom > 0 ? -bottom : 0
        }

        private func offsetChanged() {
            guard let s = scrollView, s.isTracking else { return }
            let now = overscroll
            guard now != lastReported else { return }
            lastReported = now
            onPull(now)
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .ended, .cancelled, .failed:
                let final = overscroll
                lastReported = 0
                onRelease(final)
            default: break
            }
        }
    }
}
