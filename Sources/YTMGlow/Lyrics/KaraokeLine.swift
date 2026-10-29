import SwiftUI
import YTMGlowCore

/// Gap after a word: a space for spaced scripts, none inside CJK runs.
private struct WordGap: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Lays words out left-to-right, wrapping into centered rows.
struct WordFlow: Layout {
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment = .center
    /// Arabic and Hebrew lines flow right to left.
    var rightToLeft = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.maxX - row.width
            default: x = bounds.minX + (bounds.width - row.width) / 2
            }
            let items = rightToLeft ? Array(row.items.reversed()) : row.items
            for (offset, item) in items.enumerated() {
                subviews[item.index].place(at: CGPoint(x: x, y: y + row.height - item.size.height), proposal: ProposedViewSize(item.size))
                // In RTL rows the gap belongs to the word placed to the left's right-hand neighbor.
                let gap = rightToLeft ? (offset + 1 < items.count ? items[offset + 1].gap : 0) : item.gap
                x += item.size.width + gap
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize, gap: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let gap = subview[WordGap.self]
            let previousGap = row.items.last?.gap ?? 0
            if !row.items.isEmpty, row.width + previousGap + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            if !row.items.isEmpty { row.width += row.items[row.items.count - 1].gap }
            row.items.append((index, size, gap))
            row.width += size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        // The last word's gap doesn't count toward row width.
        return rows
    }
}

/// One lyric line whose words come alive as they are sung.
struct KaraokeLine: View {
    let line: LyricLine
    /// Words up to and including this index are lit.
    let litThrough: Int?
    let fontSize: CGFloat
    let highlight: Color
    var base: Color = .white.opacity(0.5)
    var weight: Font.Weight = .bold
    var alignment: HorizontalAlignment = .center
    var animation: LyricsAnimation = .lightUp
    /// Current lyric time; needed for the karaoke wipe.
    var time: (() -> Double?)?
    /// While false the wipe's frame clock stops, so a paused song costs nothing.
    var playing = true

    @State private var entered = false

    var body: some View {
        Group {
            if animation == .karaoke, let time {
                // The only mode that redraws every frame, and only while playing.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { _ in
                    words(fills: time().map(line.wordFills(at:)))
                }
            } else {
                words(fills: nil)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .onAppear { entered = true }
    }

    private func words(fills: [Double]?) -> some View {
        let rightToLeft = Self.isRightToLeft(line.text)
        let font = Font.system(size: fontSize, weight: weight, design: .rounded)
        return WordFlow(lineSpacing: fontSize * 0.12, alignment: alignment, rightToLeft: rightToLeft) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                let fill = fills.map { index < $0.count ? $0[index] : 0 }
                let lit = fill.map { $0 >= 1 } ?? (litThrough.map { index <= $0 } ?? false)
                let current = fill.map { $0 > 0 && $0 < 1 } ?? (litThrough == index)
                wordView(word.text, index: index, font: font, lit: lit, current: current, fill: fill, rightToLeft: rightToLeft)
                    .layoutValue(key: WordGap.self, value: word.spaceAfter ? fontSize * 0.27 : 0)
            }
        }
    }

    @ViewBuilder
    private func wordView(_ text: String, index: Int, font: Font, lit: Bool, current: Bool, fill: Double?, rightToLeft: Bool) -> some View {
        switch animation {
        case .lightUp:
            // Words switch on without interpolation: one composite per word.
            Text(text)
                .font(font)
                .foregroundStyle(lit ? highlight : base)
                .shadow(color: current ? highlight.opacity(0.8) : .clear, radius: fontSize * 0.3)
        case .pop:
            Text(text)
                .font(font)
                .foregroundStyle(lit ? highlight : base)
                .shadow(color: current ? highlight.opacity(0.85) : .clear, radius: fontSize * 0.35)
                .scaleEffect(current ? 1.05 : 1)
                .offset(y: current ? -fontSize * 0.14 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: current)
                .modifier(Entrance(entered: entered, index: index, fontSize: fontSize))
        case .karaoke:
            WipeText(text: text, font: font, fill: fill ?? (lit ? 1 : 0), highlight: highlight, base: base, rightToLeft: rightToLeft)
                .shadow(color: current ? highlight.opacity(0.75) : .clear, radius: fontSize * 0.3)
                .modifier(Entrance(entered: entered, index: index, fontSize: fontSize))
        }
    }

    /// True when the first strong letter is Hebrew or Arabic.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            default: return false
            }
        }
        return false
    }
}

/// New lines rise in word by word, slightly blurred, with a short stagger.
private struct Entrance: ViewModifier {
    let entered: Bool
    let index: Int
    let fontSize: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(entered ? 1 : 0)
            .offset(y: entered ? 0 : fontSize * 0.45)
            .blur(radius: entered ? 0 : fontSize * 0.12)
            .animation(.spring(response: 0.45, dampingFraction: 0.78).delay(Double(min(index, 14)) * 0.035), value: entered)
    }
}

/// A word whose highlight color sweeps across it as it's sung.
private struct WipeText: View {
    let text: String
    let font: Font
    /// 0…1 of the word sung.
    let fill: Double
    let highlight: Color
    let base: Color
    let rightToLeft: Bool

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(base)
            .overlay {
                Text(text)
                    .font(font)
                    .foregroundStyle(highlight)
                    .mask { mask }
            }
    }

    /// A soft-edged reveal so the sweep reads as light, not a hard cut.
    @ViewBuilder private var mask: some View {
        if fill <= 0 {
            Color.clear
        } else if fill >= 1 {
            Color.white
        } else {
            let edge = 0.1
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: max(0, fill - edge / 2)),
                .init(color: .clear, location: min(1, fill + edge / 2)),
                .init(color: .clear, location: 1),
            ], startPoint: rightToLeft ? .trailing : .leading, endPoint: rightToLeft ? .leading : .trailing)
        }
    }
}
