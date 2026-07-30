import SwiftUI

/// Root screen: board, rack, action bar, floating drag layer.
/// Everything shares one named coordinate space so geometry can never drift
/// between the gesture math and the visuals.
struct GameView: View {
    static let spaceName = "game"

    /// Owned by RootView (which persists it); this view only presents it.
    let state: BoardState
    var onExit: (() -> Void)? = nil
    var onNewGame: (() -> Void)? = nil
    /// Realtime says the server row changed — owner re-pulls game state.
    var onServerPoke: (() -> Void)? = nil

    @State private var drag = DragController()
    @State private var showSwapSheet = false
    @State private var confirmingResign = false
    @State private var confirmingPass = false
    @State private var pingFeedback: String?
    @State private var chat: ChatStore?
    @State private var channel: GameChannel?
    @State private var showChat = false
    @State private var takeoverEmoji: String?
    // Phase 12: result overlay dismissal (browse the finished board),
    // review, hints, tap-to-define.
    @State private var resultDismissed = false
    @State private var showReview = false
    @State private var reviewEngine: ReviewEngine?
    @State private var showHintMenu = false
    @State private var hintWorking = false
    @State private var hintNotice: String?
    @State private var definitionRequest: DefinitionRequest?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme

    var body: some View {
        // Diagnostic: GameView body evaluations around the chat-open window.
        let _ = chatLog.notice("GameView BODY showChat=\(showChat) chatNil=\(chat == nil)")
        // Same probe for the review sheet (reproducible sibling of the
        // chat blank-sheet bug): did the PRESENTING view re-evaluate when
        // showReview flipped?
        let _ = reviewLog.notice("GameView BODY showReview=\(showReview) engineNil=\(reviewEngine == nil)")
        return GeometryReader { geo in
            let metrics = BoardMetrics.fitting(width: min(geo.size.width - 8, 440))
            // Rack must never exceed screen width: an over-wide child makes the
            // VStack overflow leading-aligned, shifting the whole layout off-center.
            // 90 = outer padding (24) + rack inner padding (24) + 6 gaps × 7.
            let rackTile = min(46, (geo.size.width - 90) / 7)
            // THE placement verdict — computed once per body evaluation and
            // shared by the board (green word outline + score badge) and the
            // Play button. One validation path; nothing below re-checks.
            let verdict = state.evaluatePlacement()

            VStack(spacing: 14) {
                GameHeaderView(local: state.localPlayer,
                               opponent: state.opponent,
                               turnState: state.turnState,
                               bagCount: state.bagRemaining,
                               passes: state.consecutivePasses,
                               logLine: state.moveLog.last,
                               rejection: rejectionText,
                               expiresAt: state.gameOver == nil ? state.expiresAt : nil,
                               onResign: state.opponentIsHuman && state.gameOver == nil
                                   ? { confirmingResign = true } : nil,
                               onPing: state.opponentIsHuman && state.waitingForOpponent
                                   ? { sendPing() } : nil,
                               onChat: state.opponentIsHuman && state.gameOver == nil
                                   ? { chatLog.notice("chat button TAPPED (chat nil=\(chat == nil))")
                                       showChat = true } : nil,
                               chatBadge: state.unreadChat,
                               onBack: { onExit?() })

                Spacer(minLength: 0)

                BoardView(state: state, drag: drag, metrics: metrics,
                          verdict: verdict,
                          onTapCommitted: { coord in
                              let words = state.committedWords(through: coord)
                              guard !words.isEmpty else { return }
                              definitionRequest = DefinitionRequest(words: words)
                          })
                    .frame(width: metrics.side, height: metrics.side)
                    .clipShape(RoundedRectangle(cornerRadius: theme.metrics.boardCornerRadius, style: .continuous))
                    .contentShape(Rectangle())
                    // Pan the zoomed board by dragging empty squares.
                    // Tile drags are child gestures, so they win on tiles.
                    .gesture(boardPanGesture)
                    // Pinch toggles between the two zoom states.
                    .simultaneousGesture(pinchGesture(metrics: metrics))
                    .background(frameReporter { drag.boardFrame = $0; drag.metrics = metrics })

                RackView(state: state, drag: drag, tileSize: rackTile)
                    .background(frameReporter { drag.rackFrame = $0 })
                    .padding(.horizontal, 12)

                if state.gameOver == nil {
                    actionBar(verdict: verdict)
                } else {
                    finishedBar
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.chrome.screenBackground.ignoresSafeArea())
            .overlay(alignment: .topLeading) { floatingTile }
            // The takeover plays ABOVE everything as a hit-test-disabled
            // overlay: a live drag underneath continues undisturbed
            // (invariant 2 — nothing is torn down or moved).
            .overlay {
                if let takeoverEmoji {
                    EmojiTakeoverView(emoji: takeoverEmoji) {
                        self.takeoverEmoji = nil
                    }
                    .zIndex(30)
                }
            }
            // Game over is an overlay, not a view swap: the board hierarchy
            // must never be torn down while a gesture could be live.
            // Its appearance IS the result acknowledgment (Phase 12) —
            // seeing this screen is what moves the game to Past games.
            // "Review game" dismisses it into the interactive finished
            // board (tap words for definitions, open the analysis,
            // return via the Result button).
            .overlay {
                if let summary = state.gameOver, !resultDismissed {
                    GameOverView(summary: summary,
                                 localName: state.localPlayer.profile.displayName,
                                 opponentName: state.opponent.profile.displayName,
                                 newGameLabel: state.opponentIsHuman ? "Rematch" : "New Game",
                                 onHome: { onExit?() },
                                 onNewGame: { onNewGame?() },
                                 onReview: {
                                     withAnimation(.easeOut(duration: 0.25)) {
                                         resultDismissed = true
                                     }
                                 })
                    // Invariant 5: presentation-lifecycle mutation goes
                    // through .task + yield, not onAppear.
                    .task {
                        await Task.yield()
                        acknowledgeResult()
                    }
                }
            }
            .alert("Nudge", isPresented: .init(get: { pingFeedback != nil },
                                               set: { if !$0 { pingFeedback = nil } })) {
                Button("OK") { pingFeedback = nil }
            } message: {
                Text(pingFeedback ?? "")
            }
            .confirmationDialog("Resign this game?",
                                isPresented: $confirmingResign,
                                titleVisibility: .visible) {
                Button("Resign — \(state.opponent.profile.displayName) wins", role: .destructive) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        state.resignLocalPlayer()
                    }
                }
                Button("Keep playing", role: .cancel) {}
            } message: {
                Text("The game ends immediately and counts as a loss.")
            }
        }
        .coordinateSpace(name: Self.spaceName)
        .task(id: state.gameID) {
            // Definitions load lazily off-main so the first define tap
            // never stalls; harmless if already loaded.
            Definitions.warmUp()
            await setUpChat()
        }
        .onDisappear {
            channel?.disconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            guard state.opponentIsHuman else { return }
            if phase == .active {
                channel?.connect()
            } else if phase == .background {
                channel?.disconnect()
            }
        }
        .sheet(isPresented: $showChat) {
            // Diagnostic: every evaluation of the sheet CONTENT closure —
            // did presentation evaluate it at all, and which branch?
            let storeDesc = chat.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
            let loadedDesc = chat.map { String($0.loaded) } ?? "-"
            let _ = chatLog.notice("sheet CLOSURE eval chatNil=\(chat == nil) store=\(storeDesc, privacy: .public) loaded=\(loadedDesc, privacy: .public)")
            if let chat {
                ChatSheet(chat: chat, board: state) {
                    // Blocked: the game was resigned server-side; leave it.
                    onExit?()
                }
                .presentationDetents([.large])
                .presentationBackground(theme.chrome.screenBackground)
            } else {
                // chat is created at game open, so this is theoretical —
                // but a sheet must never render as pure emptiness.
                ProgressView()
                    .tint(theme.chrome.ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.large])
                    .presentationBackground(theme.chrome.screenBackground)
                    .onAppear { chatLog.notice("sheet NIL-BRANCH visible (fallback spinner)") }
            }
        }
        .sheet(isPresented: blankSheetShown) {
            BlankPickerView { letter in
                if let coord = state.pendingBlank {
                    state.assignBlank(at: coord, letter: letter)
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $definitionRequest) { request in
            DefinitionSheet(request: request)
        }
        .sheet(isPresented: $showReview) {
            // Diagnostic: every evaluation of the sheet CONTENT closure —
            // did presentation evaluate it at all, and which branch?
            let engineDesc = reviewEngine.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
            let _ = reviewLog.notice("review sheet CLOSURE eval engineNil=\(reviewEngine == nil) engine=\(engineDesc, privacy: .public)")
            if let reviewEngine {
                ReviewView(engine: reviewEngine,
                           opponentName: state.opponent.profile.displayName)
            } else {
                // openReview creates the engine before presenting, so this
                // is theoretical — but a sheet must never render as pure
                // emptiness, and hitting this branch would itself be the
                // diagnosis.
                ProgressView()
                    .tint(theme.chrome.ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.large])
                    .presentationBackground(theme.chrome.screenBackground)
                    .onAppear { reviewLog.notice("review sheet NIL-BRANCH visible (fallback spinner)") }
            }
        }
        .alert("Hints", isPresented: .init(get: { hintNotice != nil },
                                           set: { if !$0 { hintNotice = nil } })) {
            Button("OK") { hintNotice = nil }
        } message: {
            Text(hintNotice ?? "")
        }
        .confirmationDialog("Need a nudge?", isPresented: $showHintMenu,
                            titleVisibility: .visible) {
            if state.hintPlacementsLeft > 0 {
                Button("Show playable spots (\(state.hintPlacementsLeft) left)") {
                    requestPlacementsHint()
                }
            }
            if state.hintBestWordsLeft > 0 {
                Button("Stage the best word (\(state.hintBestWordsLeft) left)") {
                    requestBestWordHint()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You get \(HintBudget.placements) of each per game — free, no strings.")
        }
    }

    // MARK: - Phase 12: result acknowledgment, review, hints

    /// The game-over screen is on screen: mark the result seen (locally
    /// at once; server-side so the archive follows the account).
    private func acknowledgeResult() {
        guard state.markResultSeen() else { return }
        guard state.isRemote else { return }
        let gameID = state.gameID
        Task { try? await RemoteGames.markResultSeen(gameID: gameID) }
    }

    private func openReview() {
        reviewLog.notice("review button TAPPED engineNil=\(reviewEngine == nil) showReview=\(showReview)")
        if reviewEngine == nil {
            reviewEngine = ReviewEngine(gameID: state.gameID)
        }
        showReview = true
    }

    /// Hint type 1 — outline the top playable spots. Generation runs off
    /// the main thread (it may pay the one-time trie build on a
    /// human-game board); the hint button shows a spinner meanwhile.
    private func requestPlacementsHint() {
        guard !hintWorking, state.hintPlacementsLeft > 0 else { return }
        hintWorking = true
        state.recallAll()   // hint from the FULL rack
        let board = state.committed
        let rack = state.rack
        Task {
            let moves = await Task.detached(priority: .userInitiated) {
                AIPlayer.topMoves(board: board, rack: rack,
                                  limit: HintBudget.placementSpots)
            }.value
            hintWorking = false
            if moves.isEmpty {
                hintNotice = "No plays are possible with this rack — swap or pass."
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    state.applyPlacementsHint(moves)
                }
            }
        }
    }

    /// Hint type 2 — stage the best word without committing it.
    private func requestBestWordHint() {
        guard !hintWorking, state.hintBestWordsLeft > 0 else { return }
        hintWorking = true
        state.recallAll()
        let board = state.committed
        let rack = state.rack
        Task {
            let best = await Task.detached(priority: .userInitiated) {
                AIPlayer.bestMove(board: board, rack: rack)
            }.value
            hintWorking = false
            if let best {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.applyBestWordHint(best)
                }
                drag.refreshZoom(state: state)
            } else {
                hintNotice = "No plays are possible with this rack — swap or pass."
            }
        }
    }

    // MARK: - Pieces

    private var rejectionText: String? {
        if case .rejected(let reason) = state.status { return reason }
        return nil
    }

    private func actionBar(verdict: BoardState.PlacementVerdict) -> some View {
        let playEnabled = canPlay(verdict)
        return HStack(spacing: 6) {
            ActionButton(icon: "shuffle", label: "Shuffle") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.shuffleRack()
                }
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    state.playMove()
                }
                drag.refreshZoom(state: state)
            } label: {
                Text(playLabel(verdict))
                    .font(theme.typography.buttonLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(playEnabled ? theme.chrome.buttonPrimaryText
                                                 : theme.chrome.ink.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        Capsule().fill(playEnabled ? theme.chrome.buttonPrimary
                                                   : theme.chrome.ink.opacity(0.12))
                    )
            }
            .disabled(!playEnabled)

            ActionButton(icon: "arrow.uturn.backward", label: "Recall") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.recallAll()
                }
                drag.refreshZoom(state: state)
            }

            hintButton

            ActionButton(icon: "arrow.2.squarepath", label: "Swap") {
                showSwapSheet = true
            }
            .disabled(state.waitingForOpponent || state.gameOver != nil || state.bagRemaining == 0)
            .opacity(state.bagRemaining == 0 ? 0.4 : 1)

            ActionButton(icon: "forward.end", label: "Pass") {
                confirmingPass = true
            }
            .disabled(state.waitingForOpponent || state.gameOver != nil)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        // A pass is too easy to hit by accident for a single tap — confirm
        // first, same pattern as Resign.
        .confirmationDialog("Pass your turn?",
                            isPresented: $confirmingPass,
                            titleVisibility: .visible) {
            Button("Pass") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.passTurn()
                }
                drag.refreshZoom(state: state)
            }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("You'll give up this turn without playing. Six passes in a row end the game.")
        }
        .sheet(isPresented: $showSwapSheet) {
            SwapView(rack: state.rack, bagCount: state.bagRemaining) { ids in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.swapTiles(ids: ids)
                }
            }
        }
    }

    /// The hint entry point: a lightbulb that opens the two-hint menu,
    /// with a spinner while the generator is thinking. Dimmed once both
    /// budgets are spent.
    private var hintButton: some View {
        ZStack {
            ActionButton(icon: "lightbulb", label: "Hint") {
                showHintMenu = true
            }
            .opacity(hintWorking ? 0 : 1)
            if hintWorking {
                ProgressView()
                    .tint(theme.chrome.accent)
            }
        }
        .disabled(state.waitingForOpponent || state.gameOver != nil
                  || hintWorking
                  || (state.hintPlacementsLeft == 0 && state.hintBestWordsLeft == 0))
        .opacity(state.hintPlacementsLeft == 0 && state.hintBestWordsLeft == 0 ? 0.4 : 1)
    }

    /// Replaces the action bar once the game is over: back to the result
    /// overlay, into the analysis, or straight to a rematch. The board
    /// above stays fully alive for browsing and tap-to-define.
    private var finishedBar: some View {
        HStack(spacing: 8) {
            ActionButton(icon: "flag.checkered", label: "Result") {
                withAnimation(.easeOut(duration: 0.25)) {
                    resultDismissed = false
                }
            }
            if state.isRemote {
                ActionButton(icon: "magnifyingglass", label: "Review") {
                    openReview()
                }
            }
            Button {
                onNewGame?()
            } label: {
                Text(state.opponentIsHuman ? "REMATCH" : "NEW GAME")
                    .font(theme.typography.buttonLabel)
                    .foregroundStyle(theme.chrome.buttonPrimaryText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(theme.chrome.buttonPrimary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Chat & realtime

    private func setUpChat() async {
        guard state.opponentIsHuman, chat == nil else { return }
        let store = ChatStore(gameID: state.gameID,
                              myUserID: state.localPlayer.profile.id)
        chat = store

        // ORDER MATTERS (learned from a hang): the chat fetch completes
        // BEFORE the realtime channel is touched. The channel's subscribe
        // shares client machinery with REST calls; connecting first wedged
        // the fetch behind a cold-launch socket connect until a scenePhase
        // change tore the channel down. A hung channel now costs realtime
        // only (the poll fallback still runs) — never the chat itself.
        chatLog.notice("setup: loading chat before channel connect")
        let unseen = await store.load()
        state.unreadChat = store.unreadCount
        if let latest = unseen.last {
            playTakeover(latest, store: store)
        }
        // Finished games have no reachable chat: clear unread on open so a
        // pre-finish message can't leave a badge stuck forever.
        if state.gameOver != nil {
            store.markAllRead(board: state)
        }

        let gameChannel = GameChannel(gameID: state.gameID)
        gameChannel.onChatMessage = { message in
            handleIncoming(message, store: store)
        }
        gameChannel.onGameChanged = { onServerPoke?() }
        gameChannel.onReconnect = {
            // The dead channel may have missed anything: re-pull both.
            onServerPoke?()
            Task {
                let unseen = await store.load()
                if let latest = unseen.last, showChat == false {
                    playTakeover(latest, store: store)
                }
            }
        }
        channel = gameChannel
        gameChannel.connect()
    }

    private func handleIncoming(_ message: RemoteGames.ChatMessage, store: ChatStore) {
        guard store.receive(message) else { return }
        guard message.sender != state.localPlayer.profile.id else { return }
        if showChat {
            // Visible thread: ChatSheet's onChange marks it read.
            return
        }
        if message.isEmoji {
            // Live delight: play it the moment it lands.
            playTakeover(message, store: store)
        }
        state.unreadChat = store.unreadCount
    }

    private func playTakeover(_ message: RemoteGames.ChatMessage, store: ChatStore) {
        store.recordTakeoverShown(message.id)
        withAnimation(.easeIn(duration: 0.1)) {
            takeoverEmoji = message.body
        }
    }

    /// Rate-limited server-side: one nudge per game per 6 hours.
    private func sendPing() {
        let name = state.opponent.profile.displayName
        Task {
            do {
                let result = try await RemoteGames.ping(gameID: state.gameID)
                switch result.status {
                case "sent":
                    pingFeedback = "\(name) will get a nudge that you're waiting."
                case "cooldown":
                    let minutes = result.retryAfterMinutes ?? 0
                    pingFeedback = "Already nudged — you can nudge again in about \(max(1, minutes / 60))h."
                default:
                    pingFeedback = "It's not \(name)'s turn right now."
                }
            } catch {
                pingFeedback = "Couldn't send the nudge — check your connection."
            }
        }
    }

    /// The Play button is genuinely disabled until the placement is a fully
    /// legal move (line, contiguity, center/connection, dictionary) — the
    /// SAME evaluatePlacement() verdict computed once in body and shared
    /// with the board's green outline/badge, so the button and the rules
    /// can never disagree. The rejection-message path in playMove() stays
    /// as a fallback but is unreachable in normal use.
    private func canPlay(_ verdict: BoardState.PlacementVerdict) -> Bool {
        guard case .playable = verdict else { return false }
        return !state.waitingForOpponent
    }

    private func playLabel(_ verdict: BoardState.PlacementVerdict) -> String {
        if case .playable(_, _, let score) = verdict {
            return "PLAY  +\(score)"
        }
        return "PLAY"
    }

    @ViewBuilder
    private var floatingTile: some View {
        if let active = drag.active, let center = drag.visualCenter {
            TileView(tile: active.tile,
                     size: drag.floatingSize,
                     isFreshlyPlaced: true)
                // Translucent so the target square reads through the tile,
                // which sits directly under the finger (Scrabble GO-style).
                .opacity(active.isSettling ? 0.9 : 0.72)
                .scaleEffect(active.isSettling ? 0.85 : 1.0)
                .shadow(color: theme.tile.shadowColor, radius: 8, y: 5)
                .position(center)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: drag.floatingSize)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .zIndex(10)
        }
    }

    private var blankSheetShown: Binding<Bool> {
        Binding(
            get: { state.pendingBlank != nil && drag.active == nil },
            set: { shown in if !shown { /* dismissal blocked; pick a letter */ } }
        )
    }

    // MARK: - Board pan & pinch

    /// One-finger pan of the zoomed board. Only fires when the drag starts
    /// on an empty square (tile gestures are children and take priority),
    /// and the controller ignores it entirely at 1x zoom.
    private var boardPanGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.spaceName))
            .onChanged { value in
                drag.panChanged(translation: value.translation, state: state)
            }
            .onEnded { value in
                drag.panEnded(velocity: value.velocity)
            }
    }

    /// Pinch snaps between the two zoom states: out at 1x → zoom in
    /// centered on the pinch; in while zoomed → back to the full board.
    private func pinchGesture(metrics: BoardMetrics) -> some Gesture {
        MagnifyGesture()
            .onEnded { value in
                if !drag.isZoomedIn, value.magnification > 1.15 {
                    let p = CGPoint(x: value.startAnchor.x * metrics.side,
                                    y: value.startAnchor.y * metrics.side)
                    drag.zoomIn(centering: p)
                } else if drag.isZoomedIn, value.magnification < 0.87 {
                    drag.zoomOut()
                }
            }
    }

    /// Captures a view's frame in the shared game coordinate space.
    private func frameReporter(_ update: @escaping (CGRect) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.frame(in: .named(Self.spaceName))) }
                .onChange(of: proxy.frame(in: .named(Self.spaceName))) { _, frame in
                    update(frame)
                }
        }
    }
}

private struct ActionButton: View {
    @Environment(\.theme) private var theme

    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.chrome.ink.opacity(0.8))
            .frame(width: 52, height: 50)
            .background(
                RoundedRectangle(cornerRadius: theme.metrics.cardCornerRadius, style: .continuous)
                    .fill(theme.chrome.ink.opacity(0.08))
            )
        }
    }
}

#Preview {
    GameView(state: BoardState())
}
