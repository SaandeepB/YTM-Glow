import Foundation

/// How the listener wants lyrics written.
public struct LyricsPreference: Equatable, Sendable {
    public enum Writing: String, CaseIterable, Sendable {
        /// Indian-language lyrics in English letters: a romanized version when
        /// LRCLIB has one, otherwise transliterated on device.
        case english
        /// The language's own script (తెలుగు, हिन्दी…) when available.
        case original
    }

    public var writing: Writing
    /// The listener's language, used to pick the right version of film songs
    /// released in several languages when the metadata doesn't say. nil = auto.
    public var language: IndianLanguage?

    public init(writing: Writing = .english, language: IndianLanguage? = nil) {
        self.writing = writing
        self.language = language
    }

    public static let `default` = LyricsPreference()

    /// The script to favor when choosing between LRCLIB versions.
    var preferredScript: LyricsScript? {
        switch writing {
        case .english: return .latin
        case .original: return language?.script
        }
    }

    /// Part of the lyrics cache key: different preferences pick different versions.
    var cacheTag: String {
        "\(writing.rawValue)-\(language?.rawValue ?? "auto")"
    }
}
