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
            TimelineGrid(day: form.day, bookings: store.bookings(on: form.day),
                         neighbours: (store.bookings(on: form.day.addingTimeInterval(-86_400 / 2)),
                                      store.bookings(on: form.day.addingTimeInterval(86_400 * 1.5)))) {
                form.dayOffset += $0
            }
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
    /// The day before's and the day after's bookings, peeked at past either end.
    var neighbours: (previous: [Booking], next: [Booking]) = ([], [])
    /// Pull past midnight at either end: +1 = next day, -1 = previous day.
    var changeDay: (Int) -> Void = { _ in }

    /// How far past the top (+) or bottom (−) of the day the list is pulled.
    @State private var pull: CGFloat = 0
    /// Set while a pull changes the day: the scroll view places itself, so
    /// the usual scroll-to-morning on a day change is skipped.
    @State private var snapping = false
    private let pullThreshold: CGFloat = 90
    /// Hours of the neighbouring day drawn past midnight at either end.
    private let peekHours = 4
    private var peekHeight: CGFloat { hourHeight * CGFloat(peekHours) }

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
                            // Just outside the content, so only seen when pulled
                            // past either end.
                            peek(direction: -1, columns: cols, width: geo.size.width)
                                .offset(y: -peekHeight)
                            peek(direction: 1, columns: cols, width: geo.size.width)
                                .offset(y: geo.size.height)
                        }
                    }
                    .frame(height: hourHeight * 24 + topInset * 2)
                    .background(ScrollPullWatcher(threshold: pullThreshold, midnightInset: topInset, onPull: { pull = $0 }, onSnap: snapped))
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
                    if snapping {
                        snapping = false
                    } else {
                        scroll(proxy, to: defaultHour(), animated: true)
                    }
                }
                .onReceive(idleCheck) { _ in autoScrollIfIdle(proxy) }
            }
        }
    }

    /// Pulled past the threshold: change day there and then. The scroll view
    /// keeps what was on screen in place and eases into the new day.
    private func snapped(_ direction: Int) {
        pull = 0
        snapping = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        changeDay(direction)
    }

    static func dayName(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today"
            : Calendar.current.isDateInTomorrow(date) ? "Tomorrow"
            : Calendar.current.isDateInYesterday(date) ? "Yesterday"
            : CalendarView.weekday.string(from: date)
    }

    /// The last (−1) or first (+1) few hours of the neighbouring day, drawn
    /// just outside this one so pulling past midnight shows what's there.
    private func peek(direction: Int, columns cols: Columns, width: CGFloat) -> some View {
        let other = Calendar.current.date(byAdding: .day, value: direction, to: day)!
        let firstHour = direction < 0 ? 24 - peekHours : 0
        let from = Calendar.current.date(byAdding: .hour, value: firstHour, to: other)!
        let to = from.addingTimeInterval(TimeInterval(peekHours * 3600))
        let py = { (date: Date) in CGFloat(date.timeIntervalSince(from) / 3600) * hourHeight }
        let shown = (direction < 0 ? neighbours.previous : neighbours.next)
            .filter { $0.start < to && $0.end > from }
        return ZStack(alignment: .topLeading) {
            ForEach(0..<peekHours, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.hourLabel(firstHour + i))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(y: -9)
                    Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1)
                }
                .padding(.trailing, 18)
                .offset(y: CGFloat(i) * hourHeight)
            }
            ForEach(shown) { booking in
                let top = max(py(booking.start), 0)
                let bottom = min(py(booking.end), peekHeight)
                let height = max(bottom - top - 3, 10)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(booking.person.color.opacity(booking.finishedAt == nil ? 0.75 : 0.35))
                    .overlay(alignment: .topLeading) {
                        if height >= 28 {
                            Text("\(booking.person.name)  \(booking.shortTimeRange)")
                                .font(.system(size: 14, weight: .bold))
                                .lineLimit(1)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                        }
                    }
                    .frame(width: cols.width, height: height)
                    .offset(x: cols.x(for: booking.machine), y: top + 1.5)
            }
            // Which day this is, at the midnight it joins on.
            Label(Self.dayName(other), systemImage: direction < 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white, in: Capsule())
                .offset(x: cols.x + cols.all - 110, y: direction < 0 ? peekHeight - 30 : 6)
        }
        .frame(width: width, height: peekHeight, alignment: .topLeading)
        .overlay(alignment: direction < 0 ? .bottom : .top) {
            Rectangle().fill(Color.white.opacity(0.5)).frame(height: 2)
        }
        .opacity(0.85)
        .allowsHitTesting(false)
    }

    /// "Pull for Monday" / "Release for Monday", shown while pulling.
    @ViewBuilder
    private func pullHint(direction: Int) -> some View {
        let distance = direction < 0 ? max(pull, 0) : max(-pull, 0)
        if distance > 8 {
            let ready = distance >= pullThreshold * 0.8
            Label("Drag a little harder to go to the \(direction < 0 ? "previous" : "next") day",
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
    let threshold: CGFloat
    /// Space between the content's edges and its midnight lines.
    let midnightInset: CGFloat
    let onPull: (CGFloat) -> Void
    /// −1 = previous day, +1 = next day.
    let onSnap: (Int) -> Void

    func makeUIView(context: Context) -> WatcherView { WatcherView() }

    func updateUIView(_ view: WatcherView, context: Context) {
        view.threshold = threshold
        view.midnightInset = midnightInset
        view.onPull = onPull
        view.onSnap = onSnap
    }

    final class WatcherView: UIView {
        var threshold: CGFloat = 90
        var midnightInset: CGFloat = 0
        var onPull: (CGFloat) -> Void = { _ in }
        var onSnap: (Int) -> Void = { _ in }
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastReported: CGFloat = 0
        /// One day change per drag.
        private var snapped = false

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

        private var minOffset: CGFloat { -(scrollView?.adjustedContentInset.top ?? 0) }

        private var maxOffset: CGFloat {
            guard let s = scrollView else { return 0 }
            return max(s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.height, minOffset)
        }

        /// + past the top, − past the bottom, 0 in between.
        private var overscroll: CGFloat {
            guard let s = scrollView else { return 0 }
            let top = minOffset - s.contentOffset.y
            if top > 0 { return top }
            let bottom = s.contentOffset.y - maxOffset
            return bottom > 0 ? -bottom : 0
        }

        private func offsetChanged() {
            guard let s = scrollView, s.isTracking, !snapped else { return }
            let now = overscroll
            guard now != lastReported else { return }
            lastReported = now
            onPull(now)
            if abs(now) >= threshold { snap(now) }
        }

        /// Swap to the neighbouring day without anything jumping: the new
        /// day's midnight lands where the peeked one was, then eases in.
        private func snap(_ distance: CGFloat) {
            guard let s = scrollView else { return }
            snapped = true
            lastReported = 0
            // End the drag here; the finger has done its job.
            s.panGestureRecognizer.isEnabled = false
            s.panGestureRecognizer.isEnabled = true
            let direction = distance > 0 ? -1 : 1
            let height = s.bounds.height
            let start: CGFloat, end: CGFloat
            if direction < 0 {
                // The peeked day's midnight sat `distance` down the screen
                // (the peeks butt onto the content's edges, not its midnight
                // lines); the new day's last midnight goes there instead.
                start = maxOffset + height - distance - midnightInset
                end = maxOffset
            } else {
                start = minOffset - height - distance + midnightInset
                end = minOffset
            }
            onSnap(direction)
            DispatchQueue.main.async {
                s.setContentOffset(CGPoint(x: 0, y: start), animated: false)
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9,
                               initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
                    s.contentOffset = CGPoint(x: 0, y: end)
                }
            }
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                snapped = false
            case .ended, .cancelled, .failed:
                lastReported = 0
                onPull(0)
            default: break
            }
        }
    }
}
