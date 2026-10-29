import Combine
import CoreGraphics
import Foundation

public protocol LyricsProviding: Sendable {
    func lyrics(title: String, artist: String, album: String?, duration: Double?) async -> LyricsOutcome
}

extension LyricsService: LyricsProviding {}

public protocol ArtworkProviding: Sendable {
    func load(_ url: URL) async -> (image: CGImage, palette: Palette?)?
}

extension ArtworkLoader: ArtworkProviding {}

/// Aggregates everything the browser reports into one "now playing" state.
///
/// Several tabs (or browsers) may report at once; the most recently playing
/// one wins. Lyrics and album colors are fetched when the active track changes.
@MainActor
public final class PlayerEngine: ObservableObject {
    public enum BridgeStatus: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    public enum LyricsStatus: Equatable {
        case idle
        case loading
        case synced(Lyrics)
        case plainOnly
        case instrumental
        case notFound
        case failed(String)

        public var lyrics: Lyrics? {
            if case let .synced(lyrics) = self { return lyrics }
            return nil
        }
    }

    /// Reports older than this while "playing" are treated as paused (tab frozen or crashed).
    public var staleAfter: TimeInterval = 6
    /// Wait for the new track's duration to settle before looking up lyrics.
    public var lyricsDebounce: TimeInterval = 0.6

    @Published public private(set) var bridgeStatus: BridgeStatus = .starting
    @Published public private(set) var clients: [BridgeClientID: HelloMessage] = [:]
    @Published public private(set) var track: TrackPayload?
    @Published public private(set) var clock: PlaybackClock?
    @Published public private(set) var tapStatus: AudioTapStatus?
    @Published public private(set) var isAd = false
    @Published public private(set) var lyricsStatus: LyricsStatus = .idle
    @Published public private(set) var palette: Palette?
    @Published public private(set) var artwork: CGImage?

    /// Audio levels from the active source, ~30 Hz. Not published, to keep SwiftUI out of the hot path.
    public var onLevels: ((LevelsMessage) -> Void)?
    private var levelObservers: [(LevelsMessage) -> Void] = []

    /// Adds another consumer of audio levels (alongside `onLevels`).
    public func observeLevels(_ observer: @escaping (LevelsMessage) -> Void) {
        levelObservers.append(observer)
    }

    public let now: MonotonicClock
    private let lyricsProvider: LyricsProviding
    private let artworkProvider: ArtworkProviding

    private struct Source {
        var client: BridgeClientID
        var state: StateMessage
        var clock: PlaybackClock?
        var updatedAt: TimeInterval
        /// When this source last went from not playing to playing.
        var playingSince: TimeInterval?
    }

    private var sources: [String: Source] = [:]
    private(set) var activeSourceKey: String?
    private var trackKey: String?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var staleWork: DispatchWorkItem?

    public init(lyrics: LyricsProviding, artwork: ArtworkProviding, now: @escaping MonotonicClock = systemMonotonicClock) {
        lyricsProvider = lyrics
        artworkProvider = artwork
        self.now = now
    }

    public var isPlaying: Bool { (clock?.isPlaying ?? false) && !isAd && track != nil }
    public var isConnected: Bool { !clients.isEmpty }

    public func position() -> Double? { clock?.position(at: now()) }

    // MARK: - Events

    public func handle(_ event: BridgeEvent) {
        switch event {
        case let .listening(port):
            Log.bridge.info("Listening on 127.0.0.1:\(port)")
            bridgeStatus = .listening(port: port)
        case let .failed(message):
            Log.bridge.error("Bridge failed: \(message, privacy: .public)")
            bridgeStatus = .failed(message)
        case let .connected(client):
            Log.bridge.info("\(client.description, privacy: .public) connected")
            clients[client] = HelloMessage(v: nil, client: nil, version: nil)
        case let .disconnected(client):
            Log.bridge.info("\(client.description, privacy: .public) disconnected")
            clients[client] = nil
            sources = sources.filter { $0.value.client != client }
            reselect()
        case let .message(client, message):
            handle(message, from: client)
        }
    }

    private func handle(_ message: InboundMessage, from client: BridgeClientID) {
        switch message {
        case let .hello(hello):
            Log.bridge.info("hello from \(hello.client ?? "?", privacy: .public) \(hello.version ?? "?", privacy: .public) (\(hello.browser ?? "?", privacy: .public))")
            clients[client] = hello
        case let .state(state):
            if clients[client] == nil { clients[client] = HelloMessage(v: nil, client: nil, version: nil) }
            let key = Self.sourceKey(client, state.source)
            let timestamp = now()
            let clock = state.playback.map { PlaybackClock($0, receivedAt: timestamp) }
            var source = sources[key] ?? Source(client: client, state: state, clock: nil, updatedAt: timestamp, playingSince: nil)
            if clock?.isPlaying == true {
                if source.clock?.isPlaying != true { source.playingSince = timestamp }
            } else {
                source.playingSince = nil
            }
            source.state = state
            source.clock = clock
            source.updatedAt = timestamp
            sources[key] = source
            reselect()
        case let .levels(levels):
            guard Self.sourceKey(client, levels.source) == activeSourceKey else { return }
            onLevels?(levels)
            for observer in levelObservers { observer(levels) }
        case let .clear(source):
            sources[Self.sourceKey(client, source)] = nil
            reselect()
        case .ping, .unknown:
            break
        }
    }

    static func sourceKey(_ client: BridgeClientID, _ source: String) -> String {
        "\(client.raw)/\(source)"
    }

    // MARK: - Active source

    /// The source that most recently *started* playing wins; with nothing
    /// playing, the current choice sticks so paused heartbeats don't flip it.
    private func reselect() {
        let chosen: String?
        let newestPlaying = sources
            .compactMap { key, source in source.playingSince.map { (key, $0) } }
            .max { $0.1 < $1.1 }
        if let current = activeSourceKey, let since = sources[current]?.playingSince,
           let newest = newestPlaying, newest.1 <= since {
            chosen = current
        } else if let newest = newestPlaying {
            chosen = newest.0
        } else if let current = activeSourceKey, sources[current] != nil {
            chosen = current
        } else {
            chosen = sources.max { $0.value.updatedAt < $1.value.updatedAt }?.key
        }
        activeSourceKey = chosen
        apply(chosen.flatMap { sources[$0] })
    }

    private func apply(_ source: Source?) {
        let newTrack = source?.state.track
        if clock != source?.clock { clock = source?.clock }
        if tapStatus != source?.state.tap { tapStatus = source?.state.tap }
        let ad = source?.state.ad ?? false
        if isAd != ad { isAd = ad }
        if track != newTrack { track = newTrack }

        let key = newTrack.map { "\($0.videoId ?? "")|\($0.title)|\($0.artist)" }
        if key != trackKey {
            trackKey = key
            trackChanged()
        }
        armStaleTimer()
    }

    private func trackChanged() {
        lyricsTask?.cancel()
        artworkTask?.cancel()
        palette = nil
        artwork = nil
        guard let track, let key = trackKey else {
            lyricsStatus = .idle
            return
        }
        Log.player.info("Track: \(track.title, privacy: .public) — \(track.artist, privacy: .public)")
        lyricsStatus = .loading

        let debounce = lyricsDebounce
        lyricsTask = Task { [weak self, lyricsProvider] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            let duration = self.clock?.duration
            let outcome = await lyricsProvider.lyrics(title: track.title, artist: track.artist, album: track.album, duration: duration)
            guard !Task.isCancelled, self.trackKey == key else { return }
            Log.lyrics.info("Lyrics for \(track.title, privacy: .public): \(String(describing: outcome).prefix(60), privacy: .public)")
            switch outcome {
            case let .synced(lyrics): self.lyricsStatus = .synced(lyrics)
            case .plainOnly: self.lyricsStatus = .plainOnly
            case .instrumental: self.lyricsStatus = .instrumental
            case .notFound: self.lyricsStatus = .notFound
            case let .failed(message): self.lyricsStatus = .failed(message)
            }
        }

        if let url = ArtworkPolicy.pick(track.artwork ?? [], preferredEdge: 120) {
            artworkTask = Task { [weak self, artworkProvider] in
                let loaded = await artworkProvider.load(url)
                guard !Task.isCancelled, let self, self.trackKey == key else { return }
                self.artwork = loaded?.image
                self.palette = loaded?.palette
            }
        }
    }

    /// Retries the lyric lookup for the current track (e.g. after a network error).
    public func retryLyrics() {
        guard track != nil else { return }
        trackChanged()
    }

    // MARK: - Staleness

    private func armStaleTimer() {
        staleWork?.cancel()
        staleWork = nil
        guard let key = activeSourceKey, sources[key]?.clock?.isPlaying == true else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.markStale(key) }
        }
        staleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + staleAfter, execute: work)
    }

    /// Freezes a source that stopped reporting, so the glow and lyrics stop.
    func markStale(_ key: String) {
        guard var source = sources[key], let clock = source.clock, clock.isPlaying,
              now() - source.updatedAt >= staleAfter * 0.9 else { return }
        source.clock = PlaybackClock(
            position: clock.position(at: now()), duration: clock.duration, paused: true,
            rate: clock.rate, ended: clock.ended, receivedAt: now()
        )
        source.playingSince = nil
        sources[key] = source
        reselect()
    }
}
