import Foundation
import YTMGlowCore

enum GlowMode: String, CaseIterable, Identifiable {
    case musicSync, steady
    var id: String { rawValue }
    var label: String { self == .musicSync ? "Music sync" : "Steady" }
}

enum ColorSource: String, CaseIterable, Identifiable {
    case album, custom
    var id: String { rawValue }
    var label: String { self == .album ? "Album art" : "Custom" }
}

enum LyricsStyle: String, CaseIterable, Identifiable {
    /// One large line floating above the Dock.
    case beam
    /// Previous, current and next lines on a frosted card.
    case cascade
    /// A compact pill under the menu bar.
    case capsule

    var id: String { rawValue }
    var label: String {
        switch self {
        case .beam: return "Beam"
        case .cascade: return "Cascade"
        case .capsule: return "Capsule"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultGlowColors = ("#FF5CC8", "#5AC8FF")
    static let defaultLyricsColor = "#FFD15C"

    private let defaults: UserDefaults

    @Published var glowEnabled: Bool { didSet { defaults.set(glowEnabled, forKey: Key.glowEnabled) } }
    @Published var glowMode: GlowMode { didSet { defaults.set(glowMode.rawValue, forKey: Key.glowMode) } }
    /// Points from the screen edge.
    @Published var glowThickness: Double { didSet { defaults.set(glowThickness, forKey: Key.glowThickness) } }
    /// 0…1.
    @Published var glowIntensity: Double { didSet { defaults.set(glowIntensity, forKey: Key.glowIntensity) } }
    @Published var glowColorSource: ColorSource { didSet { defaults.set(glowColorSource.rawValue, forKey: Key.glowColorSource) } }
    @Published var glowCustomA: String { didSet { defaults.set(glowCustomA, forKey: Key.glowCustomA) } }
    @Published var glowCustomB: String { didSet { defaults.set(glowCustomB, forKey: Key.glowCustomB) } }

    @Published var lyricsEnabled: Bool { didSet { defaults.set(lyricsEnabled, forKey: Key.lyricsEnabled) } }
    @Published var lyricsStyle: LyricsStyle { didSet { defaults.set(lyricsStyle.rawValue, forKey: Key.lyricsStyle) } }
    @Published var lyricsColorSource: ColorSource { didSet { defaults.set(lyricsColorSource.rawValue, forKey: Key.lyricsColorSource) } }
    @Published var lyricsCustomColor: String { didSet { defaults.set(lyricsCustomColor, forKey: Key.lyricsCustomColor) } }
    /// Seconds; positive shows lyrics later.
    @Published var lyricsOffset: Double { didSet { defaults.set(lyricsOffset, forKey: Key.lyricsOffset) } }
    /// Text size multiplier.
    @Published var lyricsScale: Double { didSet { defaults.set(lyricsScale, forKey: Key.lyricsScale) } }
    /// Prevent display sleep while music plays.
    @Published var keepDisplayAwake: Bool { didSet { defaults.set(keepDisplayAwake, forKey: Key.keepDisplayAwake) } }
    /// Experimental, private API: show glow and lyrics over the lock screen.
    @Published var lockScreenEnabled: Bool { didSet { defaults.set(lockScreenEnabled, forKey: Key.lockScreenEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.glowEnabled: true,
            Key.glowMode: GlowMode.musicSync.rawValue,
            Key.glowThickness: 38.0,
            Key.glowIntensity: 0.8,
            Key.glowColorSource: ColorSource.album.rawValue,
            Key.glowCustomA: Self.defaultGlowColors.0,
            Key.glowCustomB: Self.defaultGlowColors.1,
            Key.lyricsEnabled: true,
            Key.lyricsStyle: LyricsStyle.beam.rawValue,
            Key.lyricsColorSource: ColorSource.album.rawValue,
            Key.lyricsCustomColor: Self.defaultLyricsColor,
            Key.lyricsOffset: 0.0,
            Key.lyricsScale: 1.0,
            Key.keepDisplayAwake: false,
            Key.lockScreenEnabled: false,
        ])
        glowEnabled = defaults.bool(forKey: Key.glowEnabled)
        glowMode = GlowMode(rawValue: defaults.string(forKey: Key.glowMode) ?? "") ?? .musicSync
        glowThickness = defaults.double(forKey: Key.glowThickness)
        glowIntensity = defaults.double(forKey: Key.glowIntensity)
        glowColorSource = ColorSource(rawValue: defaults.string(forKey: Key.glowColorSource) ?? "") ?? .album
        glowCustomA = defaults.string(forKey: Key.glowCustomA) ?? Self.defaultGlowColors.0
        glowCustomB = defaults.string(forKey: Key.glowCustomB) ?? Self.defaultGlowColors.1
        lyricsEnabled = defaults.bool(forKey: Key.lyricsEnabled)
        lyricsStyle = LyricsStyle(rawValue: defaults.string(forKey: Key.lyricsStyle) ?? "") ?? .beam
        lyricsColorSource = ColorSource(rawValue: defaults.string(forKey: Key.lyricsColorSource) ?? "") ?? .album
        lyricsCustomColor = defaults.string(forKey: Key.lyricsCustomColor) ?? Self.defaultLyricsColor
        lyricsOffset = defaults.double(forKey: Key.lyricsOffset)
        lyricsScale = defaults.double(forKey: Key.lyricsScale)
        keepDisplayAwake = defaults.bool(forKey: Key.keepDisplayAwake)
        lockScreenEnabled = defaults.bool(forKey: Key.lockScreenEnabled)
    }

    /// Whether the extension should stream audio levels.
    var wantsLevels: Bool { glowEnabled && glowMode == .musicSync }

    private enum Key {
        static let glowEnabled = "glow.enabled"
        static let glowMode = "glow.mode"
        static let glowThickness = "glow.thickness"
        static let glowIntensity = "glow.intensity"
        static let glowColorSource = "glow.colorSource"
        static let glowCustomA = "glow.customA"
        static let glowCustomB = "glow.customB"
        static let lyricsEnabled = "lyrics.enabled"
        static let lyricsStyle = "lyrics.style"
        static let lyricsColorSource = "lyrics.colorSource"
        static let lyricsCustomColor = "lyrics.customColor"
        static let lyricsOffset = "lyrics.offset"
        static let lyricsScale = "lyrics.scale"
        static let keepDisplayAwake = "display.keepAwake"
        static let lockScreenEnabled = "experimental.lockScreen"
    }
}
