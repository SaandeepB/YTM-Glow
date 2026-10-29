import Foundation

public struct LyricWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Whether a space follows this word when the line is rendered.
    public var spaceAfter: Bool

    public init(text: String, start: Double, end: Double, spaceAfter: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.spaceAfter = spaceAfter
    }
}

public struct LyricLine: Equatable, Sendable {
    public var text: String
    public var start: Double
    /// When the line stops being "current". Usually the next line's start;
    /// earlier when a long instrumental gap follows.
    public var end: Double
    public var words: [LyricWord]

    public init(text: String, start: Double, end: Double, words: [LyricWord]) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

/// Where playback is within the lyrics.
public struct LyricPosition: Equatable, Sendable {
    /// The line being sung, or nil before the first line or during a gap.
    public var lineIndex: Int?
    /// The latest word whose start has passed within `lineIndex`.
    public var wordIndex: Int?
    /// 0…1 progress through `wordIndex`.
    public var wordProgress: Double
    /// The next line to be sung.
    public var nextLineIndex: Int?

    public init(lineIndex: Int?, wordIndex: Int?, wordProgress: Double, nextLineIndex: Int?) {
        self.lineIndex = lineIndex
        self.wordIndex = wordIndex
        self.wordProgress = wordProgress
        self.nextLineIndex = nextLineIndex
    }
}

public struct Lyrics: Equatable, Sendable {
    public var lines: [LyricLine]
    /// True when word times were estimated from line times (plain LRC).
    public var wordTimingEstimated: Bool

    public init(lines: [LyricLine], wordTimingEstimated: Bool) {
        self.lines = lines
        self.wordTimingEstimated = wordTimingEstimated
    }

    /// Builds timed lyrics from LRC text. Returns nil when there are no timed lines.
    public init?(lrc: String, songDuration: Double? = nil) {
        let document = LRCParser.parse(lrc)
        let lines = WordTimingEstimator.build(document.lines, songDuration: songDuration)
        guard !lines.isEmpty else { return nil }
        self.init(lines: lines, wordTimingEstimated: !document.lines.contains { $0.words != nil })
    }

    public func locate(_ time: Double) -> LyricPosition {
        // Last line whose start <= time.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        let candidate = low - 1
        guard candidate >= 0 else {
            return LyricPosition(lineIndex: nil, wordIndex: nil, wordProgress: 0, nextLineIndex: lines.isEmpty ? nil : 0)
        }
        let next = candidate + 1 < lines.count ? candidate + 1 : nil
        let line = lines[candidate]
        guard time < line.end else {
            return LyricPosition(lineIndex: nil, wordIndex: nil, wordProgress: 0, nextLineIndex: next)
        }

        guard let wordIndex = line.words.lastIndex(where: { $0.start <= time }) else {
            return LyricPosition(lineIndex: candidate, wordIndex: nil, wordProgress: 0, nextLineIndex: next)
        }
        let word = line.words[wordIndex]
        let span = word.end - word.start
        let progress = span > 0 ? min(1, max(0, (time - word.start) / span)) : 1
        return LyricPosition(lineIndex: candidate, wordIndex: wordIndex, wordProgress: progress, nextLineIndex: next)
    }

    /// The first moment after `time` at which `locate` may change its line or word.
    public func nextBoundary(after time: Double) -> Double? {
        var best: Double?
        func consider(_ value: Double) {
            if value > time, best == nil || value < best! { best = value }
        }
        let position = locate(time)
        if let lineIndex = position.lineIndex {
            let line = lines[lineIndex]
            consider(line.end)
            if let wordIndex = position.wordIndex {
                if wordIndex + 1 < line.words.count { consider(line.words[wordIndex + 1].start) }
            } else if let first = line.words.first {
                consider(first.start)
            }
        }
        if let next = position.nextLineIndex { consider(lines[next].start) }
        return best
    }
}
