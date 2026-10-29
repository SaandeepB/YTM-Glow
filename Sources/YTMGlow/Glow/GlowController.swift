import AppKit
import Combine
import YTMGlowCore

/// Owns the glow windows (four edge strips per display) and drives them from
/// playback state and audio levels. Windows are ordered out when nothing
/// plays, so an idle app costs nothing to composite.
@MainActor
final class GlowController {
    /// Levels older than this mean the tap stalled; hold a steady glow instead.
    static let levelsStaleAfter: TimeInterval = 0.6
    /// Pulse updates are capped at this rate; each one makes WindowServer
    /// recomposite the screen edges.
    static let maxPulseRate: Double = 24

    var onWantLevelsChanged: ((Bool) -> Void)?

    /// Experimental: while set, strips live in this above-the-lock-screen
    /// space. Windows can't be moved back out, so changing it rebuilds them.
    var lockScreenSpace: SkyLightSpace? {
        didSet {
            guard lockScreenSpace !== oldValue else { return }
            rebuildStrips()
        }
    }

    private let engine: PlayerEngine
    private let settings: AppSettings
    private struct Strip {
        let window: OverlayWindow
        let view: GlowView
    }

    private var displays: [CGDirectDisplayID: [Strip]] = [:]
    private var strips: [Strip] { displays.values.flatMap { $0 } }
    private var envelope = BeatEnvelope()
    private var lastLevelsAt: TimeInterval?
    private var subscriptions: Set<AnyCancellable> = []
    private var shown = false
    private var hideWork: DispatchWorkItem?
    private var stallTimer: Timer?
    private var lastWantLevels: Bool?
    private var lastColors: (SRGBColor, SRGBColor)?
    private var alpha: CGFloat = 0
    private var lastPulseAt: TimeInterval = 0

    init(engine: PlayerEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings

        engine.onLevels = { [weak self] levels in self?.handleLevels(levels) }

        let triggers: [AnyPublisher<Void, Never>] = [
            engine.$clock.map { _ in () }.eraseToAnyPublisher(),
            engine.$isAd.map { _ in () }.eraseToAnyPublisher(),
            engine.$track.map { _ in () }.eraseToAnyPublisher(),
            engine.$tapStatus.map { _ in () }.eraseToAnyPublisher(),
            engine.$palette.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
    }

    /// Re-syncs windows with the connected displays.
    func screensChanged() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, strips) in displays where !ids.contains(id) {
            for strip in strips { strip.window.orderOut(nil) }
            displays[id] = nil
        }
        for screen in screens where displays[screen.displayID] == nil && shown {
            displays[screen.displayID] = makeStrips(for: screen)
        }
        layoutStrips()
        if shown {
            for strip in strips { strip.window.orderFrontRegardless() }
        }
        applyAppearance(animated: false)
    }

    func update() {
        let wantLevels = settings.wantsLevels
        if wantLevels != lastWantLevels {
            lastWantLevels = wantLevels
            onWantLevelsChanged?(wantLevels)
        }

        let shouldShow = settings.glowEnabled && engine.isPlaying
        if shouldShow && !shown {
            show()
        } else if !shouldShow && shown {
            hide()
        } else if shown {
            applyAppearance(animated: true)
            if !isPulsing { applySteadyLevel(duration: 0.4) }
        }
    }

    // MARK: - Show / hide

    private func show() {
        shown = true
        hideWork?.cancel()
        hideWork = nil
        for screen in NSScreen.screens where displays[screen.displayID] == nil {
            displays[screen.displayID] = makeStrips(for: screen)
        }
        layoutStrips()
        applyAppearance(animated: false)
        for strip in strips { strip.window.orderFrontRegardless() }
        envelope.reset()
        applySteadyLevel(duration: 0.6)
        startStallTimer()
    }

    private func hide() {
        shown = false
        stallTimer?.invalidate()
        stallTimer = nil
        setAlpha(0, fade: 0.9)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shown else { return }
            for strip in self.strips { strip.window.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func makeStrips(for screen: NSScreen) -> [Strip] {
        GlowStrips.rects(screenSize: screen.frame.size, thickness: settings.glowThickness).map { rect in
            let window = OverlayWindow(frame: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            window.alphaValue = alpha
            let view = GlowView(screenSize: screen.frame.size, stripRect: rect)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            if let colors = lastColors { view.setColors(colors.0, colors.1, animated: false) }
            if let space = lockScreenSpace {
                window.canBecomeVisibleWithoutLogin = true
                space.adopt(windowNumber: window.windowNumber)
            }
            return Strip(window: window, view: view)
        }
    }

    /// Replaces every strip window (used when moving into or out of the lock-screen space).
    private func rebuildStrips() {
        for strip in strips {
            strip.window.orderOut(nil)
            strip.window.close()
        }
        displays.removeAll()
        guard shown else { return }
        for screen in NSScreen.screens {
            displays[screen.displayID] = makeStrips(for: screen)
        }
        layoutStrips()
        for strip in strips { strip.window.orderFrontRegardless() }
    }

    /// Sizes strip windows for the current thickness and display geometry.
    private func layoutStrips() {
        let thickness = CGFloat(settings.glowThickness)
        for screen in NSScreen.screens {
            guard let strips = displays[screen.displayID] else { continue }
            let rects = GlowStrips.rects(screenSize: screen.frame.size, thickness: thickness)
            for (strip, rect) in zip(strips, rects) {
                let frame = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                if strip.window.frame != frame { strip.window.setFrame(frame, display: false) }
                strip.view.setGeometry(screenSize: screen.frame.size, stripRect: rect, thickness: thickness)
            }
        }
    }

    private func applyAppearance(animated: Bool) {
        let colors = ThemeColors.glow(settings: settings, palette: engine.palette)
        let changed = lastColors.map { $0.0 != colors.0 || $0.1 != colors.1 } ?? true
        lastColors = colors
        if changed {
            for strip in strips { strip.view.setColors(colors.0, colors.1, animated: animated) }
        }
        layoutStrips()
    }

    // MARK: - Levels

    /// Music sync is active and levels are arriving.
    private var isPulsing: Bool {
        guard settings.glowMode == .musicSync, engine.tapStatus == .active, let last = lastLevelsAt else { return false }
        return engine.now() - last < Self.levelsStaleAfter
    }

    private func handleLevels(_ levels: LevelsMessage) {
        let now = engine.now()
        let dt = lastLevelsAt.map { now - $0 } ?? (1.0 / 30)
        lastLevelsAt = now
        guard shown, settings.glowMode == .musicSync else { return }

        let pulse = envelope.update(bass: levels.bass, mid: levels.mid, high: levels.high, dt: dt)
        guard now - lastPulseAt >= 1 / Self.maxPulseRate else { return }
        let target = CGFloat(settings.glowIntensity * (0.22 + 0.78 * pulse))
        guard abs(target - alpha) >= 0.012 else { return }
        lastPulseAt = now
        setAlpha(target, fade: 0)
    }

    private func applySteadyLevel(duration: CFTimeInterval) {
        setAlpha(CGFloat(settings.glowIntensity * 0.85), fade: duration)
    }

    /// Window alpha is applied by WindowServer at composite time: no redraw.
    private func setAlpha(_ value: CGFloat, fade: TimeInterval) {
        guard abs(value - alpha) > 0.001 else { return }
        alpha = value
        if fade > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                for strip in strips { strip.window.animator().alphaValue = value }
            }
        } else {
            for strip in strips { strip.window.alphaValue = value }
        }
    }

    /// While shown in music-sync mode, falls back to steady if levels stop.
    private func startStallTimer() {
        stallTimer?.invalidate()
        var wasPulsing = isPulsing
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pulsing = self.isPulsing
                if wasPulsing && !pulsing {
                    self.envelope.reset()
                    self.applySteadyLevel(duration: 0.5)
                }
                wasPulsing = pulsing
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }
}
