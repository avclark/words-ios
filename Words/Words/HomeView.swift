import SwiftUI

/// Placeholder home screen with a thin local profile editor (name + avatar).
/// Becomes the game lobby in Phase 5; full design pass later.
struct HomeView: View {
    @Binding var profile: PlayerProfile
    let onNewGame: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Text("WORDS")
                .font(.system(size: 34, weight: .black, design: .rounded))

            VStack(spacing: 14) {
                TextField("Your name", text: $profile.displayName)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .autocorrectionDisabled()

                HStack(spacing: 10) {
                    ForEach(Avatar.humanChoices, id: \.self) { avatar in
                        Button {
                            profile.avatar = avatar
                        } label: {
                            ZStack {
                                Circle().fill(avatar.tint.opacity(0.22))
                                Image(systemName: avatar.symbolName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(avatar.tint)
                            }
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle().strokeBorder(profile.avatar == avatar ? Color.yellow : .clear,
                                                      lineWidth: 2)
                            )
                        }
                    }
                }
            }

            Button("New Game", action: onNewGame)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
