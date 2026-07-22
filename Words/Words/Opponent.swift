import Foundation

/// What an opponent did with its turn. Scoring is NOT part of the action —
/// the game applies every move through the same shared MoveScorer path,
/// regardless of where the move came from.
enum OpponentAction {
    case play(placement: [BoardCoord: Tile], word: String)
    case pass
}

/// The seam between the game and whatever is driving the other player.
/// The game hands over the turn and, at some later point, receives an
/// action on the main queue. It never knows whether the action was computed
/// by the local AI generator or arrived from a server — a remote-player
/// implementation slots in here without touching BoardState or the views.
protocol OpponentEngine: AnyObject {
    /// Called when the turn passes to the opponent. `board` and `rack` are
    /// value-type snapshots. `completion` must be invoked exactly once, on
    /// the main queue.
    func takeTurn(board: [BoardCoord: Tile], rack: [Tile],
                  completion: @escaping (OpponentAction) -> Void)
}

/// How strong the AI plays. Every difficulty plays only legal moves; the
/// levels differ in which of the generator's ranked candidates gets picked
/// (see AIPlayer.move). Persisted per game.
enum AIDifficulty: String, Codable, CaseIterable, Identifiable {
    case easy, medium, hard

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var blurb: String {
        switch self {
        case .easy: return "Plays relaxed"
        case .medium: return "Puts up a fight"
        case .hard: return "Plays the best move it can find"
        }
    }
}

/// The built-in AI: computes its move on a background queue via the
/// Phase 2 generator, with a small floor delay so its tiles don't
/// materialize the same instant the player's commit lands.
final class LocalAIOpponent: OpponentEngine {
    private let difficulty: AIDifficulty

    init(difficulty: AIDifficulty = .hard) {
        self.difficulty = difficulty
    }

    func takeTurn(board: [BoardCoord: Tile], rack: [Tile],
                  completion: @escaping (OpponentAction) -> Void) {
        let difficulty = difficulty
        DispatchQueue.global(qos: .userInitiated).async {
            let move = AIPlayer.move(board: board, rack: rack, difficulty: difficulty)
            let action: OpponentAction = move.map { .play(placement: $0.placement, word: $0.word) } ?? .pass
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(action)
            }
        }
    }
}
