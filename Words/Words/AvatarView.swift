import SwiftUI
import Supabase

// MARK: - Duotone palettes

/// The monogram's TRUE-DUOTONE palettes — each palette is a PAIR of flat
/// colors used as figure and ground: solid `background`, the initials in
/// solid `letter`. No gradients, no white text.
///
/// THE SWAP POINT: the curated set below is a placeholder list; the
/// Phase 14 design pass owns the final colors. Replace the cases /
/// `colors` pairs freely — nothing outside this enum encodes a color,
/// and persistence stores only the case name (profiles.avatar_palette;
/// 'auto' = derived from the display name).
///
/// FUNCTIONAL RULE for any replacement set: the two colors of a pair
/// MUST contrast strongly enough that the letters read at ~40pt (game
/// rows). The starter pairs below are all dark ground + light figure
/// from the same family, which guarantees that; keep the property when
/// swapping colors.
enum AvatarPalette: String, CaseIterable {
    /// Not a palette: pick deterministically from `curated` by name.
    case auto

    case ocean, sunset, forest, plum, ember, midnight, rose, gold, slate, mint

    /// The named options a user can choose from (excludes .auto).
    static let curated: [AvatarPalette] = [
        .ocean, .sunset, .forest, .plum, .ember,
        .midnight, .rose, .gold, .slate, .mint,
    ]

    /// The duotone pair: solid ground + solid figure.
    var colors: (background: Color, letter: Color) {
        switch self {
        case .auto:     return AvatarPalette.ocean.colors  // never rendered directly
        case .ocean:    return (Color(red: 0.09, green: 0.22, blue: 0.38),
                                Color(red: 0.62, green: 0.85, blue: 0.95))
        case .sunset:   return (Color(red: 0.50, green: 0.18, blue: 0.10),
                                Color(red: 0.98, green: 0.78, blue: 0.58))
        case .forest:   return (Color(red: 0.08, green: 0.26, blue: 0.16),
                                Color(red: 0.68, green: 0.90, blue: 0.72))
        case .plum:     return (Color(red: 0.24, green: 0.12, blue: 0.34),
                                Color(red: 0.85, green: 0.74, blue: 0.95))
        case .ember:    return (Color(red: 0.38, green: 0.08, blue: 0.08),
                                Color(red: 0.98, green: 0.74, blue: 0.35))
        case .midnight: return (Color(red: 0.08, green: 0.10, blue: 0.25),
                                Color(red: 0.70, green: 0.80, blue: 0.98))
        case .rose:     return (Color(red: 0.42, green: 0.10, blue: 0.20),
                                Color(red: 0.98, green: 0.74, blue: 0.84))
        case .gold:     return (Color(red: 0.28, green: 0.19, blue: 0.05),
                                Color(red: 0.95, green: 0.78, blue: 0.30))
        case .slate:    return (Color(red: 0.14, green: 0.16, blue: 0.21),
                                Color(red: 0.84, green: 0.88, blue: 0.92))
        case .mint:     return (Color(red: 0.05, green: 0.26, blue: 0.24),
                                Color(red: 0.68, green: 0.94, blue: 0.84))
        }
    }

    /// Human-readable name for the palette picker.
    var label: String { rawValue.capitalized }

    /// Deterministic name → palette pick: the same person gets the same
    /// colors on every device, every launch. Swift's Hasher is seeded
    /// per-process, so this uses a stable djb2 hash instead.
    static func derived(from name: String) -> AvatarPalette {
        var hash: UInt64 = 5381
        for scalar in name.uppercased().unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return curated[Int(hash % UInt64(curated.count))]
    }

    /// The palette to actually render for a stored choice.
    static func resolved(_ stored: String?, name: String) -> AvatarPalette {
        let choice = stored.flatMap(AvatarPalette.init(rawValue:)) ?? .auto
        return choice == .auto ? derived(from: name) : choice
    }
}

// MARK: - Avatar image loading

/// Shared in-memory avatar photo store, replacing AsyncImage. Why:
/// AsyncImage is one-shot per view identity — a failed or cancelled
/// load (easy to hit when a fresh upload lands mid-tab-switch) parks
/// forever in its failure phase, which our fallback renders as the
/// monogram, so a dead load looks exactly like "no photo" until the
/// whole screen is rebuilt. This store makes loads independent of any
/// view's lifetime: a finished fetch PUBLISHES the image and every
/// mounted AvatarView showing that URL re-renders at once; a failed
/// fetch simply retries on the next render instead of pinning the
/// fallback.
@MainActor
@Observable
final class AvatarImageStore {
    static let shared = AvatarImageStore()

    /// Loaded photos by exact URL (the ?t= stamp makes each upload a
    /// fresh key, so stale entries are never re-shown for self).
    private(set) var images: [URL: UIImage] = [:]
    /// Dedupe only — deliberately unobserved so kicking a fetch during
    /// body evaluation can't invalidate the very render that asked.
    @ObservationIgnored private var inFlight: Set<URL> = []

    /// Cache hit, or nil after kicking a background fetch. Reading
    /// `images` here is what subscribes the calling view to updates.
    func image(for url: URL) -> UIImage? {
        if let hit = images[url] { return hit }
        fetch(url)
        return nil
    }

    /// Pre-populate after an upload: the just-cropped image IS the
    /// photo at that URL, so every avatar can show it with zero network.
    func seed(_ image: UIImage, for url: URL) {
        images[url] = image
    }

    private func fetch(_ url: URL) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task {
            defer { inFlight.remove(url) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return }
            images[url] = image
        }
    }
}

// MARK: - AvatarView

/// THE avatar — the one component every screen renders. Shows the
/// user's PHOTO when one exists (public `avatars` bucket), else the
/// duotone initials MONOGRAM (chosen palette, or name-derived for
/// 'auto'). Never blank, works offline (monograms are client-side).
struct AvatarView: View {
    @Environment(\.theme) private var theme

    let name: String
    var photoURL: URL? = nil
    /// Stored palette choice ("auto" / a palette name / nil = auto).
    var palette: String? = nil
    var size: CGFloat = 40

    /// Convenience for the app's player model. avatarURL semantics:
    ///  • a URL string — the uploaded photo (cache-busted on upload);
    ///  • nil — UNKNOWN (payloads without avatar data): derive the
    ///    public bucket slot from the user id so friends' photos show
    ///    with no payload changes (a 404 just leaves the monogram);
    ///  • "" — EXPLICITLY NONE (the user removed their photo or chose
    ///    monogram colors): never derive, always monogram.
    init(profile: PlayerProfile, size: CGFloat = 40) {
        self.name = profile.displayName
        if let stored = profile.avatarURL {
            self.photoURL = stored.isEmpty ? nil : URL(string: stored)
        } else {
            self.photoURL = Self.publicAvatarURL(for: profile.id)
        }
        self.palette = profile.avatarPalette
        self.size = size
    }

    init(name: String, photoURL: URL? = nil, palette: String? = nil, size: CGFloat = 40) {
        self.name = name
        self.photoURL = photoURL
        self.palette = palette
        self.size = size
    }

    var body: some View {
        Group {
            // Photo and monogram are MUTUALLY EXCLUSIVE — never layered.
            // The shared store publishes loads to every mounted avatar,
            // so a new upload appears everywhere the moment it lands;
            // until then (or on failure/404) the monogram shows alone.
            if let photoURL, let photo = AvatarImageStore.shared.image(for: photoURL) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.chrome.border, lineWidth: theme.metrics.hairline))
    }

    private var monogram: some View {
        let duo = AvatarPalette.resolved(palette, name: name).colors
        return ZStack {
            Circle().fill(duo.background)
            Text(Self.initials(from: name))
                .font(theme.typography.font(size * 0.4, .heavy))
                .foregroundStyle(duo.letter)
        }
    }

    /// "Adam Clark" → "AC", "Robo" → "R", "" → "•".
    static func initials(from name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "•" : joined
    }

    /// The deterministic public slot for a user's photo
    /// (`avatars/{lowercased-user-id}.jpg` — one owned slot per user).
    static func publicAvatarURL(for id: UUID) -> URL? {
        try? SupabaseService.client.storage
            .from("avatars")
            .getPublicURL(path: "\(id.uuidString.lowercased()).jpg")
    }
}
