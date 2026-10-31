import Foundation

/// Writes Indian-script lyrics in everyday English letters, the way people
/// type Telugu, Hindi or Tamil songs ("challani gaali", "mujhko itna"), on
/// device and offline.
///
/// macOS's ICU transliterator produces scholarly ISO 15919 ("callani gāli",
/// "mujhakō itanā"); this turns that into popular romanization: long vowels
/// doubled, c→ch, ś→sh, retroflex dots dropped, Hindi's silent inherent "a"
/// removed, and Tamil's voiced consonants spelled as they're sung.
public enum Romanizer {
    /// Romanizes every Indian-script word in `text`; other words are kept.
    public static func romanize(_ text: String) -> String {
        var output = ""
        var word = ""
        func flush() {
            output += romanizeWord(word)
            word = ""
        }
        for character in text {
            if character.isWhitespace {
                flush()
                output.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return output
    }

    public static func romanizeWord(_ word: String) -> String {
        guard let script = LyricsScript.dominant(in: word), script.isIndic else { return word }
        var source = word
        if [.devanagari, .gurmukhi, .gujarati].contains(script) {
            source = SchwaDeletion.apply(to: source)
        }
        guard let iso = source.applyingTransform(.toLatin, reverse: false) else { return word }
        var latin = popular(iso.lowercased(), script: script)
        // Malayalam words ending in a bare virama are sung with a short "u".
        if script == .malayalam, word.unicodeScalars.last?.value == 0x0D4D { latin += "u" }
        return latin
    }

    /// ISO 15919 → popular romanization.
    static func popular(_ iso: String, script: LyricsScript) -> String {
        var text = iso
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }

        switch script {
        case .tamil:
            replace("ṟṟ", "tr")
            replace("ḻ", "zh")
            // Tamil stops are voiced between vowels and after nasals.
            let vowel = "[aāiīuūeēoō]"
            replace("(?<=\(vowel))k(?=\(vowel))", "g")
            replace("(?<=ṅ)k", "g")
            replace("(?<=\(vowel))ṭ(?=\(vowel))", "ḍ")
            replace("(?<=ṇ)ṭ", "ḍ")
            replace("(?<=\(vowel))t(?=\(vowel))", "dh")
            replace("^t(?=\(vowel))", "th")
            replace("(?<=n)t", "th")
            replace("tt", "tth")
            replace("(?<=\(vowel))c(?=\(vowel))", "s")
            replace("^c", "s")
            replace("(?<=ñ)c", "j")
            replace("cc", "ch")
        case .malayalam:
            replace("ṟṟ", "tt")
            replace("ḻ", "zh")
        default:
            break
        }

        // Consonants: ISO "c" is "ch", ISO "ch" is the aspirated "chh".
        replace("ch", "\u{1}")
        replace("c", "ch")
        replace("\u{1}", "chh")
        replace("[śṣ]", "sh")
        replace("ṭ", "t")
        replace("ḍ", "d")
        replace("[ṇṅñṉ]", "n")
        replace("ṁ(?=[pbm]|$)", "m")
        replace("ṁ", "n")
        replace("m̐", "n")
        replace("r̥̄", "ree")
        replace("r̥", "ri")
        replace("ṛ", "r")
        replace("ḥ", "h")
        replace("ḷ", "l")
        replace("ṟ", "r")
        replace("ẏ", "y")

        // Vowels: long vowels doubled inside words, single at the end.
        replace("ā(?=\\P{L}|$)", "a")
        replace("ā", "aa")
        replace("ī(?=\\P{L}|$)", "i")
        replace("ī", "ee")
        replace("ū(?=\\P{L}|$)", "u")
        replace("ū", "oo")
        replace("ē", "e")
        replace("ō", "o")

        // Vowel separators: "batā'ē" → "bataaye", "kō'ī" → "koi".
        replace("'(ē|e)", "ye")
        replace("'", "")

        return text.applyingTransform(.stripDiacritics, reverse: false) ?? text
    }
}

/// Hindi-style schwa deletion: the inherent "a" after a consonant is silent at
/// the end of a word and between two sounded syllables ("मुझको" is "mujhko",
/// not "mujhako"). Implemented by adding a virama to those consonants before
/// transliteration.
enum SchwaDeletion {
    private enum Kind {
        /// Consonant (or conjunct) still carrying its inherent "a".
        case schwa(conjunct: Bool)
        /// Has its own vowel: a vowel sign, an independent vowel, or a nasalized schwa.
        case vowel
        /// Ends in a virama: no vowel.
        case dead
    }

    static func apply(to word: String) -> String {
        var clusters = word.map(String.init)
        var kinds = clusters.map(classify)
        guard kinds.count >= 2 else { return word }

        func sounded(_ kind: Kind) -> Bool {
            switch kind {
            case .vowel, .schwa: return true
            case .dead: return false
            }
        }

        // Word-final schwa is silent unless the last syllable is a conjunct ("मित्र" = mitra).
        if case .schwa(conjunct: false) = kinds[kinds.count - 1] {
            kinds[kinds.count - 1] = .dead
            clusters[clusters.count - 1] += virama(for: clusters[clusters.count - 1])
        }
        // Medial schwa between two sounded syllables, scanning right to left.
        var index = kinds.count - 2
        while index >= 1 {
            if case .schwa(conjunct: false) = kinds[index], sounded(kinds[index - 1]), sounded(kinds[index + 1]) {
                kinds[index] = .dead
                clusters[index] += virama(for: clusters[index])
            }
            index -= 1
        }
        return clusters.joined()
    }

    private static func classify(_ cluster: String) -> Kind {
        let scalars = cluster.unicodeScalars.map(\.value)
        guard let first = scalars.first else { return .vowel }
        if !isConsonant(first) { return .vowel }
        if let last = scalars.last, isVirama(last) { return .dead }
        if scalars.contains(where: { isVowelSign($0) || isNasalization($0) }) { return .vowel }
        return .schwa(conjunct: scalars.contains(where: isVirama))
    }

    private static func virama(for cluster: String) -> String {
        guard let first = cluster.unicodeScalars.first?.value else { return "" }
        switch first {
        case 0x0A00...0x0A7F: return "\u{0A4D}"
        case 0x0A80...0x0AFF: return "\u{0ACD}"
        default: return "\u{094D}"
        }
    }

    private static func isConsonant(_ value: UInt32) -> Bool {
        (0x0915...0x0939).contains(value) || (0x0958...0x095F).contains(value)  // Devanagari
            || (0x0A15...0x0A39).contains(value) || (0x0A59...0x0A5E).contains(value)  // Gurmukhi
            || (0x0A95...0x0AB9).contains(value)  // Gujarati
    }

    private static func isVowelSign(_ value: UInt32) -> Bool {
        (0x093E...0x094C).contains(value) || (0x0962...0x0963).contains(value)
            || (0x0A3E...0x0A4C).contains(value)
            || (0x0ABE...0x0ACC).contains(value) || (0x0AE2...0x0AE3).contains(value)
    }

    /// Anusvara, chandrabindu, visarga: the syllable's vowel is sounded.
    private static func isNasalization(_ value: UInt32) -> Bool {
        [0x0901, 0x0902, 0x0903, 0x0A01, 0x0A02, 0x0A03, 0x0A70, 0x0A81, 0x0A82, 0x0A83].contains(value)
    }

    private static func isVirama(_ value: UInt32) -> Bool {
        value == 0x094D || value == 0x0A4D || value == 0x0ACD
    }
}

extension Lyrics {
    /// The same lyrics with Indian-script lines written in English letters.
    /// Word timing is kept from the original script, word for word.
    public func romanized() -> Lyrics {
        guard let script = LyricsScript.dominant(in: lines.map(\.text).joined(separator: " ")), script.isIndic else { return self }
        var copy = self
        copy.lines = lines.map { line in
            guard LyricsScript.dominant(in: line.text)?.isIndic == true else { return line }
            var line = line
            line.words = line.words.map { word in
                var word = word
                word.text = Romanizer.romanize(word.text)
                return word
            }
            if let first = line.words.first {
                line.words[0].text = first.text.prefix(1).uppercased() + first.text.dropFirst()
            }
            line.text = line.words.enumerated().map { index, word in
                word.text + (word.spaceAfter && index < line.words.count - 1 ? " " : "")
            }.joined()
            return line
        }
        copy.transliteratedFrom = script
        return copy
    }
}
