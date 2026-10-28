import AppKit
import SwiftUI
import YTMGlowCore

extension SRGBColor {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

/// Resolved colors for the overlays, from album art or the user's picks.
@MainActor
enum ThemeColors {
    static let fallbackGlow = (SRGBColor(hue: 0.83, saturation: 0.6, brightness: 1), SRGBColor(hue: 0.55, saturation: 0.65, brightness: 1))

    static func glow(settings: AppSettings, palette: Palette?) -> (SRGBColor, SRGBColor) {
        switch settings.glowColorSource {
        case .custom:
            return (SRGBColor(hex: settings.glowCustomA) ?? fallbackGlow.0, SRGBColor(hex: settings.glowCustomB) ?? fallbackGlow.1)
        case .album:
            return palette?.glowColors ?? fallbackGlow
        }
    }

    /// Highlight for lit words plus a partner color for accents.
    static func lyrics(settings: AppSettings, palette: Palette?) -> (highlight: SRGBColor, accent: SRGBColor) {
        switch settings.lyricsColorSource {
        case .custom:
            let color = SRGBColor(hex: settings.lyricsCustomColor) ?? SRGBColor(hex: AppSettings.defaultLyricsColor)!
            return (color, color.with(brightness: max(0.5, color.brightness * 0.8)))
        case .album:
            let (a, b) = palette?.glowColors ?? fallbackGlow
            // Keep lit text readable: avoid very dark highlights.
            return (a.with(brightness: max(a.brightness, 0.95)), b)
        }
    }
}
