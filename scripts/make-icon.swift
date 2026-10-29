// Renders the YTM Glow app icon and the extension icons with Core Graphics.
//
//   swift scripts/make-icon.swift
//
// Writes Resources/AppIcon.icns, docs/images/icon.png and extension/icons/*.png.
// Original artwork: a night-sky tile with a glowing screen outline and two
// lyric bars, the first one half lit.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let pink = CGColor(srgbRed: 1.0, green: 0.36, blue: 0.78, alpha: 1)
let cyan = CGColor(srgbRed: 0.35, green: 0.78, blue: 1.0, alpha: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon into a square of `size` pixels. `simplified` drops fine detail for tiny sizes.
func drawIcon(size: Int, simplified: Bool = false, fullBleed: Bool = false) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // macOS icon grid: 824/1024 body with ~22% corner radius (full bleed for the extension).
    let inset = fullBleed ? 0 : s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bodyPath = roundedRect(body, body.width * 0.225)

    // Drop shadow under the tile.
    if !fullBleed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(bodyPath)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Night background.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.16, green: 0.07, blue: 0.27, alpha: 1),
        CGColor(srgbRed: 0.03, green: 0.09, blue: 0.20, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Soft ambient bloom behind the screen.
    let bloom = CGGradient(colorsSpace: space, colors: [pink.copy(alpha: 0.35)!, pink.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: body.midX - body.width * 0.12, y: body.midY + body.height * 0.1), startRadius: 0,
                           endCenter: CGPoint(x: body.midX - body.width * 0.12, y: body.midY + body.height * 0.1), endRadius: body.width * 0.55, options: [])
    let bloom2 = CGGradient(colorsSpace: space, colors: [cyan.copy(alpha: 0.3)!, cyan.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom2, startCenter: CGPoint(x: body.midX + body.width * 0.18, y: body.midY - body.height * 0.15), startRadius: 0,
                           endCenter: CGPoint(x: body.midX + body.width * 0.18, y: body.midY - body.height * 0.15), endRadius: body.width * 0.5, options: [])

    // Glowing screen outline with a pink → cyan gradient stroke.
    let screen = body.insetBy(dx: body.width * 0.17, dy: body.height * 0.22)
    let screenPath = roundedRect(screen, screen.height * 0.16)
    let stroke = max(2, body.width * (simplified ? 0.075 : 0.05))
    let strokeGradient = CGGradient(colorsSpace: space, colors: [pink, cyan] as CFArray, locations: [0, 1])!
    for (blur, alpha) in (simplified ? [(0.0, 1.0)] : [(body.width * 0.09, 0.9), (body.width * 0.035, 1.0), (0.0, 1.0)]) {
        ctx.saveGState()
        if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: pink.copy(alpha: alpha)!) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(screenPath)
        ctx.setLineWidth(stroke)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(strokeGradient, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // Two lyric bars; the first is half lit.
    let barHeight = screen.height * (simplified ? 0.17 : 0.12)
    let barX = screen.minX + screen.width * 0.16
    let fullWidth = screen.width * 0.68
    let top = CGRect(x: barX, y: screen.midY + barHeight * 0.35, width: fullWidth, height: barHeight)
    let bottom = CGRect(x: barX + fullWidth * 0.12, y: screen.midY - barHeight * 1.55, width: fullWidth * 0.76, height: barHeight)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.28))
    ctx.addPath(roundedRect(top, barHeight / 2)); ctx.fillPath()
    ctx.addPath(roundedRect(bottom, barHeight / 2)); ctx.fillPath()

    let lit = CGRect(x: top.minX, y: top.minY, width: top.width * 0.58, height: top.height)
    ctx.saveGState()
    if !simplified { ctx.setShadow(offset: .zero, blur: body.width * 0.04, color: CGColor(srgbRed: 1, green: 0.82, blue: 0.36, alpha: 0.9)) }
    ctx.addPath(roundedRect(lit, barHeight / 2))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.40, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(drawIcon(size: base, simplified: base <= 32), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(drawIcon(size: base * 2, simplified: base * 2 <= 32), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)

try writePNG(drawIcon(size: 512), to: root.appendingPathComponent("docs/images/icon.png"))
for size in [16, 32, 48, 128] {
    try writePNG(drawIcon(size: size, simplified: size <= 32, fullBleed: true), to: root.appendingPathComponent("extension/icons/icon-\(size).png"))
}
print("Wrote \(icns.path), docs/images/icon.png and extension/icons/")
