import Foundation
import Observation
import AuthenticationServices
import CryptoKit
import Security
import Supabase

/// Owns auth state for the whole app: the Supabase session, sign-in with
/// Apple, the server-side profile, sign-out, and account deletion.
///
/// Identity model (PRODUCT-SPEC requirement): the stable internal user ID
/// is `auth.users.id`. The Apple identity is one linked row in
/// `auth.identities` under that user — the user HAS an Apple credential,
/// the user IS not the Apple identity. Adding Google/email later is an
/// additive identity row against the same user ID; no migration.
@Observable
final class AuthController {

    enum State: Equatable {
        /// Loading the stored session at launch.
        case loading
        /// No session — the app shows the sign-in screen.
        case signedOut
        /// Signed in; the value is the stable internal user ID.
        case signedIn(UUID)
    }

    private(set) var state: State = .loading
    /// Human-readable error from the last auth attempt, for the sign-in UI.
    private(set) var lastError: String?
    /// Fired after the server confirms account deletion, before local
    /// sign-out — the owner clears account-local data (game cache) here.
    var onAccountDeleted: (() -> Void)?
    /// Fired before any sign-out (including deletion) — the owner
    /// unregisters this device's push token so a signed-out phone
    /// stops receiving that account's notifications.
    var onWillSignOut: (() async -> Void)?

    private let client = SupabaseService.client
    /// Raw nonce for the in-flight Apple request; Apple receives its SHA-256.
    private var currentNonce: String?
    /// Display name from Apple — only delivered on the FIRST authorization,
    /// so it's captured at credential time and applied once the session lands.
    private var pendingAppleName: String?

    var signedInUserID: UUID? {
        if case .signedIn(let id) = state { return id }
        return nil
    }

    /// Runs for the app's lifetime, mirroring Supabase session events into
    /// `state`. An expired or revoked session surfaces here as a signed-out
    /// event, not an error — the app just returns to the sign-in screen.
    func start() async {
        // Phase 6 shipped a temporary "continue offline" bypass while Apple
        // sign-in couldn't be configured; anyone still carrying its flag
        // just falls through to the sign-in screen now.
        UserDefaults.standard.removeObject(forKey: "authOfflineModeChosen")

        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                if let session {
                    state = .signedIn(session.user.id)
                } else if state == .loading {
                    state = .signedOut
                }
            case .signedOut:
                state = .signedOut
            default:
                break
            }
        }
    }

    // MARK: - Sign in with Apple

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        // A new attempt starts: whatever the last one said is stale now.
        lastError = nil
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                lastError = "Apple didn't return a usable credential."
                return
            }
            if let name = credential.fullName {
                let joined = [name.givenName, name.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                if !joined.isEmpty { pendingAppleName = joined }
            }
            lastError = nil
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: currentNonce)
            )
            // `state` flips via the authStateChanges stream.
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User dismissed the Apple sheet; not an error.
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Sign out & account deletion

    func signOut() async {
        await onWillSignOut?()
        do {
            try await client.auth.signOut()
        } catch {
            // Server unreachable: still drop the local session so the user
            // is signed out on this device.
            try? await client.auth.signOut(scope: .local)
        }
        state = .signedOut
    }

    /// App Store requirement: really deletes the user's data server-side.
    /// The `delete_account` RPC (supabase/setup.sql) removes the auth user;
    /// profile and identities follow by cascade. Games saved on this device
    /// are untouched — they're local-only until Phase 7.
    func deleteAccount() async -> Bool {
        await onWillSignOut?()
        do {
            try await client.rpc("delete_account").execute()
            onAccountDeleted?()
            try? await client.auth.signOut(scope: .local)
            state = .signedOut
            return true
        } catch {
            lastError = "Account deletion failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Server-side profile

    private struct RemoteProfile: Codable {
        var id: UUID
        var displayName: String
        var avatar: String

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case avatar
        }
    }

    /// Merge the server profile with the local one after sign-in and return
    /// what the app should now use, or nil if the server is unreachable
    /// (play continues on the local profile; nothing is lost).
    ///
    /// A fresh server row (still the trigger default) is seeded from
    /// Apple's name when available, else from the local profile. An
    /// established server row wins — the server is the source of truth.
    func resolveProfile(local: PlayerProfile) async -> PlayerProfile? {
        guard let userID = signedInUserID else { return nil }
        let appleName = pendingAppleName
        pendingAppleName = nil
        do {
            var remote: RemoteProfile = try await client
                .from("profiles")
                .select()
                .eq("id", value: userID)
                .single()
                .execute()
                .value
            if remote.displayName == "Player" {
                let localName = local.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                remote.displayName = appleName ?? (localName.isEmpty ? "Player" : localName)
                remote.avatar = local.avatar.rawValue
                try await push(displayName: remote.displayName, avatar: remote.avatar, userID: userID)
            }
            return PlayerProfile(id: userID,
                                 displayName: remote.displayName,
                                 avatar: Avatar(rawValue: remote.avatar) ?? .bolt)
        } catch {
            return nil
        }
    }

    /// Push local profile edits to the server (no-op when not signed in).
    func pushProfile(_ profile: PlayerProfile) async {
        guard let userID = signedInUserID else { return }
        try? await push(displayName: profile.displayName,
                        avatar: profile.avatar.rawValue,
                        userID: userID)
    }

    private func push(displayName: String, avatar: String, userID: UUID) async throws {
        try await client
            .from("profiles")
            .update(["display_name": displayName, "avatar": avatar])
            .eq("id", value: userID)
            .execute()
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "Unable to generate sign-in nonce")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }
}
