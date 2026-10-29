import Foundation

/// Turns line-timed LRC into word-timed lines.
///
/// LRCLIB lyrics only say when each *line* starts, so word times are an
/// estimate: each word gets a share of the line weighted by its syllable
/// count, and the line is sung at a natural pace instead of being stretched
/// across long instrumental gaps.
public enum WordTimingEstimator {
    /// Slowest pace assumed when a line has more time than it needs.
    public static let slowestSyllablesPerSecond = 1.8
    /// Fraction of the gap to the next line that a line may fill.
    public static let fillRatio = 0.92
    /// A line stays on screen this long after its last word when a long gap follows.
    public static let holdAfterLastWord = 2.5
    /// Extra weight per word so short words still get a visible beat.
    static let perWordWeight = 0.35
    /// Used for the last line when the song duration is unknown.
    static let defaultLastLineLength = 6.0

    public static func build(_ lrcLines: [LRCLine], songDuration: Double?) -> [LyricLine] {
        var result: [LyricLine] = []
        for (index, line) in lrcLines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            // Empty timed lines only mark where the previous line ends.
            guard !text.isEmpty else { continue }

            let nextStart = lrcLines[(index + 1)...].first { $0.time > line.time }?.time
            let limit: Double
            if let nextStart {
                limit = nextStart
            } else if let songDuration, songDuration > line.time {
                limit = min(songDuration, line.time + defaultLastLineLength * 2)
            } else {
                limit = line.time + defaultLastLineLength
            }
            let available = max(0.05, limit - line.time)

            let words: [LyricWord]
            if let explicit = line.words, !explicit.isEmpty {
                words = explicitWords(explicit, lineEnd: line.time + available)
            } else {
                words = estimateWords(text: text, start: line.time, available: available)
            }
            let sungEnd = words.last?.end ?? line.time + available
            let end = min(line.time + available, sungEnd + holdAfterLastWord)
            result.append(LyricLine(text: text, start: line.time, end: max(end, sungEnd), words: words))
        }
        return result
    }

    /// Estimated word timings for one line starting at `start` with
    /// `available` seconds before the next line.
    public static func estimateWords(text: String, start: Double, available: Double) -> [LyricWord] {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }

        let syllables = tokens.map { SyllableCounter.count($0.text) }
        let weights = syllables.map { $0 + perWordWeight }
        let totalWeight = weights.reduce(0, +)
        let totalSyllables = syllables.reduce(0, +)

        let slowest = max(0.6, totalSyllables / slowestSyllablesPerSecond)
        let sung = min(available * fillRatio, slowest)

        var words: [LyricWord] = []
        var cursor = start
        for (token, weight) in zip(tokens, weights) {
            let length = sung * weight / totalWeight
            words.append(LyricWord(text: token.text, start: cursor, end: cursor + length, spaceAfter: token.spaceAfter))
            cursor += length
        }
        return words
    }

    private static func explicitWords(_ words: [LRCWord], lineEnd: Double) -> [LyricWord] {
        words.enumerated().map { index, word in
            let end = index + 1 < words.count ? words[index + 1].time : min(lineEnd, word.time + 1.0)
            return LyricWord(text: word.text, start: word.time, end: max(end, word.time), spaceAfter: true)
        }
    }

    struct Token: Equatable {
        var text: String
        var spaceAfter: Bool
    }

    /// Splits on whitespace; scripts written without spaces (Chinese,
    /// Japanese) are split per character so they still light up progressively.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            let piece = String(chunk)
            if piece.contains(where: SyllableCounter.isUnspacedScript) {
                var pending = ""
                for character in piece {
                    if SyllableCounter.isUnspacedScript(character) {
                        if !pending.isEmpty, pending.contains(where: { $0.isLetter || $0.isNumber || SyllableCounter.isUnspacedScript($0) }) {
                            tokens.append(Token(text: pending, spaceAfter: false))
                            pending = ""
                        }
                        pending.append(character)
                    } else {
                        // Punctuation or Latin letters stick to the preceding character.
                        pending.append(character)
                    }
                }
                if !pending.isEmpty { tokens.append(Token(text: pending, spaceAfter: false)) }
                if !tokens.isEmpty { tokens[tokens.count - 1].spaceAfter = true }
            } else {
                tokens.append(Token(text: piece, spaceAfter: true))
            }
        }
        if !tokens.isEmpty { tokens[tokens.count - 1].spaceAfter = false }
        return tokens
    }
}

/// Rough syllable counts used as word-length weights.
public enum SyllableCounter {
    static let vowels: Set<Character> = Set("aeiouyàáâãäåæèéêëìíîïòóôõöøœùúûüýÿąęįųāēīōūăőűаеёиоуыэюяіїєαεηιουωάέήίόύώ")

    public static func count(_ word: String) -> Double {
        let lower = word.lowercased()
        var unspaced = 0
        var hangul = 0
        for scalar in lower.unicodeScalars {
            if (0xAC00...0xD7A3).contains(scalar.value) { hangul += 1 }
        }
        for character in lower where isUnspacedScript(character) { unspaced += 1 }
        if unspaced > 0 || hangul > 0 { return Double(unspaced + hangul) }

        let letters = lower.filter(\.isLetter)
        guard !letters.isEmpty else {
            // Numbers and symbols: a beat per digit group, at least a short one.
            return lower.contains(where: \.isNumber) ? Double(max(1, lower.filter(\.isNumber).count)) : 0.5
        }

        var groups = 0
        var previousWasVowel = false
        for character in letters {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { groups += 1 }
            previousWasVowel = isVowel
        }
        // Silent trailing "e" in English ("love", "time"), but not "-le" ("little").
        if groups > 1, letters.hasSuffix("e"), !letters.hasSuffix("le"), !letters.hasSuffix("ee") {
            groups -= 1
        }
        return Double(max(1, groups))
    }

    /// Han ideographs, kana, and Thai: scripts usually written without spaces.
    static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x0E00...0x0E7F, // Thai
             0x20000...0x2FFFF: // CJK Extensions B+
            return true
        default:
            return false
        }
    }
}
