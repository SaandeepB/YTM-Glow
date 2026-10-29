import Foundation

/// An instrumental break between two sung lines.
public struct LyricGap: Equatable, Sendable {
    /// When the previous line finished (or the song started).
    public var start: Double
    /// When the next line starts.
    public var end: Double
    public var nextLineIndex: Int

    /// 0 at the start of the break, 1 when the next line begins.
    public func progress(at time: Double) -> Double {
        guard end > start else { return 1 }
        return min(1, max(0, (time - start) / (end - start)))
    }
}

extension LyricLine {
    /// How much of each word has been sung at `time`: 1 for sung words, a
    /// fraction for the word being sung, 0 for upcoming ones. Drives the
    /// left-to-right karaoke wipe.
    public func wordFills(at time: Double) -> [Double] {
        words.map { word in
            guard time > word.start else { return 0 }
            guard word.end > word.start else { return 1 }
            return min(1, (time - word.start) / (word.end - word.start))
        }
    }
}

extension Lyrics {
    public func wordFills(lineIndex: Int, at time: Double) -> [Double] {
        guard lines.indices.contains(lineIndex) else { return [] }
        return lines[lineIndex].wordFills(at: time)
    }

    /// The break `time` falls in, if it lasts at least `minimum` seconds.
    /// Used for the karaoke countdown before the next line.
    public func gap(at time: Double, minimum: Double = 3) -> LyricGap? {
        let position = locate(time)
        guard position.lineIndex == nil, let next = position.nextLineIndex else { return nil }
        let start = next > 0 ? lines[next - 1].end : 0
        let end = lines[next].start
        guard end - start >= minimum else { return nil }
        return LyricGap(start: start, end: end, nextLineIndex: next)
    }
}

/// A connected display, as far as choosing the karaoke screen is concerned.
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    /// Has the menu bar.
    public var isMain: Bool

    public init(id: UInt32, name: String, isMain: Bool) {
        self.id = id
        self.name = name
        self.isMain = isMain
    }
}

/// Chooses where the full-screen karaoke view goes.
public enum StageDisplayPicker {
    /// The preferred display if it's connected; otherwise ("automatic", or the
    /// preferred one was unplugged) the first display without the menu bar.
    /// Returns nil when only the main display exists and wasn't asked for, so
    /// the karaoke screen never covers your work by surprise.
    public static func pick(_ displays: [DisplayInfo], preferredID: UInt32?) -> DisplayInfo? {
        if let preferredID, preferredID != 0, let preferred = displays.first(where: { $0.id == preferredID }) {
            return preferred
        }
        return displays.first { !$0.isMain }
    }
}
