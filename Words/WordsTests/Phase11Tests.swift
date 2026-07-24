//
//  Phase11Tests.swift
//  WordsTests
//
//  Chat + takeover logic that's testable without a server: fire-once
//  candidate selection, style mapping, message decoding, dedupe.
//

import Foundation
import Testing
@testable import Words

struct Phase11Tests {

    private let me = UUID()
    private let them = UUID()

    private func message(_ id: Int64, from sender: UUID, kind: String = "text",
                         body: String = "hi") -> RemoteGames.ChatMessage {
        RemoteGames.ChatMessage(id: id, sender: sender, kind: kind,
                                body: body, createdAt: nil)
    }

    /// Takeover fires once: only opponent emoji newer than BOTH markers.
    @Test func takeoverCandidatesRespectBothMarkers() {
        let messages = [
            message(1, from: them, kind: "emoji", body: "🎉"),  // server-read
            message(2, from: them, body: "nice"),               // text: never a candidate
            message(3, from: me, kind: "emoji", body: "🔥"),    // mine: never
            message(4, from: them, kind: "emoji", body: "😂"),  // locally shown already
            message(5, from: them, kind: "emoji", body: "😭"),  // genuinely new
        ]
        let candidates = ChatStore.takeoverCandidates(
            messages: messages, myID: me, serverRead: 1, localMark: 4)
        #expect(candidates.map(\.id) == [5])

        // A reinstall (localMark reset to 0) can't replay server-read history.
        let reinstall = ChatStore.takeoverCandidates(
            messages: messages, myID: me, serverRead: 4, localMark: 0)
        #expect(reinstall.map(\.id) == [5])
    }

    /// Every quick-panel emoji maps to a style, and the marquee ones are
    /// distinct from each other.
    @Test func quickPanelStylesAreDistinct() {
        let styles = ChatSheet.quickEmoji.map { TakeoverStyle.style(for: $0) }
        #expect(styles.count == 8)
        // 🎉 😂 🔥 👏 ❤️ 🤬 each get their own physicality.
        #expect(TakeoverStyle.style(for: "🎉") == .confetti)
        #expect(TakeoverStyle.style(for: "😂") == .tumble)
        #expect(TakeoverStyle.style(for: "🔥") == .flames)
        #expect(TakeoverStyle.style(for: "👏") == .clapWave)
        #expect(TakeoverStyle.style(for: "❤️") == .heartbeat)
        #expect(TakeoverStyle.style(for: "🤬") == .slamShake)
        // Unknown emoji still animate (fallback), never crash.
        #expect(TakeoverStyle.style(for: "🦄") == .zoomQuiver)
    }

    /// Particle systems are deterministic and bounded.
    @Test func particleSystemsAreDeterministicAndFinite() {
        for emoji in ChatSheet.quickEmoji {
            let style = TakeoverStyle.style(for: emoji)
            let a = style.makeParticles(emoji: emoji)
            let b = style.makeParticles(emoji: emoji)
            #expect(a.count == b.count)
            #expect(a.count <= 100, "particle count stays sane for \(emoji)")
            // Past the style's duration every particle has expired.
            for particle in a {
                let state = style.particleState(particle, t: style.duration + 3,
                                                size: CGSize(width: 400, height: 800))
                #expect(state == nil || state!.opacity == 0)
            }
        }
    }

    /// Server chat payload decodes, including bigint ids.
    @Test func chatStateDecodes() throws {
        let json = """
        {"my_last_read": 7,
         "messages": [
           {"id": 8, "sender": "\(them.uuidString)", "kind": "emoji",
            "body": "🎉", "created_at": "2026-07-23T01:00:00+00:00"}]}
        """
        let state = try JSONDecoder().decode(RemoteGames.ChatState.self,
                                             from: Data(json.utf8))
        #expect(state.myLastRead == 7)
        #expect(state.messages.first?.isEmoji == true)
        #expect(state.messages.first?.body == "🎉")
    }

    /// Realtime echoes of our own sends dedupe by id.
    @Test func chatStoreDedupes() async {
        let store = await ChatStore(gameID: UUID(), myUserID: me)
        let m = message(1, from: me)
        #expect(await store.receive(m) == true)
        #expect(await store.receive(m) == false)
        #expect(await store.messages.count == 1)
    }
}
