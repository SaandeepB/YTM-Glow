import Foundation

/// Wire protocol version spoken by the app. See docs/PROTOCOL.md.
public let bridgeProtocolVersion = 1

/// Default loopback port shared by the app and the browser extension.
public let defaultBridgePort: UInt16 = 47816

// MARK: - Client → app

public struct HelloMessage: Codable, Equatable, Sendable {
    public var v: Int?
    public var client: String?
    public var version: String?
    public var browser: String?

    public init(v: Int? = bridgeProtocolVersion, client: String?, version: String?, browser: String? = nil) {
        self.v = v
        self.client = client
        self.version = version
        self.browser = browser
    }
}

public struct ArtworkImage: Codable, Equatable, Sendable {
    public var src: String
    public var sizes: String?
    public var type: String?

    public init(src: String, sizes: String? = nil, type: String? = nil) {
        self.src = src
        self.sizes = sizes
        self.type = type
    }

    /// Largest edge parsed from a `sizes` value such as "544x544" or "60x60 120x120".
    public var largestEdge: Int? {
        guard let sizes else { return nil }
        return sizes
            .split(whereSeparator: { $0 == " " })
            .compactMap { token -> Int? in
                let parts = token.lowercased().split(separator: "x")
                guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
                return max(w, h)
            }
            .max()
    }
}

public struct TrackPayload: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var artwork: [ArtworkImage]?
    public var videoId: String?

    public init(title: String, artist: String, album: String? = nil, artwork: [ArtworkImage]? = nil, videoId: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.videoId = videoId
    }
}

public struct PlaybackPayload: Codable, Equatable, Sendable {
    public var position: Double
    public var duration: Double?
    public var paused: Bool
    public var rate: Double?
    public var ended: Bool?
    /// Playing but stalled for data (buffering): position isn't advancing.
    public var waiting: Bool?

    public init(position: Double, duration: Double?, paused: Bool, rate: Double? = 1, ended: Bool? = false, waiting: Bool? = false) {
        self.position = position
        self.duration = duration
        self.paused = paused
        self.rate = rate
        self.ended = ended
        self.waiting = waiting
    }
}

/// Whether the extension's Web Audio tap is delivering levels.
public enum AudioTapStatus: String, Codable, Equatable, Sendable {
    /// Levels are flowing.
    case active
    /// Waiting for a click or key press in the tab (autoplay rules).
    case pending
    /// The tap could not be created; the glow falls back to steady.
    case failed
    /// The app didn't ask for levels.
    case off
}

public struct StateMessage: Codable, Equatable, Sendable {
    public var source: String
    public var reason: String?
    public var track: TrackPayload?
    public var playback: PlaybackPayload?
    public var tap: AudioTapStatus?
    public var ad: Bool?

    public init(source: String, reason: String? = nil, track: TrackPayload?, playback: PlaybackPayload?, tap: AudioTapStatus? = nil, ad: Bool? = nil) {
        self.source = source
        self.reason = reason
        self.track = track
        self.playback = playback
        self.tap = tap
        self.ad = ad
    }
}

public struct LevelsMessage: Codable, Equatable, Sendable {
    public var source: String
    public var bass: Double
    public var mid: Double
    public var high: Double

    public init(source: String, bass: Double, mid: Double, high: Double) {
        self.source = source
        self.bass = bass
        self.mid = mid
        self.high = high
    }
}

public enum InboundMessage: Equatable, Sendable {
    case hello(HelloMessage)
    case state(StateMessage)
    case levels(LevelsMessage)
    case clear(source: String)
    case ping
    case unknown(type: String)
}

public enum MessageDecodingError: Error, Equatable {
    case notJSONObject
    case missingType
}

public enum MessageDecoder {
    private struct Envelope: Decodable { var type: String? }
    private struct ClearBody: Decodable { var source: String }

    /// Decodes one text frame. Unknown `type`s decode to `.unknown` so newer
    /// clients can add messages without breaking older apps.
    public static func decode(_ data: Data) throws -> InboundMessage {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw MessageDecodingError.notJSONObject
        }
        guard let type = envelope.type else { throw MessageDecodingError.missingType }
        switch type {
        case "hello": return .hello(try decoder.decode(HelloMessage.self, from: data))
        case "state": return .state(try decoder.decode(StateMessage.self, from: data))
        case "levels": return .levels(try decoder.decode(LevelsMessage.self, from: data))
        case "clear": return .clear(source: try decoder.decode(ClearBody.self, from: data).source)
        case "ping": return .ping
        default: return .unknown(type: type)
        }
    }

    public static func decode(_ text: String) throws -> InboundMessage {
        try decode(Data(text.utf8))
    }
}

// MARK: - App → client

public enum OutboundMessage: Equatable, Sendable {
    case welcome(appVersion: String, wantLevels: Bool)
    case config(wantLevels: Bool)
    case pong

    public func encoded() -> Data {
        let object: [String: Any]
        switch self {
        case let .welcome(appVersion, wantLevels):
            object = ["type": "welcome", "v": bridgeProtocolVersion, "app": "YTM Glow", "version": appVersion, "wantLevels": wantLevels]
        case let .config(wantLevels):
            object = ["type": "config", "wantLevels": wantLevels]
        case .pong:
            object = ["type": "pong"]
        }
        // Dictionaries of plain values always serialize.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
