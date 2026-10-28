import CoreGraphics
import Foundation

public struct Palette: Equatable, Sendable {
    public var primary: SRGBColor
    public var secondary: SRGBColor
    /// True for grayscale art; glow then uses soft white.
    public var isMonochrome: Bool

    public init(primary: SRGBColor, secondary: SRGBColor, isMonochrome: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.isMonochrome = isMonochrome
    }

    /// Bright, saturated variants suited to emitting light on screen.
    public var glowColors: (SRGBColor, SRGBColor) {
        if isMonochrome {
            return (SRGBColor(hue: 0.6, saturation: 0.06, brightness: 0.97), SRGBColor(hue: 0.08, saturation: 0.08, brightness: 0.92))
        }
        func lift(_ color: SRGBColor) -> SRGBColor {
            color.with(saturation: min(1, max(color.saturation, 0.55)), brightness: max(color.brightness, 0.92))
        }
        return (lift(primary), lift(secondary))
    }
}

/// Picks two representative colors from album art, locally.
///
/// Pixels are bucketed by hue, saturation and brightness; buckets are scored
/// by how much of the image they cover and how vivid they are, so a small
/// bright accent can beat a large dark background.
public enum PaletteExtractor {
    static let sampleEdge = 40
    static let hueBins = 24
    /// Minimum hue separation for the second color (≈ 30°).
    static let minimumHueSeparation = 30.0 / 360.0

    public static func extract(from image: CGImage) -> Palette? {
        extract(pixels: samplePixels(image))
    }

    public static func extract(pixels: [SRGBColor]) -> Palette? {
        guard !pixels.isEmpty else { return nil }

        struct Bucket {
            var count = 0
            var r = 0.0, g = 0.0, b = 0.0
            var mean: SRGBColor { SRGBColor(r: r / Double(count), g: g / Double(count), b: b / Double(count)) }
        }

        var chromatic: [Int: Bucket] = [:]
        var gray = Bucket()
        var chromaticCount = 0
        for pixel in pixels {
            let (h, s, v) = pixel.hsb
            if s < 0.18 || v < 0.15 {
                if v >= 0.15 {
                    gray.count += 1; gray.r += pixel.r; gray.g += pixel.g; gray.b += pixel.b
                }
                continue
            }
            chromaticCount += 1
            let key = (Int(h * Double(hueBins)) % hueBins) * 4 + (s >= 0.55 ? 2 : 0) + (v >= 0.6 ? 1 : 0)
            chromatic[key, default: Bucket()].count += 1
            chromatic[key]!.r += pixel.r
            chromatic[key]!.g += pixel.g
            chromatic[key]!.b += pixel.b
        }

        let total = Double(pixels.count)
        // Treat art as grayscale when almost nothing is colorful.
        guard Double(chromaticCount) / total >= 0.03 else {
            let base = gray.count > 0 ? gray.mean : SRGBColor(r: 0.8, g: 0.8, b: 0.8)
            return Palette(primary: base, secondary: base.with(brightness: min(1, base.brightness + 0.2)), isMonochrome: true)
        }

        let scored: [(color: SRGBColor, score: Double)] = chromatic.values.map { bucket in
            let color = bucket.mean
            let coverage = Double(bucket.count) / total
            let (_, s, v) = color.hsb
            let vividness = s * v
            return (color, pow(coverage, 0.55) * (0.2 + vividness) * (v < 0.3 ? 0.4 : 1))
        }
        .sorted { $0.score > $1.score }

        let primary = scored[0].color
        let secondary = scored.dropFirst().first {
            SRGBColor.hueDistance($0.color.hue, primary.hue) >= minimumHueSeparation
        }?.color ?? derivedPartner(for: primary)
        return Palette(primary: primary, secondary: secondary, isMonochrome: false)
    }

    /// A neighboring hue for single-color art, so the gradient still has two ends.
    static func derivedPartner(for color: SRGBColor) -> SRGBColor {
        let (h, s, v) = color.hsb
        return SRGBColor(hue: h + 40.0 / 360.0, saturation: s, brightness: min(1, v * 0.95 + 0.05))
    }

    /// Downsamples an image to at most `sampleEdge`² sRGB pixels, skipping transparent ones.
    public static func samplePixels(_ image: CGImage) -> [SRGBColor] {
        let edge = sampleEdge
        let bytesPerRow = edge * 4
        var buffer = [UInt8](repeating: 0, count: edge * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return [] }

        var pixels: [SRGBColor] = []
        pixels.reserveCapacity(edge * edge)
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Double(buffer[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            pixels.append(SRGBColor(
                r: Double(buffer[index]) / 255 / alpha,
                g: Double(buffer[index + 1]) / 255 / alpha,
                b: Double(buffer[index + 2]) / 255 / alpha
            ))
        }
        return pixels
    }
}
