import SwiftUI

@main
struct SudsAndSlotsApp: App {
    @StateObject private var store = BookingStore()
    @StateObject private var form = BookingForm()
    @StateObject private var idle = IdleMonitor()
    @StateObject private var confirmer = Confirmer()
    @StateObject private var customExtend = CustomExtend()

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                .mini4PreviewFrame()
                #endif
                .environmentObject(store)
                .environmentObject(form)
                .environmentObject(idle)
                .environmentObject(confirmer)
                .environmentObject(customExtend)
                .confirmationAlert(confirmer)
                .background(IdleTouchWatcher(monitor: idle))
                .preferredColorScheme(.dark)
                #if DEBUG
                .onAppear(perform: forceLandscapeForScreenshots)
                #endif
        }
    }
}

#if DEBUG
/// The simulator can't be rotated headlessly, so `-landscape` does it for screenshots.
private func forceLandscapeForScreenshots() {
    guard ProcessInfo.processInfo.arguments.contains("-landscape"),
          #available(iOS 16, *),
          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
}

extension View {
    /// `-mini4` pins the UI to an iPad Mini 4 landscape screen (1024x768pt) so
    /// a bigger simulator can preview the real target size.
    @ViewBuilder func mini4PreviewFrame() -> some View {
        if ProcessInfo.processInfo.arguments.contains("-mini4") {
            frame(width: 1024, height: 768 - 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            self
        }
    }
}
#endif

struct ContentView: View {
    @EnvironmentObject var store: BookingStore
    @EnvironmentObject var customExtend: CustomExtend

    var body: some View {
        GeometryReader { geo in
            // Side by side when there's room (landscape iPad); stacked otherwise.
            if geo.size.width >= 820 {
                HStack(spacing: 16) {
                    StatusPanel()
                        .frame(width: min(max(geo.size.width * 0.34, 340), 420))
                        .panel()
                    CalendarView()
                        .panel()
                }
                .padding(16)
            } else {
                VStack(spacing: 16) {
                    StatusPanel()
                        .frame(height: geo.size.height * 0.5)
                        .panel()
                    CalendarView()
                        .panel()
                }
                .padding(16)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(item: $customExtend.booking) { booking in
            ExtendSheet(booking: booking)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
