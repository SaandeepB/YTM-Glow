import CoreGraphics
import Testing
@testable import YTMGlowCore

@Suite struct PaletteTests {
    let red = SRGBColor(r: 0.9, g: 0.1, b: 0.1)
    let blue = SRGBColor(r: 0.1, g: 0.2, b: 0.9)
    let green = SRGBColor(r: 0.1, g: 0.85, b: 0.3)

    @Test func twoColorArtGivesBothColors() throws {
        let pixels = Array(repeating: red, count: 500) + Array(repeating: blue, count: 500)
        let palette = try #require(PaletteExtractor.extract(pixels: pixels))
        let hues = Set([palette.primary, palette.secondary].map { Int(($0.hue * 360).rounded()) / 10 })
        #expect(hues == Set([Int((red.hue * 360).rounded()) / 10, Int((blue.hue * 360).rounded()) / 10]))
        #expect(!palette.isMonochrome)
    }

    @Test func smallVividAccentBeatsLargeDarkBackground() throws {
        let dark = SRGBColor(r: 0.08, g: 0.06, b: 0.1)
        let pixels = Array(repeating: dark, count: 900) + Array(repeating: green, count: 100)
        let palette = try #require(PaletteExtractor.extract(pixels: pixels))
        #expect(SRGBColor.hueDistance(palette.primary.hue, green.hue) < 0.03)
    }

    @Test func grayscaleArtIsMonochrome() throws {
        let pixels: [SRGBColor] = (0..<1000).map { (i: Int) -> SRGBColor in
            let level = Double(i % 10) / 10
            return SRGBColor(r: level, g: level, b: level)
        }
        let palette = try #require(PaletteExtractor.extract(pixels: pixels))
        #expect(palette.isMonochrome)
        let (a, b) = palette.glowColors
        #expect(a.brightness > 0.9 && a.saturation < 0.15)
        #expect(b.brightness > 0.9 && b.saturation < 0.15)
    }

    @Test func singleColorArtGetsADistinctPartner() throws {
        let palette = try #require(PaletteExtractor.extract(pixels: Array(repeating: SRGBColor(r: 0.95, g: 0.55, b: 0.1), count: 400)))
        #expect(SRGBColor.hueDistance(palette.primary.hue, palette.secondary.hue) > 0.08)
    }

    @Test func glowColorsAreBrightAndSaturated() throws {
        let muted = SRGBColor(r: 0.4, g: 0.3, b: 0.35)
        let palette = try #require(PaletteExtractor.extract(pixels: Array(repeating: muted, count: 300) + Array(repeating: blue.with(brightness: 0.5), count: 300)))
        let (a, b) = palette.glowColors
        for color in [a, b] {
            #expect(color.brightness >= 0.92 - 1e-9)
            #expect(color.saturation >= 0.55 - 1e-9)
        }
    }

    @Test func emptyInputHasNoPalette() {
        #expect(PaletteExtractor.extract(pixels: []) == nil)
    }

    @Test func extractsFromRealCGImage() throws {
        // Left half orange, right half teal, with a transparent-free sRGB bitmap.
        let orange = SRGBColor(r: 1, g: 0.5, b: 0.05)
        let teal = SRGBColor(r: 0.05, g: 0.7, b: 0.7)
        let image = try #require(TestImages.make(edge: 120, background: orange, regions: [(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), teal)]))
        let pixels = PaletteExtractor.samplePixels(image)
        #expect(pixels.count == PaletteExtractor.sampleEdge * PaletteExtractor.sampleEdge)
        let palette = try #require(PaletteExtractor.extract(from: image))
        let distances = [palette.primary, palette.secondary].map { color in
            min(SRGBColor.hueDistance(color.hue, orange.hue), SRGBColor.hueDistance(color.hue, teal.hue))
        }
        #expect(distances.allSatisfy { $0 < 0.03 })
        #expect(SRGBColor.hueDistance(palette.primary.hue, palette.secondary.hue) > 0.3)
    }

    @Test func colorConversionsRoundTrip() throws {
        #expect(SRGBColor(hex: "#FF8000")?.hex == "#FF8000")
        #expect(SRGBColor(hex: "00ff7f")?.hex == "#00FF7F")
        #expect(SRGBColor(hex: "nope") == nil)
        #expect(SRGBColor(hex: "#12345") == nil)
        for hue in stride(from: 0.0, to: 1.0, by: 0.07) {
            let color = SRGBColor(hue: hue, saturation: 0.8, brightness: 0.9)
            #expect(abs(color.hue - hue) < 1e-6)
            #expect(abs(color.saturation - 0.8) < 1e-6)
            #expect(abs(color.brightness - 0.9) < 1e-6)
        }
        #expect(SRGBColor.hueDistance(0.95, 0.05) - 0.1 < 1e-9)
        #expect(SRGBColor(r: 2, g: -1, b: .nan) == SRGBColor(r: 1, g: 0, b: 0))
    }
}
