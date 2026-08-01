import SwiftUI

// MARK: - Stats data (UI shape)

/// Everything the Profile stats page can show. Optional fields render as
/// "—" when absent.
///
/// Data-source status: every block has a REAL source once
/// supabase/phase13d_profile_stats.sql is applied (fetch_profile_stats —
/// skill stats over all games, win/streak stats over human games only).
/// Until it's pasted, the client falls back to the Phase 13 fetch_stats
/// mapping (wins / avg game / best game / best word) and the rest show
/// "—".
struct ProfileStatsData {
    struct Month: Identifiable {
        let id = UUID()
        let label: String     // "APR"
        let value: Double     // average word score that month
    }

    var avgWordThisMonth: Double?
    var avgWordLifetime: Double?
    var monthlyAvgWord: [Month] = []
    var bestWord: (word: String, score: Int)?
    var avgGame: Int?
    var bestGame: Int?
    var wins: Int?
    var longestStreak: Int?
    var currentStreak: Int?
    var words50Plus: Int?
    var words40Plus: Int?
    var words30Plus: Int?
    var bingos: Int?
    var lastBingo: String?

    // Phase 13e friends-percentiles ("Top N%", lower is better). nil =
    // no badge: suppressed below the server's population floor, no data
    // for the stat, or the 13e SQL not applied yet.
    var avgWordPct: Int?
    var bestWordPct: Int?
    var bestGamePct: Int?
    var winsPct: Int?
    var bingosPct: Int?
}

// MARK: - Profile hub

/// The Profile tab: identity (avatar slot + name + username) and the
/// full stats page, with everything else (notifications, sound, account,
/// legal) behind the gear icon's Settings sheet. Stats layout mirrors
/// Scrabble GO's arrangement; styling is the existing token system —
/// the visual hierarchy pass is Phase 14's.
struct ProfileView: View {
    #if DEBUG
    /// DEV SWITCH — fills every stat block with plausible FAKE numbers
    /// so the layout can be judged before the stats backend round.
    /// Client-side only: while true, the stats RPC is never called and
    /// nothing touches Supabase (identity/username stay real). Same
    /// pattern as FriendsStore.useMockFriends; compile-time walled —
    /// this symbol cannot exist in a release build.
    static let useMockStats = false

    static let mockStats = ProfileStatsData(
        avgWordThisMonth: 18.4,
        avgWordLifetime: 16.9,
        monthlyAvgWord: [.init(label: "APR", value: 15.2),
                         .init(label: "MAY", value: 16.8),
                         .init(label: "JUN", value: 17.5),
                         .init(label: "JUL", value: 18.4)],
        bestWord: ("QUARTZ", 68),
        avgGame: 342,
        bestGame: 461,
        wins: 27,
        longestStreak: 6,
        currentStreak: 2,
        words50Plus: 4,
        words40Plus: 11,
        words30Plus: 26,
        bingos: 9,
        lastBingo: "RETAINS",
        avgWordPct: 10,
        bestWordPct: 25,
        bestGamePct: 25,
        winsPct: 40,
        bingosPct: 50
    )
    #endif

    @Environment(\.theme) private var theme

    @Binding var profile: PlayerProfile
    let auth: AuthController

    @State private var showSettings = false
    @State private var stats = ProfileStatsData()
    // Username editing (unchanged behavior, moved from the old sheet).
    @State private var username = ""
    @State private var savedUsername: String?
    @State private var usernameFeedback: (text: String, good: Bool)?
    @State private var savingUsername = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROFILE")
                    .font(theme.typography.font(20, .black))
                    .foregroundStyle(theme.chrome.ink)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.chrome.ink.opacity(0.7))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(theme.chrome.ink.opacity(0.08)))
                }
            }
            .padding(.horizontal, theme.metrics.screenHPadding)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    statsSection
                }
                .padding(.horizontal, theme.metrics.screenHPadding)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsSheet(auth: auth)
        }
        .task {
            await loadIdentity()
            await loadStats()
        }
    }

    // MARK: Identity

    private var identitySection: some View {
        section("IDENTITY") {
            VStack(spacing: 12) {
                // Avatar slot: the existing icon picker stands in until
                // photo avatars (a separate future round).
                HStack(spacing: 10) {
                    ForEach(Avatar.humanChoices, id: \.self) { avatar in
                        Button {
                            profile.avatar = avatar
                        } label: {
                            AvatarCircle(avatar: avatar, size: 36)
                                .overlay(
                                    Circle().strokeBorder(profile.avatar == avatar ? theme.chrome.accent : .clear,
                                                          lineWidth: theme.metrics.selectionBorder)
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                TextField("Your name", text: $profile.displayName)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .autocorrectionDisabled()

                usernameRows
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Optional search handle, distinct from the display name on purpose:
    /// the name is what people SEE (free-form, duplicable, zero friction);
    /// the username is how people FIND you (unique, opt-in — no username
    /// means not searchable, which is a privacy default, not a gap).
    private var usernameRows: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("@")
                    .font(theme.typography.font(14, .bold))
                    .foregroundStyle(theme.chrome.ink.opacity(0.4))
                TextField("username (optional)", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 170)
                    .onSubmit { saveUsername() }
                if username.lowercased() != (savedUsername ?? "") {
                    Button("Save") { saveUsername() }
                        .font(theme.typography.font(13, .semibold))
                        .disabled(savingUsername)
                }
            }
            if let feedback = usernameFeedback {
                Text(feedback.text)
                    .font(theme.typography.font(11, .regular))
                    .foregroundStyle(feedback.good ? theme.semantic.validMove.opacity(0.8)
                                                   : theme.chrome.error)
            } else {
                Text("Friends can find you by your name. A username is an optional exact handle on top.")
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.chrome.ink.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func saveUsername() {
        let cleaned = username.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        username = cleaned
        savingUsername = true
        Task {
            defer { savingUsername = false }
            guard let result = try? await RemoteGames.setUsername(cleaned.isEmpty ? nil : cleaned) else {
                usernameFeedback = ("Couldn't save — check your connection.", false)
                return
            }
            switch result {
            case "ok":
                savedUsername = cleaned
                usernameFeedback = ("You're @\(cleaned) — friends can find you by it.", true)
            case "cleared":
                savedUsername = nil
                usernameFeedback = ("Username removed — you won't appear in search.", true)
            case "taken":
                usernameFeedback = ("@\(cleaned) is taken — try another.", false)
            default:
                usernameFeedback = ("3–20 characters: a–z, 0–9, and underscores.", false)
            }
        }
    }

    private func loadIdentity() async {
        guard let userID = auth.signedInUserID else { return }
        if let existing = try? await RemoteGames.fetchUsername(userID: userID) {
            savedUsername = existing
            username = existing ?? ""
        }
    }

    /// Mock-aware stats load. Real path: the Phase 13d profile-stats RPC
    /// (every block). If that RPC isn't available yet (SQL not pasted,
    /// or offline), fall back to the Phase 13 fetch_stats mapping so the
    /// profile still shows what it can — never a crash, never a block.
    private func loadStats() async {
        #if DEBUG
        if Self.useMockStats {
            stats = Self.mockStats
            return
        }
        #endif
        if let full = try? await RemoteGames.fetchProfileStats() {
            var real = ProfileStatsData()
            real.avgWordLifetime = full.avgWord.lifetime
            real.avgWordThisMonth = full.avgWord.thisMonth
            real.monthlyAvgWord = full.avgWord.monthly.map {
                .init(label: Self.monthLabel($0.month), value: $0.avg)
            }
            real.bestWord = full.bestWord.map { ($0.word, $0.score) }
            real.avgGame = full.avgGame
            real.bestGame = full.bestGame
            real.wins = full.wins
            real.longestStreak = full.streaks.longest
            real.currentStreak = full.streaks.current
            real.words50Plus = full.pointWords.w50
            real.words40Plus = full.pointWords.w40
            real.words30Plus = full.pointWords.w30
            real.bingos = full.bingos.count
            real.lastBingo = full.bingos.lastWord
            real.avgWordPct = full.percentiles?.avgWord
            real.bestWordPct = full.percentiles?.bestWord
            real.bestGamePct = full.percentiles?.bestGame
            real.winsPct = full.percentiles?.wins
            real.bingosPct = full.percentiles?.bingos
            stats = real
            return
        }
        guard let fetched = try? await RemoteGames.fetchStats() else { return }
        var real = ProfileStatsData()
        real.wins = fetched.human.wins
        real.avgGame = fetched.human.avgScore
        real.bestGame = fetched.bestGame
        real.bestWord = fetched.bestWord.map { ($0.word, $0.score) }
        stats = real
    }

    /// "2026-04" → "APR" (bar-chart axis label).
    private static func monthLabel(_ isoMonth: String) -> String {
        guard let m = Int(isoMonth.suffix(2)), (1...12).contains(m),
              let symbols = DateFormatter().shortMonthSymbols, m <= symbols.count
        else { return isoMonth }
        return symbols[m - 1].uppercased()
    }

    // MARK: Stats blocks (layout mirrors Scrabble GO's stats page)

    private var statsSection: some View {
        section("STATS") {
            averageWordCard
            bestWordCard
            HStack(spacing: 10) {
                statCard("AVERAGE GAME", figure(stats.avgGame), detail: nil)
                statCard("BEST GAME", figure(stats.bestGame), detail: nil,
                         badge: stats.bestGamePct)
            }
            statCard("WINS", figure(stats.wins), detail: nil, badge: stats.winsPct)
            twoUp(("LONGEST WIN STREAK", figure(stats.longestStreak)),
                  ("CURRENT WIN STREAK", figure(stats.currentStreak)))
            pointWordsCard
            bingosCard
        }
    }

    /// The Phase 13e friends-percentile badge — rendered only when a
    /// percentile exists (nil = suppressed/no data = no badge at all).
    private func topBadge(_ pct: Int) -> some View {
        Text("TOP \(pct)%")
            .font(theme.typography.font(9, .heavy))
            .kerning(0.5)
            .foregroundStyle(theme.chrome.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.chrome.accent))
    }

    /// A stat label with its optional percentile badge alongside.
    private func labelRow(_ text: String, badge: Int?) -> some View {
        HStack(spacing: 6) {
            statLabel(text)
            if let badge {
                topBadge(badge)
            }
        }
    }

    /// Average word score: this month, the monthly bar chart, lifetime.
    private var averageWordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelRow("AVERAGE WORD SCORE", badge: stats.avgWordPct)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.avgWordThisMonth.map { String(format: "%.1f", $0) } ?? "—")
                        .font(theme.typography.font(22, .black))
                        .foregroundStyle(theme.chrome.accent)
                    statDetail("this month")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(stats.avgWordLifetime.map { String(format: "%.1f", $0) } ?? "—")
                        .font(theme.typography.font(22, .black))
                        .foregroundStyle(theme.chrome.textPrimary)
                    statDetail("lifetime")
                }
            }
            if stats.monthlyAvgWord.isEmpty {
                statDetail("Monthly averages will chart here once there's data.")
            } else {
                monthlyChart
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(card)
    }

    /// A small bar chart of the last few months' average word score —
    /// plain themed bars (no chart framework), heights normalized to the
    /// series maximum.
    private var monthlyChart: some View {
        let peak = stats.monthlyAvgWord.map(\.value).max() ?? 1
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(stats.monthlyAvgWord) { month in
                VStack(spacing: 4) {
                    Text(String(format: "%.1f", month.value))
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.chrome.ink.opacity(0.45))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.chrome.accent.opacity(month.id == stats.monthlyAvgWord.last?.id ? 1 : 0.45))
                        .frame(height: max(8, 56 * month.value / peak))
                    Text(month.label)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.chrome.ink.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var bestWordCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelRow("BEST WORD", badge: stats.bestWordPct)
            if let best = stats.bestWord {
                WordTileDisplay(word: best.word)
                Text("+\(best.score)")
                    .font(theme.typography.font(15, .heavy))
                    .foregroundStyle(theme.chrome.accent)
            } else {
                statDetail("No words played yet.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(card)
    }

    private var pointWordsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            statLabel("HIGH-SCORING WORDS")
            HStack(spacing: 10) {
                miniFigure("50+ PTS", figure(stats.words50Plus))
                miniFigure("40+ PTS", figure(stats.words40Plus))
                miniFigure("30+ PTS", figure(stats.words30Plus))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(card)
    }

    private var bingosCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelRow("BINGOS", badge: stats.bingosPct)
            Text(figure(stats.bingos))
                .font(theme.typography.font(18, .black))
                .foregroundStyle(theme.chrome.accent)
            if let last = stats.lastBingo {
                statDetail("last bingo")
                WordTileDisplay(word: last)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(card)
    }

    // MARK: Small pieces

    private func figure(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func twoUp(_ left: (String, String), _ right: (String, String)) -> some View {
        HStack(spacing: 10) {
            statCard(left.0, left.1, detail: nil)
            statCard(right.0, right.1, detail: nil)
        }
    }

    private func statCard(_ label: String, _ value: String, detail: String?,
                          badge: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labelRow(label, badge: badge)
            Text(value)
                .font(theme.typography.font(18, .black))
                .foregroundStyle(theme.chrome.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail {
                statDetail(detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.metrics.cardPadding)
        .background(card)
    }

    private func miniFigure(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(theme.typography.font(18, .black))
                .foregroundStyle(theme.chrome.textPrimary)
            Text(label)
                .font(theme.typography.font(9, .heavy))
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    private func statLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.font(9, .heavy))
            .kerning(1)
            .foregroundStyle(theme.chrome.ink.opacity(0.4))
    }

    private func statDetail(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.caption)
            .foregroundStyle(theme.chrome.ink.opacity(0.45))
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
            .fill(theme.chrome.cardFill)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(theme.typography.sectionTitle)
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
            content()
        }
    }
}

// MARK: - Settings sheet

/// Everything that isn't identity or stats, consolidated behind the
/// Profile gear: notification toggles, the sound/haptics slot, account
/// controls, legal. Content renders immediately (sections carry their
/// own loading/error/loaded states — never a blank sheet).
struct SettingsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let auth: AuthController

    @State private var confirmingDelete = false
    @State private var prefs: RemoteGames.NotificationPrefs?
    @State private var prefsLoadFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("SETTINGS")
                        .font(theme.typography.font(15, .black))
                        .kerning(1.5)
                        .foregroundStyle(theme.chrome.textPrimary)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(theme.typography.font(14, .semibold))
                }

                notificationSection

                section("SOUND & HAPTICS") {
                    // Slot only: no sound/haptics toggles exist yet (the
                    // FEATURE-LIST settings item). Wire real toggles here
                    // when they're built — do not invent behavior.
                    statDetailText("Sound and haptic settings will live here.")
                }

                section("APPEARANCE") {
                    // Slot only: when the themes feature lands
                    // (post-Phase-14 design pass), the theme picker goes
                    // right here — do not build switching before then.
                    statDetailText("Theme settings will live here.")
                }

                section("ACCOUNTS") {
                    // Slot only: the identity model supports additive
                    // sign-in providers later (PRODUCT-SPEC); managing
                    // connected methods lands here. Apple-only today —
                    // the current auth is stated by "Signed in with
                    // Apple" below. Do not build account linking yet.
                    statDetailText("Connected sign-in methods will appear here.")
                }

                section("LEGAL") {
                    // Slot only: Terms & Privacy Policy are Phase 15
                    // (ship) deliverables; rows/links land here then.
                    statDetailText("Terms and the privacy policy will live here.")
                }

                Divider().overlay(theme.chrome.border)

                accountSection
            }
            .padding(.horizontal, theme.metrics.screenHPadding)
            .padding(.vertical, 20)
        }
        .background(theme.chrome.screenBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.chrome.screenBackground)
        .task {
            await loadPrefs()
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Delete account", role: .destructive) {
                Task {
                    if await auth.deleteAccount() { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and profile from the server. Games saved on this device stay on this device.")
        }
    }

    private func loadPrefs() async {
        guard let userID = auth.signedInUserID else { return }
        prefsLoadFailed = false
        do {
            prefs = try await RemoteGames.fetchNotificationPrefs(userID: userID)
        } catch {
            // Say so — an empty section is indistinguishable from broken.
            prefsLoadFailed = true
        }
    }

    /// Per-type push toggles, honored server-side (a disabled type is never
    /// queued, let alone sent). The list is FEATURE-LIST's exact events —
    /// there is nothing else to toggle because nothing else is ever sent.
    /// The section header ALWAYS renders with toggles, an error+retry, or
    /// a spinner — never a silent blank (that hid a decode bug once).
    private var notificationSection: some View {
        section("NOTIFICATIONS") {
            if prefs != nil {
                prefToggle("Your turn", \.turn)
                prefToggle("New games", \.newGame)
                prefToggle("Game over", \.gameOver)
                prefToggle("Expiry warnings", \.expiryWarning)
                prefToggle("Nudges from opponents", \.ping)
                prefToggle("Chat messages", \.chat)
                prefToggle("Friend requests", \.friend)
            } else if prefsLoadFailed {
                HStack {
                    Text("Couldn't load notification settings.")
                        .font(theme.typography.font(12, .regular))
                        .foregroundStyle(theme.chrome.ink.opacity(0.5))
                    Button("Try again") {
                        Task { await loadPrefs() }
                    }
                    .font(theme.typography.font(12, .semibold))
                }
            } else {
                ProgressView()
                    .tint(theme.chrome.ink.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func prefToggle(_ label: String,
                            _ keyPath: WritableKeyPath<RemoteGames.NotificationPrefs, Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { prefs?[keyPath: keyPath] ?? true },
            set: { newValue in
                prefs?[keyPath: keyPath] = newValue
                if let prefs {
                    Task { try? await RemoteGames.saveNotificationPrefs(prefs) }
                }
            }))
            .font(theme.typography.body)
            .tint(theme.chrome.accent)
    }

    @ViewBuilder
    private var accountSection: some View {
        if case .signedIn = auth.state {
            VStack(spacing: 12) {
                Text("Signed in with Apple")
                    .font(theme.typography.font(12, .regular))
                    .foregroundStyle(theme.chrome.ink.opacity(0.45))
                HStack(spacing: 20) {
                    Button("Sign out") {
                        Task {
                            await auth.signOut()
                            dismiss()
                        }
                    }
                    .font(theme.typography.font(14, .semibold))
                    Button("Delete account…", role: .destructive) {
                        confirmingDelete = true
                    }
                    .font(theme.typography.font(14, .semibold))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(theme.typography.sectionTitle)
                .kerning(1)
                .foregroundStyle(theme.chrome.ink.opacity(0.4))
            content()
        }
    }

    private func statDetailText(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.caption)
            .foregroundStyle(theme.chrome.ink.opacity(0.45))
    }
}
