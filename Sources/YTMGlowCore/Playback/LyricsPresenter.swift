import Combine
import Foundation

/// What the lyrics overlay should show right now.
public struct LyricsFrame: Equatable, Sendable {
    public var lyrics: Lyrics?
    public var lineIndex: Int?
    public var wordIndex: Int?
    public var nextLineIndex: Int?
    /// Lyrics are loaded and the track is playing.
    public var isActive: Bool

    public static let empty = LyricsFrame(lyrics: nil, lineIndex: nil, wordIndex: nil, nextLineIndex: nil, isActive: false)

    public var currentLine: LyricLine? { lineIndex.flatMap { lyrics?.lines[$0] } }
    public var nextLine: LyricLine? { nextLineIndex.flatMap { lyrics?.lines[$0] } }
    /// The line before the current one (or before the upcoming one during a gap).
    public var previousLine: LyricLine? {
        guard let lyrics else { return nil }
        let reference = lineIndex ?? nextLineIndex ?? lyrics.lines.count
        let previous = reference - 1
        return previous >= 0 && previous < lyrics.lines.count ? lyrics.lines[previous] : nil
    }
}

/// Keeps a `LyricsFrame` in step with playback.
///
/// Rather than ticking at display rate, it wakes only at the next word or
/// line boundary, plus whenever the browser reports a new playback state.
@MainActor
public final class LyricsPresenter: ObservableObject {
    @Published public private(set) var frame: LyricsFrame = .empty

    /// Seconds; positive values show lyrics later.
    public var offset: Double = 0 {
        didSet { if offset != oldValue { refresh() } }
    }

    private let engine: PlayerEngine
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?

    public init(engine: PlayerEngine) {
        self.engine = engine
        engine.$clock.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        engine.$lyricsStatus.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        engine.$isAd.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
    }

    /// `@Published` emits before the value changes, so refresh on the next turn.
    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Playback time in lyric terms (position minus the offset), or nil without lyrics.
    public func lyricTime() -> Double? {
        guard engine.lyricsStatus.lyrics != nil, let position = engine.position() else { return nil }
        return position - offset
    }

    /// The lyric position at the engine's current time, after the offset.
    public func currentPosition() -> LyricPosition? {
        guard let lyrics = engine.lyricsStatus.lyrics, let position = engine.position() else { return nil }
        return lyrics.locate(position - offset)
    }

    public func refresh() {
        timer?.invalidate()
        timer = nil

        guard let lyrics = engine.lyricsStatus.lyrics, let clock = engine.clock else {
            update(.empty)
            return
        }
        let lyricTime = clock.position(at: engine.now()) - offset
        let position = lyrics.locate(lyricTime)
        let playing = clock.isPlaying && !engine.isAd
        update(LyricsFrame(
            lyrics: lyrics,
            lineIndex: position.lineIndex,
            wordIndex: position.wordIndex,
            nextLineIndex: position.nextLineIndex,
            isActive: playing
        ))

        // While buffering the position holds; the next state report resumes the schedule.
        guard playing, !clock.waiting, let boundary = lyrics.nextBoundary(after: lyricTime) else { return }
        let delay = max(0.01, (boundary - lyricTime) / clock.rate + 0.002)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update(_ newFrame: LyricsFrame) {
        if frame != newFrame { frame = newFrame }
    }
}
