import SwiftUI
import YTMGlowCore

/// The karaoke screen: blurred album art, a beat-reactive bloom, and lyrics
/// sized for reading across a room, with the current line swept word by word.
struct StageView: View {
    @ObservedObject var presenter: LyricsPresenter
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var appearance: LyricsAppearance
    let stage: StageModel
    var onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            // Designed at 1080 p; scales with the display.
            let s = max(0.6, min(geometry.size.height / 1080, 2.4))
            ZStack {
                StageBackdrop(artwork: engine.artwork, highlight: appearance.highlight.swiftUI, accent: appearance.accent.swiftUI,
                              stage: stage, scale: s)
                content(scale: s)
                    .padding(.horizontal, 140 * s)
                if hovering {
                    closeButton(scale: s)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: hovering)
    }

    @ViewBuilder
    private func content(scale s: CGFloat) -> some View {
        let frame = presenter.frame
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let lyrics = frame.lyrics {
                lyricsStack(frame: frame, lyrics: lyrics, scale: s)
            } else {
                NoLyricsCard(engine: engine, highlight: appearance.highlight.swiftUI, scale: s)
            }
            Spacer(minLength: 0)
            StageFooter(engine: engine, highlight: appearance.highlight.swiftUI, accent: appearance.accent.swiftUI,
                        paused: !(engine.clock?.isPlaying ?? false), scale: s)
                .padding(.bottom, 56 * s)
        }
    }

    @ViewBuilder
    private func lyricsStack(frame: LyricsFrame, lyrics: Lyrics, scale s: CGFloat) -> some View {
        let afterNext = frame.nextLineIndex.flatMap { $0 + 1 < lyrics.lines.count ? lyrics.lines[$0 + 1] : nil }
        VStack(spacing: 34 * s) {
            Text(frame.previousLine?.text ?? " ")
                .font(.system(size: 30 * s, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(2)
                .id("prev-\(frame.lineIndex ?? frame.nextLineIndex ?? -1)")
                .transition(.opacity)

            ZStack {
                if let line = frame.currentLine {
                    KaraokeLine(line: line, litThrough: frame.wordIndex, fontSize: 78 * s, highlight: appearance.highlight.swiftUI,
                                base: .white.opacity(0.42), weight: .heavy, animation: .karaoke, time: presenter.lyricTime,
                                playing: frame.isActive)
                        .id(frame.lineIndex)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: -40 * s)).combined(with: .scale(scale: 0.92))))
                } else {
                    GapCountdown(lyrics: lyrics, time: presenter.lyricTime, playing: frame.isActive, color: appearance.highlight.swiftUI, scale: s)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 200 * s)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: frame.lineIndex)

            VStack(spacing: 18 * s) {
                Text(frame.nextLine?.text ?? " ")
                    .font(.system(size: 42 * s, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                Text(afterNext?.text ?? " ")
                    .font(.system(size: 30 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .lineLimit(2)
            .id("next-\(frame.nextLineIndex ?? -1)")
            .transition(.opacity.combined(with: .offset(y: 20 * s)))
            .animation(.easeOut(duration: 0.35), value: frame.nextLineIndex)
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.35), radius: 6 * s, y: 2 * s)
    }

    private func closeButton(scale s: CGFloat) -> some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Label("Close karaoke screen (Esc)", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18 * s, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44 * s, height: 44 * s)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .help("Close the karaoke screen (Esc)")
            }
            Spacer()
        }
        .padding(28 * s)
        .transition(.opacity)
    }
}

// MARK: - Backdrop

private struct StageBackdrop: View {
    let artwork: CGImage?
    let highlight: Color
    let accent: Color
    let stage: StageModel
    let scale: CGFloat

    var body: some View {
        ZStack {
            // In an overlay so the square art can't grow the layout past the screen.
            Color.black.overlay {
                if let artwork {
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 90 * scale)
                        .scaleEffect(1.35)
                        .opacity(0.55)
                }
            }
            LinearGradient(colors: [highlight.opacity(0.32), .clear, accent.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
            BeatBloom(stage: stage, color: highlight, scale: scale)
            // Keep the text area readable on bright art.
            RadialGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], center: .center, startRadius: 200 * scale, endRadius: 1300 * scale)
        }
        .clipped()
        .drawingGroup()
    }
}

/// A soft glow behind the lyrics that swells on the beat. Isolated so the
/// ~20 Hz pulse redraws only this layer.
private struct BeatBloom: View {
    @ObservedObject var stage: StageModel
    let color: Color
    let scale: CGFloat

    var body: some View {
        RadialGradient(colors: [color.opacity(0.08 + 0.32 * stage.pulse), .clear], center: .center,
                       startRadius: 0, endRadius: (700 + 260 * stage.pulse) * scale)
    }
}

// MARK: - Countdown, footer, no lyrics

/// Instrumental break: dots fill toward the next line, karaoke-style.
private struct GapCountdown: View {
    let lyrics: Lyrics
    let time: () -> Double?
    let playing: Bool
    let color: Color
    let scale: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { _ in
            let now = time() ?? 0
            let gap = lyrics.gap(at: now)
            let progress = gap?.progress(at: now) ?? 0
            HStack(spacing: 26 * scale) {
                ForEach(0..<4) { dot in
                    let fill = min(1, max(0, progress * 4 - Double(dot)))
                    Circle()
                        .fill(color.opacity(0.18 + 0.82 * fill))
                        .frame(width: 26 * scale, height: 26 * scale)
                        .scaleEffect(0.8 + 0.3 * fill)
                        .shadow(color: color.opacity(0.8 * fill), radius: 16 * scale)
                }
            }
            .opacity(gap == nil ? 0.5 : 1)
        }
    }
}

private struct StageFooter: View {
    @ObservedObject var engine: PlayerEngine
    let highlight: Color
    let accent: Color
    let paused: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 22 * s) {
            Group {
                if let art = engine.artwork {
                    Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [highlight, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 72 * s, height: 72 * s)
            .clipShape(RoundedRectangle(cornerRadius: 12 * s, style: .continuous))

            VStack(alignment: .leading, spacing: 6 * s) {
                HStack(spacing: 12 * s) {
                    Text(engine.track?.title ?? "")
                        .font(.system(size: 26 * s, weight: .bold, design: .rounded))
                    if paused {
                        Text("Paused")
                            .font(.system(size: 15 * s, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10 * s)
                            .padding(.vertical, 3 * s)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    }
                }
                Text(engine.track?.artist ?? "")
                    .font(.system(size: 20 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                // Twice a second is plenty for a progress bar.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ProgressStrip(position: engine.position() ?? 0, duration: engine.clock?.duration, highlight: highlight, accent: accent, scale: s)
                }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .frame(maxWidth: 1100 * s)
    }
}

private struct ProgressStrip: View {
    let position: Double
    let duration: Double?
    let highlight: Color
    let accent: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 12 * scale) {
            Text(Self.format(position)).monospacedDigit()
            GeometryReader { geometry in
                let fraction = duration.map { $0 > 0 ? min(1, position / $0) : 0 } ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(LinearGradient(colors: [highlight, accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6 * scale)
            Text(duration.map(Self.format) ?? "–:––").monospacedDigit()
        }
        .font(.system(size: 15 * scale, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.6))
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct NoLyricsCard: View {
    @ObservedObject var engine: PlayerEngine
    let highlight: Color
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 28 * scale) {
            if let art = engine.artwork {
                Image(decorative: art, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 320 * scale, height: 320 * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 28 * scale, style: .continuous))
                    .shadow(color: highlight.opacity(0.5), radius: 40 * scale)
            }
            Text(engine.track?.title ?? "")
                .font(.system(size: 56 * scale, weight: .heavy, design: .rounded))
            Text(message)
                .font(.system(size: 24 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
    }

    private var message: String {
        switch engine.lyricsStatus {
        case .loading, .idle: return "Finding lyrics…"
        case .instrumental: return "Instrumental"
        case .plainOnly: return "No synced lyrics for this track"
        case .notFound: return "No lyrics found"
        case .failed: return "Lyrics are offline"
        case .synced: return ""
        }
    }
}
