import SwiftUI
import Observation
import Supabase
import os

/// Console-visible breadcrumbs for the chat/realtime path (subsystem
/// com.kittyrobotics.Words.Words, category "chat").
let chatLog = Logger(subsystem: "com.kittyrobotics.Words.Words", category: "chat")

// MARK: - Realtime channel (one per open game)

/// Realtime for the open game: chat inserts and game-row updates stream in
/// sub-second; the Phase 9 poll stays underneath as the fallback, so a
/// dropped channel degrades to slow, never to stalled. All callbacks fire
/// on the main actor (invariant 5).
@MainActor
final class GameChannel {
    private let gameID: UUID
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []
    private var everConnected = false

    var onChatMessage: ((RemoteGames.ChatMessage) -> Void)?
    var onGameChanged: (() -> Void)?
    /// Fired on RE-connection (foreground after background): the caller
    /// re-syncs whatever the dead channel missed.
    var onReconnect: (() -> Void)?

    init(gameID: UUID) {
        self.gameID = gameID
    }

    func connect() {
        guard channel == nil else { return }
        chatLog.notice("channel connect() game=\(self.gameID.uuidString, privacy: .public)")
        let ch = SupabaseService.client.channel("game-\(gameID.uuidString)")
        let inserts = ch.postgresChange(InsertAction.self, schema: "public",
                                        table: "chat_messages",
                                        filter: "game_id=eq.\(gameID.uuidString)")
        let updates = ch.postgresChange(UpdateAction.self, schema: "public",
                                        table: "games",
                                        filter: "id=eq.\(gameID.uuidString)")
        channel = ch

        tasks.append(Task { [weak self] in
            chatLog.notice("channel insert-stream consuming")
            for await action in inserts {
                chatLog.notice("channel insert received")
                self?.handleChatRecord(action.record)
            }
            chatLog.notice("channel insert-stream ended")
        })
        tasks.append(Task { [weak self] in
            for await _ in updates {
                chatLog.notice("channel game-update received")
                self?.onGameChanged?()
            }
        })
        tasks.append(Task { [weak self] in
            chatLog.notice("channel subscribe starting")
            await ch.subscribe()
            chatLog.notice("channel subscribe RETURNED")
            guard let self else { return }
            if self.everConnected {
                chatLog.notice("channel reconnected — resync")
                self.onReconnect?()
            } else {
                self.everConnected = true
            }
        })
    }

    func disconnect() {
        chatLog.notice("channel disconnect() game=\(self.gameID.uuidString, privacy: .public)")
        tasks.forEach { $0.cancel() }
        tasks = []
        if let channel {
            let doomed = channel
            Task { await SupabaseService.client.removeChannel(doomed) }
        }
        channel = nil
    }

    private func handleChatRecord(_ record: [String: AnyJSON]) {
        guard let id = record["id"]?.intValue,
              let senderString = record["sender"]?.stringValue,
              let sender = UUID(uuidString: senderString),
              let body = record["body"]?.stringValue else { return }
        onChatMessage?(RemoteGames.ChatMessage(
            id: Int64(id),
            sender: sender,
            kind: record["kind"]?.stringValue ?? "text",
            body: body,
            createdAt: record["created_at"]?.stringValue))
    }
}

// MARK: - Chat state

/// Per-game chat: messages, read markers, and the fire-once bookkeeping
/// for takeover animations. Two markers on purpose:
///  • the SERVER read marker drives unread badges and moves when the chat
///    sheet is actually read;
///  • a LOCAL takeover marker records which emoji have already animated,
///    so a takeover fires exactly once even though seeing it doesn't
///    necessarily mean the text backlog was read.
@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [RemoteGames.ChatMessage] = []
    private(set) var serverLastRead: Int64 = 0
    private(set) var loaded = false
    private(set) var loadFailed = false

    let gameID: UUID
    let myUserID: UUID

    private var takeoverMarkKey: String { "takeoverMark-\(gameID.uuidString)" }
    private var takeoverMark: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: takeoverMarkKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: takeoverMarkKey) }
    }

    init(gameID: UUID, myUserID: UUID) {
        self.gameID = gameID
        self.myUserID = myUserID
        chatLog.notice("ChatStore INIT \(String(describing: ObjectIdentifier(self)), privacy: .public) game=\(gameID.uuidString.prefix(8), privacy: .public)")
    }

    var unreadCount: Int {
        messages.filter { $0.sender != myUserID && $0.id > serverLastRead }.count
    }

    /// Load the thread; returns the emoji that should take over the screen
    /// now (opponent emoji never animated before), oldest first.
    func load() async -> [RemoteGames.ChatMessage] {
        loadFailed = false
        chatLog.notice("load: fetch issuing game=\(self.gameID.uuidString, privacy: .public)")
        let fetched = try? await RemoteGames.fetchChat(gameID: gameID)
        chatLog.notice("load: fetch+decode returned ok=\(fetched != nil) count=\(fetched?.messages.count ?? -1)")
        guard let state = fetched else {
            loadFailed = !loaded  // cached content beats an error banner
            return []
        }
        messages = state.messages
        serverLastRead = state.myLastRead
        loaded = true
        chatLog.notice("load: state set loaded=true lastRead=\(state.myLastRead)")
        // A reinstall can't replay history: anything at or below the
        // SERVER read marker never becomes a candidate, wherever the
        // device-local takeover marker stands.
        return Self.takeoverCandidates(messages: messages, myID: myUserID,
                                       serverRead: state.myLastRead,
                                       localMark: takeoverMark)
    }

    nonisolated static func takeoverCandidates(
        messages: [RemoteGames.ChatMessage], myID: UUID,
        serverRead: Int64, localMark: Int64
    ) -> [RemoteGames.ChatMessage] {
        let threshold = max(serverRead, localMark)
        return messages.filter {
            $0.isEmoji && $0.sender != myID && $0.id > threshold
        }
    }

    func recordTakeoverShown(_ messageID: Int64) {
        takeoverMark = max(takeoverMark, messageID)
    }

    /// A realtime arrival. Returns true if it's new (deduped by id — our
    /// own sends echo back through the channel).
    func receive(_ message: RemoteGames.ChatMessage) -> Bool {
        guard !messages.contains(where: { $0.id == message.id }) else { return false }
        messages.append(message)
        messages.sort { $0.id < $1.id }
        return true
    }

    /// Message shown when a send is refused (chat closed, blocked, offline).
    private(set) var sendError: String?

    func send(body: String, kind: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendError = nil
        do {
            let id = try await RemoteGames.sendChat(gameID: gameID, body: trimmed, kind: kind)
            _ = receive(RemoteGames.ChatMessage(id: id, sender: myUserID, kind: kind,
                                                body: trimmed, createdAt: nil))
        } catch let error as PostgrestError where error.message.contains("chat_closed") {
            // Reachable only in the race where the game ends while the
            // sheet is open (e.g. the opponent resigns as you type).
            sendError = "This game has ended — chat is closed. Rematch to keep talking!"
        } catch let error as PostgrestError where error.message.contains("blocked") {
            sendError = "You can't message this player."
        } catch {
            sendError = "Couldn't send — check your connection."
        }
    }

    /// Everything currently in the thread counts as read.
    func markAllRead(board: BoardState?) {
        guard let latest = messages.last?.id, latest > serverLastRead else {
            board?.unreadChat = 0
            return
        }
        serverLastRead = latest
        takeoverMark = max(takeoverMark, latest)
        board?.unreadChat = 0
        let gameID = gameID
        Task { try? await RemoteGames.markChatRead(gameID: gameID, messageID: latest) }
    }
}

// MARK: - Chat sheet

/// iMessage-style thread + the emoji quick panel. Emoji are one tap from
/// here (chat button → emoji): they send immediately, no compose step.
struct ChatSheet: View {
    let chat: ChatStore
    let board: BoardState
    let onBlocked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showReportDialog = false
    @State private var confirmingBlock = false

    static let quickEmoji = ["🎉", "😂", "😮", "😭", "🔥", "👏", "❤️", "🤬"]

    private var opponent: PlayerProfile { board.opponent.profile }

    var body: some View {
        // Diagnostic: every body evaluation, with the store's identity —
        // discriminates "stale snapshot, no evaluation" from "evaluated
        // against a different store instance".
        let _ = chatLog.notice("ChatSheet BODY store=\(String(describing: ObjectIdentifier(chat)), privacy: .public) loaded=\(chat.loaded) failed=\(chat.loadFailed) count=\(chat.messages.count)")
        VStack(spacing: 0) {
            header
            messagesList
            emojiStrip
            inputBar
        }
        .background(HomeView.background.ignoresSafeArea())
        .onAppear {
            chatLog.notice("ChatSheet onAppear (UIKit appearance)")
        }
        // INVARIANT 6: never mutate parent-observed state synchronously
        // from presentation-lifecycle callbacks (onAppear/onChange fire
        // inside the presentation transaction; invalidating the parent
        // there dropped this sheet's first frame — blank until a system
        // commit). .task runs after the commit; the yield makes sure.
        .task(id: chat.messages.count) {
            chatLog.notice("sheet presented/updated loaded=\(chat.loaded) failed=\(chat.loadFailed) count=\(chat.messages.count)")
            await Task.yield()
            chat.markAllRead(board: board)
        }
        .confirmationDialog("Report \(opponent.displayName)?",
                            isPresented: $showReportDialog, titleVisibility: .visible) {
            Button("Offensive messages") { report("Offensive messages") }
            Button("Spam") { report("Spam") }
            Button("Something else") { report("Other (reported from chat)") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The report goes to the developers for review.")
        }
        .confirmationDialog("Block \(opponent.displayName)?",
                            isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block — ends this game", role: .destructive) { block() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocking removes them as a friend, resigns this game, and stops all messages and challenges both ways.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarCircle(avatar: opponent.avatar, size: 30)
            Text(opponent.displayName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Menu {
                Button("Report \(opponent.displayName)…") { showReportDialog = true }
                Button("Block \(opponent.displayName)…", role: .destructive) {
                    confirmingBlock = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
            }
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    // Cached messages render immediately; the spinner shows
                    // only while a first fetch is genuinely in flight, and
                    // failure gets a retry — never a blank view.
                    if !chat.loaded && !chat.loadFailed && chat.messages.isEmpty {
                        ProgressView()
                            .tint(.white.opacity(0.5))
                            .padding(.top, 30)
                    } else if chat.loadFailed && chat.messages.isEmpty {
                        VStack(spacing: 10) {
                            Text("Couldn't load messages.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                            Button("Try again") {
                                Task { _ = await chat.load() }
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .padding(.top, 30)
                    } else if chat.messages.isEmpty {
                        Text("Say something — \(opponent.displayName) will get a notification.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.top, 30)
                    }
                    ForEach(chat.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: RemoteGames.ChatMessage) -> some View {
        let mine = message.sender == chat.myUserID
        HStack {
            if mine { Spacer(minLength: 60) }
            if message.isEmoji {
                Text(message.body)
                    .font(.system(size: 44))
                    .padding(.vertical, 2)
            } else {
                Text(message.body)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(mine ? .black : .white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(mine ? Color.yellow : Color.white.opacity(0.12))
                    )
            }
            if !mine { Spacer(minLength: 60) }
        }
    }

    private var emojiStrip: some View {
        HStack(spacing: 0) {
            ForEach(Self.quickEmoji, id: \.self) { emoji in
                Button {
                    Task { await chat.send(body: emoji, kind: "emoji") }
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
        if let sendError = chat.sendError {
            Text(sendError)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
        }
        HStack(spacing: 8) {
            TextField("Message…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            Button {
                let text = draft
                draft = ""
                Task { await chat.send(body: text, kind: "text") }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.white.opacity(0.2) : Color.yellow)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func report(_ reason: String) {
        let opponentID = opponent.id
        let gameID = chat.gameID
        Task { try? await RemoteGames.reportUser(opponentID, reason: reason, gameID: gameID) }
    }

    private func block() {
        let opponentID = opponent.id
        Task {
            try? await RemoteGames.blockUser(opponentID)
            dismiss()
            onBlocked()
        }
    }
}
