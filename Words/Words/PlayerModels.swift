import SwiftUI

// MARK: - Avatar

/// Simple built-in avatar set: SF Symbol + tint. Deliberately minimal — the
/// profile system gets rebuilt against server data later (see PRODUCT-SPEC).
enum Avatar: String, CaseIterable, Codable, Equatable {
    case bolt, flame, leaf, drop, star, heart, moon, crown, robot

    /// Choices offered to a human player (the robot is the AI's default,
    /// but nothing breaks if a human picks it too).
    static let humanChoices: [Avatar] = [.bolt, .flame, .leaf, .drop, .star, .heart, .moon, .crown]

    var symbolName: String {
        switch self {
        case .bolt: return "bolt.fill"
        case .flame: return "flame.fill"
        case .leaf: return "leaf.fill"
        case .drop: return "drop.fill"
        case .star: return "star.fill"
        case .heart: return "heart.fill"
        case .moon: return "moon.fill"
        case .crown: return "crown.fill"
        case .robot: return "cpu.fill"
        }
    }

    var tint: Color {
        switch self {
        case .bolt: return .yellow
        case .flame: return .orange
        case .leaf: return .green
        case .drop: return .blue
        case .star: return .purple
        case .heart: return .pink
        case .moon: return .indigo
        case .crown: return .brown
        case .robot: return .cyan
        }
    }
}

// MARK: - Profile & player

/// Who someone is: stable internal ID plus presentation. The ID is the
/// primary identity — later, server credentials (Sign in with Apple) hang
/// off a user record keyed by an ID like this, per PRODUCT-SPEC.
struct PlayerProfile: Identifiable, Equatable, Codable {
    let id: UUID
    var displayName: String
    var avatar: Avatar

    /// The built-in AI opponent's profile. Fixed ID so it's the same
    /// "user" across games.
    static let ai = PlayerProfile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A1A1")!,
                                  displayName: "Robo",
                                  avatar: .robot)
}

/// A participant in one game: identity plus per-game state. "You" and the
/// AI are two instances of this same type; a remote human later becomes a
/// third instance with no changes to the game screen.
struct Player: Identifiable, Equatable {
    var profile: PlayerProfile
    var score = 0
    var rack: [Tile] = []

    var id: UUID { profile.id }
}

// MARK: - Local profile storage

/// UserDefaults-backed store for the local player's profile. Deliberately
/// thin; replaced by real account data once a backend exists.
enum LocalProfile {
    private static let key = "localPlayerProfile"

    static func load() -> PlayerProfile {
        if let data = UserDefaults.standard.data(forKey: key),
           let profile = try? JSONDecoder().decode(PlayerProfile.self, from: data) {
            return profile
        }
        // First launch: mint a stable ID once and keep it forever.
        let fresh = PlayerProfile(id: UUID(), displayName: "Player", avatar: .bolt)
        save(fresh)
        return fresh
    }

    static func save(_ profile: PlayerProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
