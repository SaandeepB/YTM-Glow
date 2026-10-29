import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import YTMGlowCore

/// Renders the lyrics styles and the settings popover to PNGs without
/// touching the screen:  `YTMGlow --render-previews <dir>`.
/// Used for the README images and for eyeballing layout changes.
@MainActor
enum PreviewRenderer {
    nonisolated static let sampleLRC = """
    [00:10.00]Hang the glass lanterns over the river
    [00:14.50]Every one is a wish we forgot
    [00:19.00]Hold the light till the morning delivers
    """

    struct SampleLyrics: LyricsProviding {
        func lyrics(title: String, artist: String, album: String?, duration: Double?) async -> LyricsOutcome {
            Lyrics(lrc: PreviewRenderer.sampleLRC, songDuration: duration).map { .synced($0) } ?? .notFound
        }
    }

    struct SampleArtwork: ArtworkProviding {
        func load(_ url: URL) async -> (image: CGImage, palette: Palette?)? {
            let palette = Palette(primary: SRGBColor(r: 1, g: 0.42, b: 0.62), secondary: SRGBColor(r: 0.36, g: 0.62, b: 1), isMonochrome: false)
            return (PreviewRenderer.artwork(palette), palette)
        }
    }

    static func run(outputDirectory: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let engine = PlayerEngine(lyrics: SampleLyrics(), artwork: SampleArtwork(), now: { 1000 })
        engine.lyricsDebounce = 0
        let client = BridgeClientID(raw: 1)
        engine.handle(.listening(port: defaultBridgePort))
        engine.handle(.message(client, .hello(HelloMessage(client: "ytm-glow-extension", version: "0.1.0", browser: "Google Chrome"))))
        let track = TrackPayload(title: "Glass Lanterns", artist: "The Paper Moths", album: "Night Market",
                                 artwork: [ArtworkImage(src: "https://lh3.googleusercontent.com/preview=w544-h544", sizes: "544x544")], videoId: "preview")
        engine.handle(.message(client, .state(StateMessage(source: "tab-1", track: track,
                                                           playback: PlaybackPayload(position: 11.9, duration: 200, paused: false), tap: .active))))
        for _ in 0..<100 where engine.lyricsStatus.lyrics == nil || engine.palette == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let defaults = UserDefaults(suiteName: "ytmglow-preview-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let presenter = LyricsPresenter(engine: engine)
        presenter.refresh()
        let appearance = LyricsAppearance()
        let colors = ThemeColors.lyrics(settings: settings, palette: engine.palette)
        appearance.highlight = colors.highlight
        appearance.accent = colors.accent
        appearance.artwork = engine.artwork
        appearance.visible = true

        var failures: Int32 = 0
        for (style, size) in [(LyricsStyle.beam, CGSize(width: 1100, height: 200)), (.cascade, CGSize(width: 900, height: 270)), (.capsule, CGSize(width: 760, height: 110))] {
            appearance.style = style
            let view = LyricsOverlayView(presenter: presenter, appearance: appearance)
                .environment(\.isRenderingPreview, true)
                .frame(width: size.width, height: size.height)
                .background(desktop)
            if !write(view, size: size, to: outputDirectory.appendingPathComponent("lyrics-\(style.rawValue).png")) { failures += 1 }
        }

        // Beam with each animation mode, caught mid-word.
        appearance.style = .beam
        for animation in LyricsAnimation.allCases {
            appearance.animation = animation
            let view = LyricsOverlayView(presenter: presenter, appearance: appearance)
                .environment(\.isRenderingPreview, true)
                .frame(width: 1100, height: 200)
                .background(desktop)
            if !write(view, size: CGSize(width: 1100, height: 200), to: outputDirectory.appendingPathComponent("animation-\(animation.rawValue).png")) { failures += 1 }
        }

        // The karaoke screen at 1080p.
        let stageModel = StageModel()
        stageModel.pulse = 0.6
        let stage = StageView(presenter: presenter, engine: engine, appearance: appearance, stage: stageModel, onClose: {})
            .frame(width: 1920, height: 1080)
        if !write(stage, size: CGSize(width: 1920, height: 1080), to: outputDirectory.appendingPathComponent("karaoke-screen.png")) { failures += 1 }

        // The glow, drawn by the real GlowView over a stand-in desktop.
        let glowSize = CGSize(width: 1100, height: 620)
        let glow = GlowView(screenSize: glowSize, stripRect: CGRect(origin: .zero, size: glowSize))
        glow.setGeometry(screenSize: glowSize, stripRect: CGRect(origin: .zero, size: glowSize), thickness: 46)
        let glowColors = ThemeColors.glow(settings: settings, palette: engine.palette)
        glow.setColors(glowColors.0, glowColors.1, animated: false)
        if !writeLayered(glow, over: desktop, size: glowSize, to: outputDirectory.appendingPathComponent("glow.png")) { failures += 1 }

        let lockScreen = LockScreenController(engine: engine, presenter: presenter, settings: settings,
                                              lockMonitor: ScreenLockMonitor(center: NotificationCenter()), glow: nil, appearance: appearance)
        let popover = SettingsView(settings: settings, engine: engine, lockScreen: lockScreen, launchAtLogin: LaunchAtLogin(),
                                   extensionSetup: ExtensionSetup(), onQuit: {})
            .background(Color(nsColor: .windowBackgroundColor))
        if !write(popover, size: nil, to: outputDirectory.appendingPathComponent("popover.png")) { failures += 1 }
        print("Wrote previews to \(outputDirectory.path)")
        return failures
    }

    /// A stand-in desktop so the overlays have something to sit on.
    private static var desktop: some View {
        LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.24), Color(red: 0.32, green: 0.22, blue: 0.30)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Renders through a real NSHostingView in an offscreen window so AppKit controls draw too.
    private static func write<V: View>(_ view: V, size: CGSize?, to url: URL) -> Bool {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let fitting = size ?? hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let image = rep.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Renders an AppKit layer tree with `CALayer.render(in:)` over a SwiftUI background.
    private static func writeLayered<B: View>(_ view: NSView, over background: B, size: CGSize, to url: URL) -> Bool {
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        let backdrop = NSHostingView(rootView: background.frame(width: size.width, height: size.height))
        backdrop.frame = container.bounds
        container.addSubview(backdrop)
        view.frame = container.bounds
        container.addSubview(view)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let scale: CGFloat = 2
        guard let root = container.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.scaleBy(x: scale, y: scale)
        root.render(in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    nonisolated static func artwork(_ palette: Palette) -> CGImage {
        let size = 128
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: nil, colors: [palette.primary.cgColor, palette.secondary.cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 44, y: 44, width: 40, height: 40))
        return context.makeImage()!
    }
}
