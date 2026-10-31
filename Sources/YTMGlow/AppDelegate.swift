import AppKit
import Combine
import YTMGlowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private let settings = AppSettings()
    private lazy var engine = PlayerEngine(lyrics: LyricsService(), artwork: ArtworkLoader())
    private lazy var presenter = LyricsPresenter(engine: engine)
    private lazy var beat = BeatMeter(now: engine.now)
    private let server = BridgeServer(port: defaultBridgePort, appVersion: AppDelegate.appVersion)
    private var glow: GlowController?
    private var lyricsOverlay: LyricsOverlayController?
    private var lockScreen: LockScreenController?
    private var stage: StageController?
    private var statusItem: StatusItemController?
    private let displayAwake = DisplayAwakeController()
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if quitIfAlreadyRunning() { return }

        let engine = self.engine
        let glow = GlowController(engine: engine, settings: settings)
        self.glow = glow
        let beat = self.beat
        engine.observeLevels { levels in beat.feed(levels) }
        let lyricsOverlay = LyricsOverlayController(engine: engine, presenter: presenter, settings: settings, beat: beat)
        self.lyricsOverlay = lyricsOverlay
        let lockScreen = LockScreenController(engine: engine, presenter: presenter, settings: settings, lockMonitor: ScreenLockMonitor(),
                                              glow: glow, appearance: lyricsOverlay.appearance, beat: beat)
        self.lockScreen = lockScreen
        stage = StageController(engine: engine, presenter: presenter, settings: settings, appearance: lyricsOverlay.appearance, beat: beat)
        statusItem = StatusItemController(settings: settings, engine: engine, lockScreen: lockScreen, launchAtLogin: LaunchAtLogin(),
                                          extensionSetup: ExtensionSetup())

        // Ask the extension for audio levels only while something shows them:
        // music-sync glow, the karaoke screen, or the no-lyrics beat visualizer.
        Publishers.MergeMany([
            engine.$lyricsStatus.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            self.server.setWantLevels(self.settings.wantsLevels(lyricsUnavailable: self.engine.lyricsStatus.isUnavailable))
        }
        .store(in: &subscriptions)

        // English letters vs. original script, and the listener's language.
        engine.lyricsPreference = settings.lyricsPreference
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.engine.lyricsPreference = self.settings.lyricsPreference
            }
            .store(in: &subscriptions)

        // Keep the display awake only while music actually plays.
        Publishers.MergeMany([
            engine.$clock.map { _ in () }.eraseToAnyPublisher(),
            engine.$isAd.map { _ in () }.eraseToAnyPublisher(),
            engine.$track.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            self.displayAwake.update(enabled: self.settings.keepDisplayAwake, playing: self.engine.isPlaying)
        }
        .store(in: &subscriptions)

        server.start { event in
            MainActor.assumeIsolated { engine.handle(event) }
        }
        glow.update()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensChanged()
                self?.presenter.refresh()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayAwake.update(enabled: false, playing: false)
        server.stop()
    }

    private func screensChanged() {
        glow?.screensChanged()
        lyricsOverlay?.screensChanged()
        lockScreen?.screensChanged()
        stage?.update()
    }

    /// A second copy would fail to bind the bridge port; hand over to the first.
    private func quitIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }
}
