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

/// One lyric line whose words light up as they are sung.
struct KaraokeLine: View {
    let line: LyricLine
    /// Words up to and including this index are lit.
    let litThrough: Int?
    let fontSize: CGFloat
    let highlight: Color
    var base: Color = .white.opacity(0.5)
    var weight: Font.Weight = .bold
    var alignment: HorizontalAlignment = .center

    var body: some View {
        WordFlow(lineSpacing: fontSize * 0.12, alignment: alignment, rightToLeft: Self.isRightToLeft(line.text)) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                let lit = litThrough.map { index <= $0 } ?? false
                let current = litThrough == index
                // Words switch on without interpolation: each change is one
                // composite, instead of a run of animation frames per word.
                Text(word.text)
                    .font(.system(size: fontSize, weight: weight, design: .rounded))
                    .foregroundStyle(lit ? highlight : base)
                    .shadow(color: current ? highlight.opacity(0.8) : .clear, radius: fontSize * 0.3)
                    .layoutValue(key: WordGap.self, value: word.spaceAfter ? fontSize * 0.27 : 0)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
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
