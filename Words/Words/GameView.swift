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
    @State private var pingFeedback: String?
    @State private var chat: ChatStore?
    @State private var channel: GameChannel?
    @State private var showChat = false
    @State private var takeoverEmoji: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Diagnostic: GameView body evaluations around the chat-open window.
        let _ = chatLog.notice("GameView BODY showChat=\(showChat) chatNil=\(chat == nil)")
        return GeometryReader { geo in
            let metrics = BoardMetrics.fitting(width: min(geo.size.width - 8, 440))
            // Rack must never exceed screen width: an over-wide child makes the
            // VStack overflow leading-aligned, shifting the whole layout off-center.
            // 90 = outer padding (24) + rack inner padding (24) + 6 gaps × 7.
            let rackTile = min(46, (geo.size.width - 90) / 7)

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

                BoardView(state: state, drag: drag, metrics: metrics)
                    .frame(width: metrics.side, height: metrics.side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

                actionBar
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.05, green: 0.07, blue: 0.13).ignoresSafeArea())
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
            .overlay {
                if let summary = state.gameOver {
                    GameOverView(summary: summary,
                                 localName: state.localPlayer.profile.displayName,
                                 opponentName: state.opponent.profile.displayName,
                                 newGameLabel: state.opponentIsHuman ? "Rematch" : "New Game",
                                 onHome: { onExit?() },
                                 onNewGame: { onNewGame?() })
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
                .presentationBackground(HomeView.background)
            } else {
                // chat is created at game open, so this is theoretical —
                // but a sheet must never render as pure emptiness.
                ProgressView()
                    .tint(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .presentationDetents([.large])
                    .presentationBackground(HomeView.background)
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
    }

    // MARK: - Pieces

    private var rejectionText: String? {
        if case .rejected(let reason) = state.status { return reason }
        return nil
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
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
                Text(playLabel)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(canPlay ? .black : .white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        Capsule().fill(canPlay ? Color.yellow : Color.white.opacity(0.12))
                    )
            }
            .disabled(!canPlay)

            ActionButton(icon: "arrow.uturn.backward", label: "Recall") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.recallAll()
                }
                drag.refreshZoom(state: state)
            }

            ActionButton(icon: "arrow.2.squarepath", label: "Swap") {
                showSwapSheet = true
            }
            .disabled(state.waitingForOpponent || state.gameOver != nil || state.bagRemaining == 0)
            .opacity(state.bagRemaining == 0 ? 0.4 : 1)

            ActionButton(icon: "forward.end", label: "Pass") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.passTurn()
                }
                drag.refreshZoom(state: state)
            }
            .disabled(state.waitingForOpponent || state.gameOver != nil)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .sheet(isPresented: $showSwapSheet) {
            SwapView(rack: state.rack, bagCount: state.bagRemaining) { ids in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    state.swapTiles(ids: ids)
                }
            }
        }
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

    private var canPlay: Bool {
        state.currentScore() != nil && state.pendingBlank == nil && !state.waitingForOpponent
    }

    private var playLabel: String {
        if let score = state.currentScore() { return "PLAY  +\(score)" }
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
                .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
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
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 52, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}

#Preview {
    GameView(state: BoardState())
}
