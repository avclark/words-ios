import SwiftUI
import AuthenticationServices

/// The auth gate: shown whenever there is no session. Minimal and
/// unstyled on purpose — the design pass comes later.
struct SignInView: View {
    let auth: AuthController

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("WORDS")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("Sign in to keep your games\nand play with friends.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
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
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer().frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeView.background.ignoresSafeArea())
    }
}
