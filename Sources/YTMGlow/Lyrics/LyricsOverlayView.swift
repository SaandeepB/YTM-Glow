import AppKit
import SwiftUI
import YTMGlowCore

/// Appearance inputs that change rarely, kept apart from the per-word frame.
@MainActor
final class LyricsAppearance: ObservableObject {
    @Published var style: LyricsStyle = .beam
    @Published var highlight: SRGBColor = .init(r: 1, g: 0.82, b: 0.36)
    @Published var accent: SRGBColor = .init(r: 0.35, g: 0.78, b: 1)
    @Published var scale: Double = 1
    @Published var visible = false
    @Published var artwork: CGImage?
}

struct LyricsOverlayView: View {
    @ObservedObject var presenter: LyricsPresenter
    @ObservedObject var appearance: LyricsAppearance

    var body: some View {
        let frame = presenter.frame
        Group {
            switch appearance.style {
            case .beam: BeamStyle(frame: frame, appearance: appearance)
            case .cascade: CascadeStyle(frame: frame, appearance: appearance)
            case .capsule: CapsuleStyle(frame: frame, appearance: appearance)
            }
        }
        .opacity(appearance.visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: appearance.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Beam: one big line above the Dock, next line underneath.

private struct BeamStyle: View {
    let frame: LyricsFrame
    @ObservedObject var appearance: LyricsAppearance

    var body: some View {
        let s = appearance.scale
        VStack(spacing: 10 * s) {
            Spacer(minLength: 0)
            ZStack {
                if let line = frame.currentLine {
                    KaraokeLine(line: line, litThrough: frame.wordIndex, fontSize: 40 * s, highlight: appearance.highlight.swiftUI)
                        .id(frame.lineIndex)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
                } else if frame.nextLine != nil {
                    GapDots(color: appearance.highlight.swiftUI, size: 9 * s)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: frame.lineIndex)

            if let next = frame.nextLine {
                Text(next.text)
                    .font(.system(size: 19 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .id(frame.nextLineIndex)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 18)
    }
}

// MARK: - Cascade: previous / current / next on a frosted card.

private struct CascadeStyle: View {
    let frame: LyricsFrame
    @ObservedObject var appearance: LyricsAppearance

    var body: some View {
        let s = appearance.scale
        VStack(spacing: 12 * s) {
            Text(frame.previousLine?.text ?? " ")
                .font(.system(size: 17 * s, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .id("prev-\(frame.lineIndex ?? -1)")

            Group {
                if let line = frame.currentLine {
                    KaraokeLine(line: line, litThrough: frame.wordIndex, fontSize: 30 * s, highlight: appearance.highlight.swiftUI)
                        .id(frame.lineIndex)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                } else {
                    GapDots(color: appearance.highlight.swiftUI, size: 8 * s)
                        .frame(height: 30 * s)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.85), value: frame.lineIndex)

            Text(frame.nextLine?.text ?? " ")
                .font(.system(size: 17 * s, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .id("next-\(frame.nextLineIndex ?? -1)")
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 22 * s)
        .padding(.horizontal, 34 * s)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                VisualEffectBackground()
                LinearGradient(colors: [appearance.highlight.swiftUI.opacity(0.18), appearance.accent.swiftUI.opacity(0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26 * s, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26 * s, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [appearance.highlight.swiftUI.opacity(0.7), appearance.accent.swiftUI.opacity(0.5)],
                                                 startPoint: .leading, endPoint: .trailing), lineWidth: 1.2)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Capsule: compact pill under the menu bar.

private struct CapsuleStyle: View {
    let frame: LyricsFrame
    @ObservedObject var appearance: LyricsAppearance

    var body: some View {
        let s = appearance.scale
        HStack(spacing: 12 * s) {
            ArtworkBadge(image: appearance.artwork, colors: [appearance.highlight.swiftUI, appearance.accent.swiftUI], size: 26 * s)
            Group {
                if let line = frame.currentLine {
                    KaraokeLine(line: line, litThrough: frame.wordIndex, fontSize: 17 * s, highlight: appearance.highlight.swiftUI,
                                base: .white.opacity(0.55), weight: .semibold, alignment: .leading)
                        .id(frame.lineIndex)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    GapDots(color: appearance.highlight.swiftUI, size: 6 * s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.25), value: frame.lineIndex)
        }
        .padding(.vertical, 10 * s)
        .padding(.leading, 10 * s)
        .padding(.trailing, 20 * s)
        .background {
            ZStack {
                VisualEffectBackground(material: .hudWindow)
                Color.black.opacity(0.25)
            }
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(LinearGradient(colors: [appearance.highlight.swiftUI.opacity(0.8), appearance.accent.swiftUI.opacity(0.6)],
                                                      startPoint: .leading, endPoint: .trailing), lineWidth: 1)
            }
            .shadow(color: appearance.highlight.swiftUI.opacity(0.35), radius: 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
    }
}

// MARK: - Pieces

/// Three soft dots shown during instrumental gaps.
private struct GapDots: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.9) {
            ForEach(0..<3) { _ in
                Circle().fill(color.opacity(0.7)).frame(width: size, height: size)
            }
        }
        .shadow(color: color.opacity(0.6), radius: size)
    }
}

private struct ArtworkBadge: View {
    let image: CGImage?
    let colors: [Color]
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
    }
}

private struct RenderingPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering offscreen previews, where AppKit blur can't be captured.
    var isRenderingPreview: Bool {
        get { self[RenderingPreviewKey.self] }
        set { self[RenderingPreviewKey.self] = newValue }
    }
}

/// Behind-window blur that stays active while the app is in the background.
struct VisualEffectBackground: View {
    var material: NSVisualEffectView.Material = .hudWindow
    @Environment(\.isRenderingPreview) private var isRenderingPreview

    var body: some View {
        if isRenderingPreview {
            Color(white: 0.12).opacity(0.72)
        } else {
            BlurView(material: material)
        }
    }
}

private struct BlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
