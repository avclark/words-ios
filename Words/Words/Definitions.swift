import SwiftUI

/// Tap-to-define data source (Phase 12): a bundled WordNet 3.1 extract
/// intersected with the ENABLE list (definitions.tsv, built offline —
/// ~58k base entries). Bundled beats an API here: definitions work
/// offline (AI games), never rate-limit, and WordNet's license needs only
/// the attribution line shown in the sheet.
///
/// WordNet covers LEMMAS, so regular inflections (CATS, QUIZZED, MAKING)
/// are resolved at lookup time by suffix-stripping candidates; irregulars
/// (MICE, RAN) were baked into the file at build time from WordNet's .exc
/// tables. Some valid ENABLE words (QI, ZA…) have no WordNet entry at
/// all — the UI says "valid word, no definition" rather than pretending
/// otherwise. Never used for validity: Lexicon remains the only judge.
///
/// License: WordNet 3.1 © 2011 Princeton University — free for any
/// purpose with notice, data provided "as is". The attribution line
/// below (shown in the definitions sheet) satisfies the acknowledgment
/// requirement.
enum Definitions {

    static let attribution = "Definitions from WordNet 3.1, © Princeton University."

    /// WORD → "n. gloss | v. gloss". Built once, lazily (~4MB file, a few
    /// hundred ms) — call warmUp() from a background hop before the first
    /// lookup so a definition tap never stalls the main thread.
    private static let store: [String: String] = load()

    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = store }
    }

    /// The definition line for a word, resolving regular inflections to
    /// their base entry. Nil = valid-but-undefined (caller says so).
    static func lookup(_ word: String) -> String? {
        let w = word.uppercased()
        if let direct = store[w] { return direct }
        for candidate in stems(of: w) {
            if let d = store[candidate] { return d }
        }
        return nil
    }

    private static func load() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "definitions", withExtension: "tsv"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            // Unlike the Lexicon (game-critical, fail loudly), definitions
            // are an amenity: a missing file degrades to "no definition".
            assertionFailure("definitions.tsv missing from bundle")
            return [:]
        }
        var map: [String: String] = [:]
        map.reserveCapacity(60_000)
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            map[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return map
    }

    /// Base-form candidates for a regularly inflected word, most specific
    /// first. Candidates are guesses — lookup() only accepts ones that
    /// exist in the store, so over-generating is harmless.
    static func stems(of w: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if s.count >= 2, !out.contains(s) { out.append(s) } }

        // Plurals / third person: CATS→CAT, BOXES→BOX, PONIES→PONY
        if w.hasSuffix("IES") { add(String(w.dropLast(3)) + "Y") }
        if w.hasSuffix("ES") { add(String(w.dropLast(2))) }
        if w.hasSuffix("S"), !w.hasSuffix("SS") { add(String(w.dropLast())) }
        // Past tense: BAKED→BAKE, WANTED→WANT, STOPPED→STOP, TRIED→TRY
        if w.hasSuffix("IED") { add(String(w.dropLast(3)) + "Y") }
        if w.hasSuffix("ED") {
            add(String(w.dropLast()))      // BAKED → BAKE
            add(String(w.dropLast(2)))     // WANTED → WANT
            undoubled(w.dropLast(2)).map(add)  // STOPPED → STOP
        }
        // Progressive: MAKING→MAKE, RUNNING→RUN, PLAYING→PLAY
        if w.hasSuffix("ING") {
            add(String(w.dropLast(3)))
            add(String(w.dropLast(3)) + "E")
            undoubled(w.dropLast(3)).map(add)
        }
        // Comparatives: BIGGER→BIG, NICEST→NICE, HAPPIER→HAPPY
        for suffix in ["ER", "EST"] where w.hasSuffix(suffix) {
            let stem = w.dropLast(suffix.count)
            add(String(stem))
            add(String(stem) + "E")
            undoubled(stem).map(add)
            if stem.hasSuffix("I") { add(String(stem.dropLast()) + "Y") }
        }
        return out
    }

    /// STOPP → STOP (a doubled final consonant collapsed), else nil.
    private static func undoubled(_ s: Substring) -> String? {
        guard s.count >= 3, let last = s.last, s.dropLast().last == last,
              !"AEIOU".contains(last) else { return nil }
        return String(s.dropLast())
    }
}

/// The words a tapped committed tile participates in — the payload of the
/// definitions sheet. Identifiable so it can drive .sheet(item:).
struct DefinitionRequest: Identifiable {
    let id = UUID()
    let words: [String]
}

/// Tap-to-define sheet: every word through the tapped tile, each with its
/// WordNet line or an honest "no definition" note.
struct DefinitionSheet: View {
    @Environment(\.theme) private var theme

    let request: DefinitionRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DEFINITIONS")
                    .font(theme.typography.font(13, .heavy))
                    .kerning(1.5)
                    .foregroundStyle(theme.chrome.ink.opacity(0.5))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.chrome.ink.opacity(0.3))
                }
            }
            .padding(.bottom, 14)

            ForEach(request.words, id: \.self) { word in
                VStack(alignment: .leading, spacing: 5) {
                    Text(word)
                        .font(theme.typography.font(24, .black))
                        .foregroundStyle(theme.chrome.accent)
                    if let definition = Definitions.lookup(word) {
                        ForEach(definition.components(separatedBy: " | "), id: \.self) { sense in
                            Text(sense)
                                .font(theme.typography.font(14, .regular))
                                .foregroundStyle(theme.chrome.ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("A valid word — no definition in our dictionary.")
                            .font(theme.typography.font(14, .regular))
                            .foregroundStyle(theme.chrome.ink.opacity(0.5))
                            .italic()
                    }
                }
                .padding(.bottom, 16)
            }

            Spacer(minLength: 0)

            Text(Definitions.attribution)
                .font(theme.typography.caption)
                .foregroundStyle(theme.chrome.ink.opacity(0.3))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents([.medium])
        .presentationBackground(theme.chrome.screenBackground)
    }
}
