import SwiftUI
import UIKit
import UserNotifications
import Observation
import os

/// Console.app-visible breadcrumbs for the notification path (subsystem
/// com.kittyrobotics.Words.Words, category "push").
let pushLog = Logger(subsystem: "com.kittyrobotics.Words.Words", category: "push")

/// APNs registration callbacks land here and are forwarded on.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // INVARIANT: the UNUserNotificationCenter delegate MUST be installed
        // before this method returns. Setting it later (e.g. from a SwiftUI
        // view's init, which runs after scene connection) means the
        // notification response that COLD-LAUNCHED the app is silently
        // dropped — didReceive never fires. 100% reproducible on device;
        // the simulator's lenient timing masks it.
        MainActor.assumeIsolated {
            UNUserNotificationCenter.current().delegate = NotificationsController.shared
            if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
               let gameID = NotificationsController.gameID(fromUserInfo: payload) {
                // Belt & braces: some launch paths surface the payload here
                // instead of (or before) the delegate callback.
                pushLog.notice("didFinishLaunching carried game=\(gameID.uuidString, privacy: .public)")
                NotificationsController.shared.pendingGameID = gameID
            } else {
                pushLog.notice("didFinishLaunching (no notification payload)")
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            NotificationsController.shared.deviceTokenReceived(token)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator, or APNs unreachable. The app works fully without pushes.
    }
}

/// Owns notification permission, the APNs token's server registration,
/// tap-to-open routing, and the badge. The app never depends on any of it —
/// denial just means finding out it's your turn by opening the app.
@MainActor
@Observable
final class NotificationsController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationsController()

    enum Permission { case unknown, notAsked, denied, granted }
    private(set) var permission: Permission = .unknown

    /// Set when the user taps a push; RootView opens this game and clears it.
    var pendingGameID: UUID?
    /// The game currently on screen — its own banners are suppressed.
    var visibleGameID: UUID?
    /// Hex token currently registered server-side (for sign-out cleanup).
    private(set) var currentToken: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Launch-time: adopt the existing status; if already granted, refresh
    /// the token registration (tokens can rotate between launches).
    func refreshPermissionState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permission = .granted
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            permission = .denied
        case .notDetermined:
            permission = .notAsked
        @unknown default:
            permission = .notAsked
        }
    }

    /// The system prompt — only ever called after the in-app explanation
    /// (never on first launch; the player has to have a reason first).
    func requestPermission() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        permission = granted ? .granted : .denied
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func deviceTokenReceived(_ token: String) {
        currentToken = token
        Task { try? await RemoteGames.registerDeviceToken(token) }
    }

    /// Sign-out / account deletion: this device stops receiving pushes.
    func unregisterCurrentToken() async {
        guard let token = currentToken else { return }
        try? await RemoteGames.unregisterDeviceToken(token)
    }

    /// Badge = human games awaiting my move; recomputed from the local
    /// cache on foreground (pushes set it server-side in between).
    func updateBadge(from games: [SavedGame]) {
        let count = Self.awaitingMoveCount(in: games)
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }

    nonisolated static func awaitingMoveCount(in games: [SavedGame]) -> Int {
        games.filter {
            $0.gameOver == nil && $0.turnState == .local && $0.opponentIsHuman == true
        }.count
    }

    nonisolated static func gameID(fromUserInfo userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["game_id"] as? String).flatMap(UUID.init)
    }

    // MARK: - UNUserNotificationCenterDelegate
    //
    // INVARIANT (learned from a device crash): these callbacks arrive on a
    // background queue, and their completion handlers feed straight back
    // into UIKit (banner teardown, scene activation) — so the handler body
    // AND the completionHandler call must both run on the main thread. The
    // async delegate variants resume the framework thunk off-main and
    // crash with "Call must be made on main thread"; use the
    // completion-handler variants with an explicit main hop, only.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let gameID = Self.gameID(fromUserInfo: notification.request.content.userInfo)
        pushLog.notice("willPresent game=\(gameID?.uuidString ?? "nil", privacy: .public)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // The board you're looking at already shows the move — no banner.
                let suppressed = gameID != nil && gameID == self.visibleGameID
                pushLog.notice("willPresent resolved suppressed=\(suppressed)")
                completionHandler(suppressed ? [.badge] : [.banner, .sound, .badge])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let gameID = Self.gameID(fromUserInfo: response.notification.request.content.userInfo)
        pushLog.notice("didReceive tap game=\(gameID?.uuidString ?? "nil", privacy: .public)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let gameID {
                    // Stays pending until RootView's session is ready —
                    // a cold-launch tap arrives before the store exists.
                    self.pendingGameID = gameID
                    pushLog.notice("didReceive parked game=\(gameID.uuidString, privacy: .public)")
                }
                completionHandler()
            }
        }
    }
}
