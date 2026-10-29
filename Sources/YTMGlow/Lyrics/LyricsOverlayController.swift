import AppKit
import Combine
import SwiftUI
import YTMGlowCore

/// Hosts the lyrics overlay on the main display and decides when it shows.
@MainActor
final class LyricsOverlayController {
    let appearance = LyricsAppearance()

    private let engine: PlayerEngine
    private let presenter: LyricsPresenter
    private let settings: AppSettings
    private let window: OverlayWindow
    private var subscriptions: Set<AnyCancellable> = []
    private var hideWork: DispatchWorkItem?
    private var placedStyle: LyricsStyle?
    private var placedScreenFrame: NSRect?

    init(engine: PlayerEngine, presenter: LyricsPresenter, settings: AppSettings) {
        self.engine = engine
        self.presenter = presenter
        self.settings = settings

        window = OverlayWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let hosting = NSHostingView(rootView: LyricsOverlayView(presenter: presenter, appearance: appearance))
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        window.contentView = hosting

        let triggers: [AnyPublisher<Void, Never>] = [
            presenter.$frame.map { _ in () }.eraseToAnyPublisher(),
            engine.$palette.map { _ in () }.eraseToAnyPublisher(),
            engine.$artwork.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
    }

    func screensChanged() {
        placedScreenFrame = nil
        update()
    }

    func update() {
        presenter.offset = settings.lyricsOffset

        let colors = ThemeColors.lyrics(settings: settings, palette: engine.palette)
        if appearance.highlight != colors.highlight { appearance.highlight = colors.highlight }
        if appearance.accent != colors.accent { appearance.accent = colors.accent }
        if appearance.style != settings.lyricsStyle { appearance.style = settings.lyricsStyle }
        if appearance.scale != settings.lyricsScale { appearance.scale = settings.lyricsScale }
        if appearance.animation != settings.lyricsAnimation { appearance.animation = settings.lyricsAnimation }
        if appearance.artwork !== engine.artwork { appearance.artwork = engine.artwork }

        let frame = presenter.frame
        let shouldShow = settings.lyricsEnabled && frame.isActive && (frame.currentLine != nil || frame.nextLine != nil)
        if shouldShow {
            hideWork?.cancel()
            hideWork = nil
            placeWindow()
            if !window.isVisible { window.orderFrontRegardless() }
            if !appearance.visible { appearance.visible = true }
        } else if appearance.visible || window.isVisible {
            if appearance.visible { appearance.visible = false }
            guard hideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                if !self.appearance.visible { self.window.orderOut(nil) }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// Sizes and positions the window for the current style on the menu-bar display.
    private func placeWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let style = settings.lyricsStyle
        let scale = CGFloat(settings.lyricsScale)
        guard style != placedStyle || screen.frame != placedScreenFrame || window.frame.isEmpty || scaleChanged(scale) else { return }
        placedStyle = style
        placedScreenFrame = screen.frame
        placedScale = scale

        let full = screen.frame
        let visible = screen.visibleFrame
        let rect: NSRect
        switch style {
        case .beam:
            let width = min(full.width, 1500)
            let height = 190 * scale
            rect = NSRect(x: full.midX - width / 2, y: visible.minY + 24, width: width, height: height)
        case .cascade:
            let width = min(980, full.width * 0.72)
            let height = 230 * scale + 40
            rect = NSRect(x: full.midX - width / 2, y: visible.minY + 30, width: width, height: height)
        case .capsule:
            let width = min(820, full.width * 0.62)
            let height = 110 * scale
            rect = NSRect(x: full.midX - width / 2, y: visible.maxY - height, width: width, height: height)
        }
        window.setFrame(rect.integral, display: true)
    }

    private var placedScale: CGFloat?
    private func scaleChanged(_ scale: CGFloat) -> Bool { placedScale != scale }
}
