import Foundation

/// sRGB color with components in 0…1.
public struct SRGBColor: Equatable, Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
    }

    /// `hue` in 0…1 (fraction of a turn).
    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - floor(hue)) * 6
        let s = Self.clamp(saturation)
        let v = Self.clamp(brightness)
        let sector = Int(h) % 6
        let f = h - floor(h)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: self.init(r: v, g: t, b: p)
        case 1: self.init(r: q, g: v, b: p)
        case 2: self.init(r: p, g: v, b: t)
        case 3: self.init(r: p, g: q, b: v)
        case 4: self.init(r: t, g: p, b: v)
        default: self.init(r: v, g: p, b: q)
        }
    }

    /// Accepts "#RRGGBB" or "RRGGBB".
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public var hue: Double { hsb.hue }
    public var saturation: Double { hsb.saturation }
    public var brightness: Double { hsb.brightness }

    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue > 0 ? delta / maxValue : 0
        return (hue, saturation, maxValue)
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Shortest distance between two hues, in fractions of a turn (0…0.5).
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    public func with(saturation: Double? = nil, brightness: Double? = nil) -> SRGBColor {
        let current = hsb
        return SRGBColor(hue: current.hue, saturation: saturation ?? current.saturation, brightness: brightness ?? current.brightness)
    }

    public func mixed(with other: SRGBColor, amount: Double) -> SRGBColor {
        let t = Self.clamp(amount)
        return SRGBColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
