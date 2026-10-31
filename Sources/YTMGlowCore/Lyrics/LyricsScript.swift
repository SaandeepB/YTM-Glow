import Foundation

/// The writing system a set of lyrics uses. Indian songs on LRCLIB come in
/// their own script (తెలుగు, हिन्दी, தமிழ்…) or romanized in English letters,
/// and multi-language film songs share titles across language versions, so
/// the script tells us which version a lyric file really is.
public enum LyricsScript: String, CaseIterable, Codable, Sendable {
    case latin, devanagari, bengali, gurmukhi, gujarati, odia, tamil, telugu, kannada, malayalam

    public var isIndic: Bool { self != .latin }

    /// Shown in settings, in the script itself.
    public var label: String {
        switch self {
        case .latin: return "English letters"
        case .devanagari: return "हिन्दी / मराठी"
        case .bengali: return "বাংলা"
        case .gurmukhi: return "ਪੰਜਾਬੀ"
        case .gujarati: return "ગુજરાતી"
        case .odia: return "ଓଡ଼ିଆ"
        case .tamil: return "தமிழ்"
        case .telugu: return "తెలుగు"
        case .kannada: return "ಕನ್ನಡ"
        case .malayalam: return "മലയാളം"
        }
    }

    /// Language name used to search LRCLIB for this script's version.
    var searchName: String? {
        switch self {
        case .latin: return nil
        case .devanagari: return "Hindi"
        case .bengali: return "Bengali"
        case .gurmukhi: return "Punjabi"
        case .gujarati: return "Gujarati"
        case .odia: return "Odia"
        case .tamil: return "Tamil"
        case .telugu: return "Telugu"
        case .kannada: return "Kannada"
        case .malayalam: return "Malayalam"
        }
    }

    public static func of(_ scalar: Unicode.Scalar) -> LyricsScript? {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        case 0x0900...0x097F, 0xA8E0...0xA8FF: return .devanagari
        case 0x0980...0x09FF: return .bengali
        case 0x0A00...0x0A7F: return .gurmukhi
        case 0x0A80...0x0AFF: return .gujarati
        case 0x0B00...0x0B7F: return .odia
        case 0x0B80...0x0BFF: return .tamil
        case 0x0C00...0x0C7F: return .telugu
        case 0x0C80...0x0CFF: return .kannada
        case 0x0D00...0x0D7F: return .malayalam
        default: return nil
        }
    }

    /// The script most letters are written in, ignoring LRC tags. Nil when the
    /// text has no letters from these scripts (e.g. only Chinese or Korean).
    public static func dominant(in text: String) -> LyricsScript? {
        var counts: [LyricsScript: Int] = [:]
        var inTag = false
        for scalar in text.unicodeScalars {
            if scalar == "[" || scalar == "<" { inTag = true; continue }
            if scalar == "]" || scalar == ">" { inTag = false; continue }
            guard !inTag, let script = of(scalar) else { continue }
            counts[script, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }
}

/// An Indian language named in the track's metadata, like the "(Telugu)" in
/// "Pushpa - The Rise (Telugu)".
public enum IndianLanguage: String, CaseIterable, Sendable {
    case telugu, tamil, hindi, kannada, malayalam, marathi, bengali, punjabi, gujarati, odia

    public var script: LyricsScript {
        switch self {
        case .telugu: return .telugu
        case .tamil: return .tamil
        case .hindi, .marathi: return .devanagari
        case .kannada: return .kannada
        case .malayalam: return .malayalam
        case .bengali: return .bengali
        case .punjabi: return .gurmukhi
        case .gujarati: return .gujarati
        case .odia: return .odia
        }
    }

    /// English name for settings.
    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var names: [String] {
        switch self {
        case .bengali: return ["bengali", "bangla"]
        case .odia: return ["odia", "oriya"]
        default: return [rawValue]
        }
    }

    /// All language names, for stripping tags like "(Telugu Version)".
    static var allNames: [String] { allCases.flatMap(\.names) }

    /// The first language named as a whole word in any of `texts`.
    public static func hint(in texts: [String?]) -> IndianLanguage? {
        for text in texts.compactMap({ $0?.lowercased() }) {
            for language in allCases {
                for name in language.names where text.range(of: #"(^|[^\p{L}])"# + name + #"($|[^\p{L}])"#, options: .regularExpression) != nil {
                    return language
                }
            }
        }
        return nil
    }
}
