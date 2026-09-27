import SwiftUI

/// Asks "Are you sure you want to:" with a native alert. Views call `ask`; the
/// alert itself is attached once at the root with `.confirmationAlert`.
final class Confirmer: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let message: String
        let confirmTitle: String
        /// Shown in red, e.g. cancelling a booking.
        let destructive: Bool
        let action: () -> Void
    }

    @Published fileprivate var request: Request?

    func ask(_ message: String, confirmTitle: String, destructive: Bool = false,
             action: @escaping () -> Void) {
        request = Request(message: message, confirmTitle: confirmTitle, destructive: destructive, action: action)
    }
}

extension View {
    func confirmationAlert(_ confirmer: Confirmer) -> some View {
        alert("Your confirmation required",
              isPresented: Binding(get: { confirmer.request != nil },
                                   set: { if !$0 { confirmer.request = nil } }),
              presenting: confirmer.request) { request in
            // "No" must have the cancel role, or SwiftUI adds its own Cancel button.
            Button("No", role: .cancel) {}
            Button(request.confirmTitle, role: request.destructive ? .destructive : nil) { request.action() }
        } message: { request in
            Text("Are you sure you want to:\n\(request.message)")
        }
    }
}
