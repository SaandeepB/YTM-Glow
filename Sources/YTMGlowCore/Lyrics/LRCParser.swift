import Foundation

/// One timestamped line from an LRC file, before word timing is applied.
public struct LRCLine: Equatable, Sendable {
    public var time: Double
    public var text: String
    /// Word timings from enhanced LRC (`<mm:ss.xx>word`), if present.
    public var words: [LRCWord]?

    public init(time: Double, text: String, words: [LRCWord]? = nil) {
        self.time = time
        self.text = text
        self.words = words
    }
}

public struct LRCWord: Equatable, Sendable {
    public var time: Double
    public var text: String

    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }
}

public struct LRCDocument: Equatable, Sendable {
    /// Sorted by time, with any `[offset:]` tag already applied.
    public var lines: [LRCLine]
    public var metadata: [String: String]
}

/// Parser for line-synced LRC lyrics, including repeated timestamps
/// (`[00:10.00][01:20.00]chorus`), metadata tags, `[offset:±ms]`, and the
/// enhanced word-timing extension.
public enum LRCParser {
    public static func parse(_ source: String) -> LRCDocument {
        var lines: [LRCLine] = []
        var metadata: [String: String] = [:]

        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var times: [Double] = []

            // Consume leading [tag] groups.
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let body = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTimestamp(body) {
                    times.append(time)
                } else if let colon = body.firstIndex(of: ":") {
                    let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "#" }) {
                        metadata[key] = value
                    }
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }

            guard !times.isEmpty else { continue }
            let (text, words) = parseBody(String(rest))
            for time in times {
                lines.append(LRCLine(time: time, text: text, words: words.map { shift($0, by: time - (times.first ?? time)) }))
            }
        }

        if let offsetText = metadata["offset"], let offsetMs = Double(offsetText.replacingOccurrences(of: "+", with: "")) {
            // Positive offset means the lyrics should appear earlier.
            let shiftBy = -offsetMs / 1000
            lines = lines.map { line in
                var line = line
                line.time = max(0, line.time + shiftBy)
                line.words = line.words?.map { LRCWord(time: max(0, $0.time + shiftBy), text: $0.text) }
                return line
            }
        }

        // Stable sort keeps file order for identical timestamps.
        let sorted = lines.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
        return LRCDocument(lines: sorted, metadata: metadata)
    }

    /// Parses `mm:ss`, `mm:ss.xx`, `mm:ss.xxx`, or `mm:ss:xx`.
    public static func parseTimestamp<S: StringProtocol>(_ text: S) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0 else { return nil }

        var secondsPart = String(parts[1])
        var fraction = ""
        if parts.count == 3 {
            fraction = String(parts[2])
        } else if let dot = secondsPart.firstIndex(where: { $0 == "." || $0 == "," }) {
            fraction = String(secondsPart[secondsPart.index(after: dot)...])
            secondsPart = String(secondsPart[..<dot])
        }
        guard let seconds = Int(secondsPart), seconds >= 0, seconds < 60,
              fraction.allSatisfy(\.isASCIIDigit) else { return nil }
        let fractional = fraction.isEmpty ? 0 : (Double("0." + fraction) ?? 0)
        return Double(minutes) * 60 + Double(seconds) + fractional
    }

    /// Splits enhanced-LRC word tags out of a line body.
    private static func parseBody(_ body: String) -> (String, [LRCWord]?) {
        guard body.contains("<") else { return (body.trimmingCharacters(in: .whitespaces), nil) }

        var words: [LRCWord] = []
        var plain = ""
        var currentTime: Double?
        var currentText = ""
        var index = body.startIndex

        func flush() {
            if let time = currentTime {
                let text = currentText.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { words.append(LRCWord(time: time, text: text)) }
            }
            currentText = ""
        }

        while index < body.endIndex {
            if body[index] == "<", let close = body[index...].firstIndex(of: ">"),
               let time = parseTimestamp(body[body.index(after: index)..<close]) {
                flush()
                currentTime = time
                index = body.index(after: close)
                continue
            }
            currentText.append(body[index])
            plain.append(body[index])
            index = body.index(after: index)
        }
        flush()

        let text = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (text, words.isEmpty ? nil : words)
    }

    private static func shift(_ words: [LRCWord], by delta: Double) -> [LRCWord] {
        guard delta != 0 else { return words }
        return words.map { LRCWord(time: $0.time + delta, text: $0.text) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
