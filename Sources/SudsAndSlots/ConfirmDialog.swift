import SwiftUI

/// Asks "Are you sure you want to:" with a native alert. Views call `ask`; the
/// alert itself is attached once at the root with `.confirmationAlert`.
final class Confirmer: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        /// Finishes "Are you sure you want to …", e.g. "cancel Leon's booking".
        let question: String
        /// Smaller line underneath, e.g. the time range.
        let detail: String
        let confirmTitle: String
        /// Shown in red, e.g. cancelling a booking.
        let destructive: Bool
        let action: () -> Void
    }

    @Published fileprivate var request: Request?

    func ask(_ question: String, detail: String, confirmTitle: String, destructive: Bool = false,
             action: @escaping () -> Void) {
        request = Request(question: question, detail: detail, confirmTitle: confirmTitle,
                          destructive: destructive, action: action)
    }
}

extension View {
    func confirmationAlert(_ confirmer: Confirmer) -> some View {
        // The question goes in the title: it's the only part of a native alert
        // drawn bold and bright. The message is always small grey text.
        alert(confirmer.request.map { "Your confirmation required\n\nAre you sure you want to \($0.question)?" } ?? "",
              isPresented: Binding(get: { confirmer.request != nil },
                                   set: { if !$0 { confirmer.request = nil } }),
              presenting: confirmer.request) { request in
            // "No" must have the cancel role, or SwiftUI adds its own Cancel button.
            Button("No", role: .cancel) {}
            Button(request.confirmTitle, role: request.destructive ? .destructive : nil) { request.action() }
        } message: { request in
            Text(request.detail)
        }
    }
}
