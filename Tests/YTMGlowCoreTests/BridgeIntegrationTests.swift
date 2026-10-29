import Foundation
import Testing
@testable import YTMGlowCore

/// End-to-end over a real loopback WebSocket: a fake extension client replays
/// recorded messages and the engine, presenter and server react.
@MainActor
@Suite(.serialized)
struct BridgeIntegrationTests {
    let clock = TestClock()
    let engine: PlayerEngine
    let presenter: LyricsPresenter
    let server = BridgeServer(port: 0, appVersion: "test")

    init() throws {
        let lrc = try Fixtures.text("glass-lanterns.lrc")
        engine = PlayerEngine(
            lyrics: FakeLyricsProvider(lrcByTitle: ["Glass Lanterns (Official Audio)": lrc]),
            artwork: FakeArtworkProvider(palette: Palette(primary: SRGBColor(r: 1, g: 0.3, b: 0.2), secondary: SRGBColor(r: 0.2, g: 0.4, b: 1), isMonochrome: false)),
            now: clock.closure
        )
        engine.lyricsDebounce = 0
        presenter = LyricsPresenter(engine: engine)
    }

    private func startServer() async throws -> UInt16 {
        let engine = self.engine
        server.start { event in MainActor.assumeIsolated { engine.handle(event) } }
        let ready = await waitUntil {
            if case .listening = engine.bridgeStatus { return true }
            return false
        }
        try #require(ready, "server never started listening")
        guard case let .listening(port) = engine.bridgeStatus else { throw TestFailure("not listening") }
        #expect(port != 0)
        return port
    }

    private func replaySession(on client: FakeExtensionClient) async throws {
        for line in try Fixtures.jsonLines("session.jsonl") {
            try await client.send(line)
        }
    }

    private func state(position: Double, paused: Bool, title: String = "Glass Lanterns (Official Audio)", source: String = "tab-17", videoId: String = "abc123XYZ00") -> String {
        """
        {"type":"state","source":"\(source)","reason":"test","track":{"title":"\(title)","artist":"The Paper Moths","album":"Night Market","videoId":"\(videoId)","artwork":[{"src":"https://lh3.googleusercontent.com/fake-art=w544-h544","sizes":"544x544"}]},"playback":{"position":\(position),"duration":200.2,"paused":\(paused),"rate":1,"ended":false},"tap":"active"}
        """
    }

    @Test func replayedSessionDrivesTrackLyricsAndWords() async throws {
        let port = try await startServer()
        defer { server.stop() }
        let client = FakeExtensionClient(port: port)
        defer { client.close() }

        try await replaySession(on: client)

        // hello → welcome
        let welcome = try await client.receiveText()
        #expect(welcome.contains("\"type\":\"welcome\""))
        #expect(welcome.contains("\"v\":1"))

        #expect(await waitUntil { engine.track?.title == "Glass Lanterns (Official Audio)" })
        #expect(engine.clients.values.contains { $0.client == "ytm-glow-extension" })
        #expect(engine.isPlaying)
        #expect(engine.tapStatus == .active)
        #expect(await waitUntil { engine.lyricsStatus.lyrics != nil })
        #expect(await waitUntil { engine.palette != nil })

        // Last state said position 10.0 → first line, first word.
        presenter.refresh()
        #expect(presenter.frame.isActive)
        #expect(presenter.frame.lineIndex == 0)
        #expect(presenter.frame.wordIndex == 0)
        #expect(presenter.frame.currentLine?.text == "Hang the glass lanterns over the river")

        // Words light up one at a time as the clock advances through the line.
        var seen: [Int] = []
        for _ in 0..<40 {
            clock.advance(0.1)
            presenter.refresh()
            if presenter.frame.lineIndex == 0, let word = presenter.frame.wordIndex { seen.append(word) }
        }
        #expect(seen == seen.sorted(), "word index never goes backwards")
        #expect(Set(seen).count == 7, "all seven words of line 1 light up")
        let mid = try #require(presenter.currentPosition())
        #expect(mid.wordProgress >= 0 && mid.wordProgress <= 1)

        // Into the second line (starts at 14.5).
        clock.advance(1.0) // position ≈ 15.0
        presenter.refresh()
        #expect(presenter.frame.lineIndex == 1)
        #expect(presenter.frame.previousLine?.text == "Hang the glass lanterns over the river")
        #expect(presenter.frame.nextLine?.text == "Hold the light till the morning delivers")
    }

    @Test func pauseFreezesAndSeekJumps() async throws {
        let port = try await startServer()
        defer { server.stop() }
        let client = FakeExtensionClient(port: port)
        defer { client.close() }
        try await replaySession(on: client)
        #expect(await waitUntil { engine.lyricsStatus.lyrics != nil })

        // Pause at 20.0: position must not advance.
        try await client.send(state(position: 20.0, paused: true))
        #expect(await waitUntil { engine.clock?.paused == true })
        clock.advance(30)
        #expect(engine.position() == 20.0)
        #expect(!engine.isPlaying)
        presenter.refresh()
        #expect(presenter.frame.isActive == false)
        #expect(presenter.frame.lineIndex == 2)

        // During the instrumental gap (23.4 → 30.0) no line is current.
        try await client.send(state(position: 27.0, paused: false))
        #expect(await waitUntil { engine.clock?.position == 27.0 })
        presenter.refresh()
        #expect(presenter.frame.lineIndex == nil)
        #expect(presenter.frame.nextLine?.text == "Paper moths in the summer weather")

        // Seek forward to 39.0 while playing.
        try await client.send(state(position: 39.0, paused: false))
        #expect(await waitUntil { engine.clock?.position == 39.0 })
        presenter.refresh()
        #expect(presenter.frame.isActive)
        #expect(presenter.frame.currentLine?.text == "We were never alone together")

        // Seek backwards to the first line.
        try await client.send(state(position: 11.0, paused: false))
        #expect(await waitUntil { engine.clock?.position == 11.0 })
        presenter.refresh()
        #expect(presenter.frame.lineIndex == 0)

        // Timing offset: +2 s shows lyrics later, so at 15.0 we're still on line 0.
        try await client.send(state(position: 15.0, paused: false))
        #expect(await waitUntil { engine.clock?.position == 15.0 })
        presenter.offset = 2
        #expect(presenter.frame.lineIndex == 0)
        presenter.offset = 0
        #expect(presenter.frame.lineIndex == 1)
    }

    @Test func levelsOnlyFromActiveSource() async throws {
        let port = try await startServer()
        defer { server.stop() }
        let client = FakeExtensionClient(port: port)
        defer { client.close() }

        var received: [LevelsMessage] = []
        engine.onLevels = { received.append($0) }
        try await replaySession(on: client)
        #expect(await waitUntil { received.count == 2 })
        #expect(received.first?.bass == 0.82)

        // A paused second tab's levels are ignored.
        try await client.send(state(position: 5, paused: true, title: "Other Song", source: "tab-99", videoId: "zzz"))
        try await client.send(#"{"type":"levels","source":"tab-99","bass":0.9,"mid":0.9,"high":0.9}"#)
        try await client.send(#"{"type":"levels","source":"tab-17","bass":0.5,"mid":0.2,"high":0.1}"#)
        #expect(await waitUntil { received.count == 3 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(received.count == 3)
        #expect(received.last?.bass == 0.5)
        #expect(engine.track?.title == "Glass Lanterns (Official Audio)")

        // When the other tab starts playing it becomes active, and stays
        // active even though both tabs keep reporting.
        clock.advance(1)
        try await client.send(state(position: 6, paused: false, title: "Other Song", source: "tab-99", videoId: "zzz"))
        #expect(await waitUntil { engine.track?.title == "Other Song" })
        try await client.send(state(position: 12, paused: false))
        try await client.send(state(position: 6.5, paused: false, title: "Other Song", source: "tab-99", videoId: "zzz"))
        try await client.send(state(position: 12.5, paused: false))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(engine.track?.title == "Other Song")

        // Closing that tab hands control back.
        try await client.send(#"{"type":"clear","source":"tab-99"}"#)
        #expect(await waitUntil { engine.track?.title == "Glass Lanterns (Official Audio)" })
    }

    @Test func reconnectRestoresState() async throws {
        let port = try await startServer()
        defer { server.stop() }

        let first = FakeExtensionClient(port: port)
        try await replaySession(on: first)
        #expect(await waitUntil { engine.isPlaying })

        // Browser quits / service worker dies.
        first.close()
        #expect(await waitUntil { engine.clients.isEmpty })
        #expect(engine.track == nil)
        #expect(!engine.isPlaying)
        presenter.refresh()
        #expect(presenter.frame.isActive == false)

        // Extension reconnects and resumes reporting.
        let second = FakeExtensionClient(port: port)
        defer { second.close() }
        try await second.send(#"{"type":"hello","v":1,"client":"ytm-glow-extension","version":"0.1.0"}"#)
        try await second.send(state(position: 40.0, paused: false))
        #expect(await waitUntil { engine.isPlaying && engine.clients.count == 1 })
        #expect(await waitUntil { engine.lyricsStatus.lyrics != nil })
        presenter.refresh()
        #expect(presenter.frame.currentLine?.text == "We were never alone together")
    }

    @Test func staleSourceStopsPlaying() async throws {
        engine.staleAfter = 0.3
        let port = try await startServer()
        defer { server.stop() }
        let client = FakeExtensionClient(port: port)
        defer { client.close() }
        try await client.send(state(position: 12, paused: false))
        #expect(await waitUntil { engine.isPlaying })
        clock.advance(1)
        #expect(await waitUntil(timeout: 2) { !engine.isPlaying })
        #expect(engine.track != nil, "track is kept; only playback is frozen")
    }

    @Test func webPageOriginsAreRejected() async throws {
        server.greetingTimeout = 1
        let port = try await startServer()
        defer { server.stop() }
        let intruder = FakeExtensionClient(port: port, origin: "https://evil.example")
        defer { intruder.close() }
        // The handshake is refused (HTTP 400), so the send fails or never completes.
        let message = state(position: 1, paused: false)
        await #expect(throws: (any Error).self) {
            try await withTimeout(1) { try await intruder.send(message) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(engine.track == nil)
        #expect(engine.clients.isEmpty)

        // A native client without Origin is fine.
        let native = FakeExtensionClient(port: port, origin: nil)
        defer { native.close() }
        try await native.send(#"{"type":"ping"}"#)
        #expect(try await native.receiveText() == #"{"type":"pong"}"#)
    }

    @Test func wantLevelsIsPushedToClients() async throws {
        let port = try await startServer()
        defer { server.stop() }
        let client = FakeExtensionClient(port: port)
        defer { client.close() }
        try await client.send(#"{"type":"hello","v":1}"#)
        #expect(try await client.receiveText().contains("\"wantLevels\":false"))
        server.setWantLevels(true)
        #expect(try await client.receiveText() == #"{"type":"config","wantLevels":true}"#)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
