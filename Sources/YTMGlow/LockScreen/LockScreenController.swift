import AppKit
import Combine
import SwiftUI
import YTMGlowCore

/// Experimental: shows the glow and a now-playing lyrics card above the lock
/// screen, using a private SkyLight space (see `SkyLightSpace`).
///
/// Only active while the screen is locked and the option is on. The card is a
/// dedicated window created on lock and closed on unlock, so nothing stays in
/// the above-everything space while you use the Mac.
@MainActor
final class LockScreenController: ObservableObject {
    enum Status: Equatable {
        case off
        case ready
        case showing
        case unsupported(String)
    }

    @Published private(set) var status: Status = .off

    private let engine: PlayerEngine
    private let presenter: LyricsPresenter
    private let settings: AppSettings
    private let lockMonitor: ScreenLockMonitor
    private let glow: GlowController?
    private let appearance: LyricsAppearance
    private var space: SkyLightSpace?
    private var window: OverlayWindow?
    private var subscriptions: Set<AnyCancellable> = []

    init(engine: PlayerEngine, presenter: LyricsPresenter, settings: AppSettings, lockMonitor: ScreenLockMonitor,
         glow: GlowController?, appearance: LyricsAppearance) {
        self.engine = engine
        self.presenter = presenter
        self.settings = settings
        self.lockMonitor = lockMonitor
        self.glow = glow
        self.appearance = appearance

        let triggers: [AnyPublisher<Void, Never>] = [
            lockMonitor.$isLocked.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            engine.$track.map { _ in () }.eraseToAnyPublisher(),
            engine.$clock.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
    }

    func update() {
        guard settings.lockScreenEnabled else {
            tearDown()
            status = .off
            return
        }
        guard lockMonitor.isLocked else {
            tearDown()
            if case .unsupported = status { return }
            status = .ready
            return
        }

        guard let space = ensureSpace() else { return }
        glow?.lockScreenSpace = space

        let hasSomethingToShow = engine.track != nil && engine.isPlaying && (settings.lyricsEnabled || settings.glowEnabled)
        if hasSomethingToShow {
            showCard(in: space)
            status = .showing
        } else {
            closeCard()
            status = .ready
        }
    }

    func screensChanged() {
        guard let window, let screen = NSScreen.screens.first else { return }
        window.setFrame(Self.cardFrame(on: screen), display: true)
    }

    private func ensureSpace() -> SkyLightSpace? {
        if let space { return space }
        guard SkyLightSpace.isSupported else {
            status = .unsupported("Missing: " + SkyLightSpace.missingSymbols.joined(separator: ", "))
            return nil
        }
        guard let created = SkyLightSpace() else {
            status = .unsupported("WindowServer refused the lock-screen space")
            return nil
        }
        Log.player.info("Created lock-screen space \(created.spaceID)")
        space = created
        return created
    }

    private func showCard(in space: SkyLightSpace) {
        guard let screen = NSScreen.screens.first else { return }
        if window == nil {
            let window = OverlayWindow(frame: Self.cardFrame(on: screen))
            window.canBecomeVisibleWithoutLogin = true
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            let root = LockScreenCard(engine: engine, presenter: presenter, appearance: appearance, settings: settings)
            let hosting = NSHostingView(rootView: root)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = .clear
            window.contentView = hosting
            space.adopt(windowNumber: window.windowNumber)
            self.window = window
        }
        window?.orderFrontRegardless()
    }

    private func closeCard() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func tearDown() {
        closeCard()
        // Moves the glow back to ordinary windows.
        glow?.lockScreenSpace = nil
    }

    /// Lower-middle of the menu-bar display: clear of the clock above and the
    /// password field below.
    static func cardFrame(on screen: NSScreen) -> NSRect {
        let full = screen.frame
        let width = min(860, full.width * 0.7)
        let height: CGFloat = 250
        return NSRect(x: full.midX - width / 2, y: full.minY + full.height * 0.36, width: width, height: height).integral
    }
}

/// Album art, title and the current lyric line, sized for the lock screen.
private struct LockScreenCard: View {
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var presenter: LyricsPresenter
    @ObservedObject var appearance: LyricsAppearance
    @ObservedObject var settings: AppSettings

    var body: some View {
        let frame = presenter.frame
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Group {
                    if let art = engine.artwork {
                        Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [appearance.highlight.swiftUI, appearance.accent.swiftUI],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.track?.title ?? "")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(engine.track?.artist ?? "")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .lineLimit(1)
            }

            if settings.lyricsEnabled, let line = frame.currentLine {
                KaraokeLine(line: line, litThrough: frame.wordIndex, fontSize: 30, highlight: appearance.highlight.swiftUI)
                    .id(frame.lineIndex)
                    .transition(.opacity)
            } else if settings.lyricsEnabled, let next = frame.nextLine {
                Text(next.text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .animation(.easeOut(duration: 0.3), value: frame.lineIndex)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }
}
