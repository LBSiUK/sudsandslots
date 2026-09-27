import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Tracks when the iPad was last touched, so the calendar can tidy itself up
/// after it's been left alone.
final class IdleMonitor: ObservableObject {
    static let idleDelay: TimeInterval = {
        #if DEBUG
        // -idle15 shortens the wait to 15 seconds for testing.
        if ProcessInfo.processInfo.arguments.contains("-idle15") { return 15 }
        #endif
        return 5 * 60
    }()

    // Deliberately not @Published: it changes on every touch move, and the
    // calendar polls it on a timer instead of re-rendering on each change.
    private(set) var lastInteraction = Date()

    /// Whether a finger is on the screen right now. The calendar's pull-to-
    /// change-day uses it to act only once the finger lifts.
    private(set) var isTouching = false

    fileprivate func setTouching(_ touching: Bool) {
        isTouching = touching
    }

    fileprivate func touched() {
        lastInteraction = Date()
    }

    var isIdle: Bool {
        Date().timeIntervalSince(lastInteraction) >= Self.idleDelay
    }
}

/// Drop this anywhere in the view tree: it attaches a passive gesture recogniser
/// to the window that notes every touch without stealing any.
struct IdleTouchWatcher: UIViewRepresentable {
    let monitor: IdleMonitor

    func makeUIView(context: Context) -> WatcherView {
        WatcherView(monitor: monitor)
    }

    func updateUIView(_ uiView: WatcherView, context: Context) {}

    final class WatcherView: UIView {
        private let recognizer: TouchRecognizer

        init(monitor: IdleMonitor) {
            recognizer = TouchRecognizer(monitor: monitor)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    final class TouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let monitor: IdleMonitor

        init(monitor: IdleMonitor) {
            self.monitor = monitor
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            monitor.touched()
            monitor.setTouching(true)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            monitor.touched()
        }

        // Count the moment a finger lifts as the last use, then step aside.
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            monitor.touched()
            monitor.setTouching(Self.anyStillDown(event))
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            monitor.touched()
            monitor.setTouching(Self.anyStillDown(event))
            state = .failed
        }

        private static func anyStillDown(_ event: UIEvent) -> Bool {
            event.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled } ?? false
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
