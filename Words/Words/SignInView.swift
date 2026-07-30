import SwiftUI
import AuthenticationServices

/// The auth gate: shown whenever there is no session. Minimal and
/// unstyled on purpose — the design pass comes later.
struct SignInView: View {
    @Environment(\.theme) private var theme

    let auth: AuthController

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("WORDS")
                .font(theme.typography.font(40, .black))
                .foregroundStyle(theme.chrome.ink)
            Text("Sign in to keep your games\nand play with friends.")
                .font(theme.typography.font(14, .regular))
                .foregroundStyle(theme.chrome.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()

            SignInWithAppleButton(.signIn) { request in
                auth.configureAppleRequest(request)
            } onCompletion: { result in
                Task { await auth.handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(Capsule())
            .padding(.horizontal, 32)

            if let error = auth.lastError {
                Text(error)
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer().frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chrome.screenBackground.ignoresSafeArea())
    }
}
