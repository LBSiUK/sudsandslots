import SwiftUI

/// Shows the app's own confirmation dialog. A custom view rather than an
/// .alert, because system alerts on iOS 15 can't colour buttons green/red.
final class Confirmer: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let message: String
        let confirmTitle: String
        let action: () -> Void
    }

    @Published fileprivate(set) var request: Request?

    func ask(_ message: String, confirmTitle: String, action: @escaping () -> Void) {
        request = Request(message: message, confirmTitle: confirmTitle, action: action)
    }

    fileprivate func answer(_ yes: Bool) {
        let action = request?.action
        request = nil
        if yes { action?() }
    }
}

/// Dimmed backdrop plus the dialog card; lay it over the whole screen.
struct ConfirmOverlay: View {
    @EnvironmentObject var confirmer: Confirmer

    static let yesGreen = Color(red: 0.13, green: 0.66, blue: 0.29)
    static let noRed = Color(red: 0.86, green: 0.18, blue: 0.18)

    var body: some View {
        ZStack {
            if let request = confirmer.request {
                // Swallows taps so nothing behind can be pressed; an answer is required.
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                card(for: request)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: confirmer.request?.id)
    }

    private func card(for request: Confirmer.Request) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("Your confirmation required")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text("Are you sure you want to:")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
                Text(request.message)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            HStack(spacing: 12) {
                button("No", color: Self.noRed) { confirmer.answer(false) }
                button(request.confirmTitle, color: Self.yesGreen) { confirmer.answer(true) }
            }
            .padding([.horizontal, .bottom], 18)
        }
        .foregroundColor(.white)
        .frame(width: 440)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.panelStroke))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private func button(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
