import Foundation
import Testing
@testable import YTMGlowCore

@Suite struct MessageDecodingTests {
    @Test func decodesEveryRecordedFixtureMessage() throws {
        let lines = try Fixtures.jsonLines("session.jsonl")
        let messages = try lines.map { try MessageDecoder.decode($0) }
        guard case let .hello(hello) = messages[0] else { Issue.record("expected hello"); return }
        #expect(hello.client == "ytm-glow-extension")
        #expect(hello.v == 1)

        guard case let .state(state) = messages[1] else { Issue.record("expected state"); return }
        #expect(state.source == "tab-17")
        #expect(state.reason == "track")
        #expect(state.track?.title == "Glass Lanterns (Official Audio)")
        #expect(state.track?.album == "Night Market")
        #expect(state.track?.videoId == "abc123XYZ00")
        #expect(state.track?.artwork?.count == 2)
        #expect(state.track?.artwork?.last?.largestEdge == 544)
        #expect(state.playback == PlaybackPayload(position: 9.5, duration: 200.2, paused: false, rate: 1, ended: false, waiting: nil))
        #expect(state.tap == .active)
        #expect(state.ad == false)

        guard case let .levels(levels) = messages[2] else { Issue.record("expected levels"); return }
        #expect(levels == LevelsMessage(source: "tab-17", bass: 0.82, mid: 0.41, high: 0.12))
        #expect(messages.last == .ping)
    }

    @Test func toleratesMissingOptionalFieldsAndNulls() throws {
        let message = try MessageDecoder.decode(#"{"type":"state","source":"tab-1","track":null,"playback":{"position":0,"duration":null,"paused":true}}"#)
        guard case let .state(state) = message else { Issue.record("expected state"); return }
        #expect(state.track == nil)
        #expect(state.playback?.duration == nil)
        #expect(state.playback?.rate == nil)
        #expect(state.tap == nil)
    }

    @Test func unknownTypesAreNotErrors() throws {
        #expect(try MessageDecoder.decode(#"{"type":"futureThing","x":1}"#) == .unknown(type: "futureThing"))
        #expect(try MessageDecoder.decode(#"{"type":"clear","source":"tab-3"}"#) == .clear(source: "tab-3"))
    }

    @Test func malformedInputThrows() {
        #expect(throws: MessageDecodingError.notJSONObject) { try MessageDecoder.decode("not json") }
        #expect(throws: MessageDecodingError.missingType) { try MessageDecoder.decode(#"{"source":"x"}"#) }
        #expect(throws: (any Error).self) { try MessageDecoder.decode(#"{"type":"levels","source":"x","bass":"loud"}"#) }
        #expect(throws: (any Error).self) { try MessageDecoder.decode(#"{"type":"state"}"#) }
    }

    @Test func unknownTapStatusFailsLoudly() {
        #expect(throws: (any Error).self) {
            try MessageDecoder.decode(#"{"type":"state","source":"x","track":null,"playback":null,"tap":"weird"}"#)
        }
    }

    @Test func encodesAppMessages() throws {
        let welcome = try JSONSerialization.jsonObject(with: OutboundMessage.welcome(appVersion: "1.2.3", wantLevels: true).encoded()) as? [String: Any]
        #expect(welcome?["type"] as? String == "welcome")
        #expect(welcome?["v"] as? Int == bridgeProtocolVersion)
        #expect(welcome?["version"] as? String == "1.2.3")
        #expect(welcome?["wantLevels"] as? Bool == true)
        #expect(String(decoding: OutboundMessage.config(wantLevels: false).encoded(), as: UTF8.self) == #"{"type":"config","wantLevels":false}"#)
        #expect(String(decoding: OutboundMessage.pong.encoded(), as: UTF8.self) == #"{"type":"pong"}"#)
    }

    @Test func artworkSizesParse() {
        #expect(ArtworkImage(src: "x", sizes: "60x60 544x544").largestEdge == 544)
        #expect(ArtworkImage(src: "x", sizes: "480X360").largestEdge == 480)
        #expect(ArtworkImage(src: "x", sizes: "any").largestEdge == nil)
        #expect(ArtworkImage(src: "x").largestEdge == nil)
    }
}
