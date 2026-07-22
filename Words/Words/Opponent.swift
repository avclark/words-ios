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

/// The built-in AI: computes the best move on a background queue via the
/// Phase 2 generator, with a small floor delay so its tiles don't
/// materialize the same instant the player's commit lands.
final class LocalAIOpponent: OpponentEngine {
    func takeTurn(board: [BoardCoord: Tile], rack: [Tile],
                  completion: @escaping (OpponentAction) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let move = AIPlayer.bestMove(board: board, rack: rack)
            let action: OpponentAction = move.map { .play(placement: $0.placement, word: $0.word) } ?? .pass
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(action)
            }
        }
    }
}
