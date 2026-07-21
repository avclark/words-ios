import SwiftUI

/// Placeholder home screen. Unstyled on purpose — design pass comes later.
struct HomeView: View {
    let onNewGame: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("WORDS")
                .font(.system(size: 34, weight: .black, design: .rounded))
            Button("New Game", action: onNewGame)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
