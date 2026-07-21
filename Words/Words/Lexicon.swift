import Foundation

/// The bundled ENABLE word list (~173k words, open license).
///
/// CRITICAL (see GAME-LOGIC-REFERENCE.md): if the list is missing or broken
/// we crash immediately with a clear message. We never "fall open" and accept
/// every word — that failure mode is silent and poisons every game played.
enum Lexicon {
    static let words: Set<String> = load()

    static func contains(_ word: String) -> Bool {
        words.contains(word.uppercased())
    }

    private static func load() -> Set<String> {
        guard let url = Bundle.main.url(forResource: "enable1", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("enable1.txt is missing from the app bundle. Refusing to run without a dictionary.")
        }
        let words = Set(raw.split(whereSeparator: \.isNewline).map { String($0).uppercased() })
        guard words.count > 100_000 else {
            fatalError("enable1.txt loaded but only \(words.count) words — file is corrupt or truncated. Refusing to fall open.")
        }
        return words
    }
}
