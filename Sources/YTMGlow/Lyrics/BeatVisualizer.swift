import SwiftUI
import YTMGlowCore

/// Mirrored equalizer bars that pulse with the music, shown where lyrics
/// would be when a song has none. Redraws at up to 30 fps while playing and
/// stops completely while paused or hidden.
struct BeatVisualizer: View {
    let meter: BeatMeter
    let playing: Bool
    let highlight: Color
    let accent: Color
    var barCount = 25
    var height: CGFloat = 64
    var barWidth: CGFloat = 8
    var spacing: CGFloat = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
            let state = meter.current()
            let heights = VisualizerBars.heights(count: barCount, state: state, time: context.date.timeIntervalSinceReferenceDate)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(colors: [accent, highlight], startPoint: .bottom, endPoint: .top))
                        .frame(width: barWidth, height: max(barWidth, height * heights[index]))
                }
            }
            .frame(height: height)
            .shadow(color: highlight.opacity(0.3 + 0.5 * state.pulse), radius: barWidth * (0.8 + 1.6 * state.pulse))
        }
    }
}

/// What the overlays say under the visualizer.
enum BeatCaption {
    static func status(_ lyrics: PlayerEngine.LyricsStatus) -> String {
        switch lyrics {
        case .instrumental: return "Instrumental"
        case .plainOnly: return "No synced lyrics"
        case .failed: return "Lyrics offline"
        default: return "No lyrics"
        }
    }
}
