import SwiftUI

@main
struct SudsAndSlotsApp: App {
    @StateObject private var store = BookingStore()
    @StateObject private var form = BookingForm()
    @StateObject private var idle = IdleMonitor()
    @StateObject private var confirmer = Confirmer()
    @StateObject private var customExtend = CustomExtend()
    @StateObject private var rescheduler = Rescheduler()

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
                .environmentObject(rescheduler)
                .confirmationAlert(confirmer)
                .background(IdleTouchWatcher(monitor: idle))
                .preferredColorScheme(.dark)
                #if DEBUG
                .onAppear(perform: forceLandscapeForScreenshots)
                .syncScreenshotSheets(store: store, form: form)
                .onAppear { runSyncSmokeTest(store); runSyncPushTest(store) }
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

/// `-syncSmokeTest`: through the same store calls the buttons use, books
/// Leon's washer 7-8 AM tomorrow, then extends it by 90 minutes (pushing any
/// later washer slot back), to exercise server sync without tapping.
private func runSyncSmokeTest(_ store: BookingStore) {
    guard ProcessInfo.processInfo.arguments.contains("-syncSmokeTest") else { return }
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    let start = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow)!
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        do {
            try store.bookChain(.leon, start: start, stages: [(.washer, 60)])
            print("[smoke] booked")
        } catch {
            print("[smoke] book failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let b = store.bookings.first(where: { $0.person == .leon && $0.machine == .washer && $0.start == start }) else {
                print("[smoke] booking not found"); return
            }
            print("[smoke] extending \(b.id)")
            store.extend(b, by: 90)
        }
    }
}

/// `-syncPushTest`: Sam quick-adds a 30-minute wash at 7 AM tomorrow,
/// shoving whatever unstarted washer bookings are there along.
private func runSyncPushTest(_ store: BookingStore) {
    guard ProcessInfo.processInfo.arguments.contains("-syncPushTest") else { return }
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    let start = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow)!
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        do {
            let moves = try store.pushPlan(.sam, start: start, stages: [(.washer, 30)])
            print("[push] plan: \(moves.map { "\($0.booking.person.name) \($0.booking.timeRange) -> \($0.newTimeRange)" })")
            try store.bookChain(.sam, start: start, stages: [(.washer, 30)], push: true)
            print("[push] booked")
        } catch {
            print("[push] failed: \(error.localizedDescription)")
        }
    }
}

/// `-serverSettings` / `-notifications` open those sheets at launch for screenshots.
private struct SyncScreenshotSheets: ViewModifier {
    let store: BookingStore
    let form: BookingForm
    @State private var settings = ProcessInfo.processInfo.arguments.contains("-serverSettings")
    @State private var notifications = ProcessInfo.processInfo.arguments.contains("-notifications")
    /// `-notifications ruby` picks whose list to show.
    private var notificationsPerson: Person? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-notifications"), i + 1 < args.count else { return nil }
        return Person(rawValue: args[i + 1])
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $settings) {
                ServerSettingsView().environmentObject(store).preferredColorScheme(.dark)
            }
            .background(EmptyView().sheet(isPresented: $notifications) {
                NotificationsView(person: notificationsPerson ?? form.person).environmentObject(store).preferredColorScheme(.dark)
            })
    }
}

extension View {
    func syncScreenshotSheets(store: BookingStore, form: BookingForm) -> some View {
        modifier(SyncScreenshotSheets(store: store, form: form))
    }

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
    @EnvironmentObject var rescheduler: Rescheduler

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
        // A second sheet needs its own view on iOS 15.
        .background(Color.clear.sheet(item: $rescheduler.booking) { booking in
            RescheduleSheet(booking: booking)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        })
        .sheet(item: $customExtend.booking) { booking in
            ExtendSheet(booking: booking)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
