import CoreGraphics
import Foundation
@testable import YTMGlowCore

/// Manually advanced monotonic clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(_ start: TimeInterval = 1000) { current = start }

    var value: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }

    var closure: MonotonicClock { { [unowned self] in self.value } }
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return url
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    /// Non-empty, non-comment lines of a .jsonl file.
    static func jsonLines(_ name: String) throws -> [String] {
        try text(name)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("//") }
    }

    enum FixtureError: Error { case missing(String) }
}

struct FakeLyricsProvider: LyricsProviding {
    var lrcByTitle: [String: String]

    func lyrics(title: String, artist: String, album: String?, duration: Double?, script: LyricsScript?) async -> LyricsOutcome {
        guard let lrc = lrcByTitle[title], let lyrics = Lyrics(lrc: lrc, songDuration: duration) else { return .notFound }
        return .synced(lyrics)
    }
}

struct FakeArtworkProvider: ArtworkProviding {
    var palette: Palette

    func load(_ url: URL) async -> (image: CGImage, palette: Palette?)? {
        guard let image = TestImages.solid(SRGBColor(r: 1, g: 0, b: 0), edge: 4) else { return nil }
        return (image, palette)
    }
}

enum TestImages {
    /// Draws colored rectangles into an sRGB bitmap. `regions` are fractions of the image.
    static func make(edge: Int, background: SRGBColor, regions: [(CGRect, SRGBColor)] = []) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func fill(_ rect: CGRect, _ color: SRGBColor) {
            context.setFillColor(CGColor(colorSpace: space, components: [color.r, color.g, color.b, 1])!)
            context.fill(CGRect(x: rect.minX * CGFloat(edge), y: rect.minY * CGFloat(edge),
                                width: rect.width * CGFloat(edge), height: rect.height * CGFloat(edge)))
        }
        fill(CGRect(x: 0, y: 0, width: 1, height: 1), background)
        for (rect, color) in regions { fill(rect, color) }
        return context.makeImage()
    }

    static func solid(_ color: SRGBColor, edge: Int) -> CGImage? {
        make(edge: edge, background: color)
    }
}

/// Polls `condition` on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Minimal stand-in for the browser extension's service worker.
final class FakeExtensionClient: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let session: URLSession

    init(port: UInt16, origin: String? = "chrome-extension://abcdefghijklmnopabcdefghijklmnop") {
        session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ytm-glow/v1")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText(timeout: TimeInterval = 3) async throws -> String {
        try await withTimeout(timeout) {
            switch try await self.task.receive() {
            case let .string(text): return text
            case let .data(data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Runs `operation`, throwing `URLError(.timedOut)` if it takes longer than `seconds`.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
