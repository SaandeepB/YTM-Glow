import AppKit
import Combine
import SwiftUI
import YTMGlowCore

/// State the karaoke screen needs beyond the lyrics frame.
@MainActor
final class StageModel: ObservableObject {
    /// 0…1 beat pulse for the backdrop bloom.
    @Published var pulse: Double = 0
}

/// Full-screen karaoke view on another display ("karaoke screen").
///
/// Opens on the chosen display (by default the first one without the menu
/// bar) while a track plays, stays up through short pauses, and closes when
/// the music stops for a while, the tab goes away, or you press Esc.
@MainActor
final class StageController {
    /// Hide after this long paused.
    static let pausedTimeout: TimeInterval = 30
    /// Backdrop pulse updates are capped at this rate.
    static let maxPulseRate: Double = 20

    let model = StageModel()
    private let engine: PlayerEngine
    private let presenter: LyricsPresenter
    private let settings: AppSettings
    private let appearance: LyricsAppearance
    private var window: StageWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var pausedSince: Date?
    private var pauseCheck: DispatchWorkItem?
    private var envelope = BeatEnvelope()
    private var lastLevelsAt: TimeInterval?
    private var lastPulseAt: TimeInterval = 0

    init(engine: PlayerEngine, presenter: LyricsPresenter, settings: AppSettings, appearance: LyricsAppearance) {
        self.engine = engine
        self.presenter = presenter
        self.settings = settings
        self.appearance = appearance

        engine.observeLevels { [weak self] levels in self?.handleLevels(levels) }
        let triggers: [AnyPublisher<Void, Never>] = [
            engine.$track.map { _ in () }.eraseToAnyPublisher(),
            engine.$clock.map { _ in () }.eraseToAnyPublisher(),
            engine.$isAd.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
    }

    /// Connected displays, for the settings picker. The first has the menu bar.
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            DisplayInfo(id: screen.displayID, name: screen.localizedName, isMain: index == 0)
        }
    }

    func update() {
        guard settings.stageEnabled, engine.track != nil, !engine.isAd else {
            hide()
            return
        }
        if engine.isPlaying {
            pausedSince = nil
            pauseCheck?.cancel()
        } else if pausedSince == nil {
            pausedSince = Date()
            let work = DispatchWorkItem { [weak self] in self?.update() }
            pauseCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedTimeout + 0.1, execute: work)
        }
        if let since = pausedSince, Date().timeIntervalSince(since) >= Self.pausedTimeout {
            hide()
            return
        }
        guard let pick = StageDisplayPicker.pick(Self.displays(), preferredID: settings.stageDisplayID),
              let screen = NSScreen.screens.first(where: { $0.displayID == pick.id }) else {
            hide()
            return
        }
        show(on: screen)
    }

    private func show(on screen: NSScreen) {
        if window == nil {
            let window = StageWindow(frame: screen.frame)
            window.onClose = { [weak self] in self?.settings.stageEnabled = false }
            let view = StageView(presenter: presenter, engine: engine, appearance: appearance, stage: model) { [weak self] in
                self?.settings.stageEnabled = false
            }
            let hosting = NSHostingView(rootView: view)
            hosting.autoresizingMask = [.width, .height]
            window.contentView = hosting
            window.alphaValue = 0
            self.window = window
            Log.player.info("Karaoke screen on \(screen.localizedName, privacy: .public)")
        }
        guard let window else { return }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        if !window.isVisible {
            // Never steals focus from what you're doing; click it to use Esc.
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                window.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        pauseCheck?.cancel()
        pausedSince = nil
        guard let window else { return }
        self.window = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.close()
        })
    }

    private func handleLevels(_ levels: LevelsMessage) {
        let now = engine.now()
        let dt = lastLevelsAt.map { now - $0 } ?? (1.0 / 30)
        lastLevelsAt = now
        guard window != nil else { return }
        let pulse = envelope.update(bass: levels.bass, mid: levels.mid, high: levels.high, dt: dt)
        guard now - lastPulseAt >= 1 / Self.maxPulseRate, abs(pulse - model.pulse) > 0.02 else { return }
        lastPulseAt = now
        model.pulse = pulse
    }
}

/// Opaque full-screen window that can take key focus (for Esc) but doesn't grab it.
final class StageWindow: NSWindow {
    var onClose: (() -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        // Covers that display's menu bar, like a full-screen app.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
