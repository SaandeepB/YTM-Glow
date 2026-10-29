import SwiftUI
import YTMGlowCore

/// Everything in the menu bar popover.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: PlayerEngine
    var extensionSetup: ExtensionSetup
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(engine: engine)
            NowPlayingCard(engine: engine)
            GlowSection(settings: settings, engine: engine)
            LyricsSection(settings: settings, engine: engine)
            GeneralSection(extensionSetup: extensionSetup, onQuit: onQuit)
        }
        .padding(16)
        .frame(width: 360)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Header & now playing

private struct Header: View {
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.78), Color(red: 0.35, green: 0.78, blue: 1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
                .frame(width: 22, height: 18)
                .shadow(color: Color(red: 1, green: 0.36, blue: 0.78).opacity(0.6), radius: 4)
            Text("YTM Glow").font(.headline)
            Spacer()
            StatusPill(text: statusText, color: statusColor)
        }
    }

    private var statusText: String {
        switch engine.bridgeStatus {
        case .starting: return "Starting…"
        case .failed: return "Bridge error"
        case .listening: return engine.isConnected ? "Connected" : "Waiting for browser"
        }
    }

    private var statusColor: Color {
        switch engine.bridgeStatus {
        case .failed: return .red
        case .starting: return .gray
        case .listening: return engine.isConnected ? .green : .orange
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }
}

private struct NowPlayingCard: View {
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let art = engine.artwork {
                    Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: paletteColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8)))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.track?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(engine.track?.artist ?? hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(lyricsText, systemImage: "quote.bubble").lineLimit(1)
                    Label(beatText, systemImage: "waveform").lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
    }

    private var paletteColors: [Color] {
        let (a, b) = engine.palette?.glowColors ?? ThemeColors.fallbackGlow
        return [a.swiftUI, b.swiftUI]
    }

    private var hint: String {
        if case let .failed(message) = engine.bridgeStatus { return message }
        return engine.isConnected ? "Play something in YouTube Music" : "Open music.youtube.com in Chrome"
    }

    private var lyricsText: String {
        switch engine.lyricsStatus {
        case .idle: return "Lyrics —"
        case .loading: return "Finding lyrics…"
        case .synced: return "Synced lyrics"
        case .plainOnly: return "No synced lyrics"
        case .instrumental: return "Instrumental"
        case .notFound: return "No lyrics found"
        case .failed: return "Lyrics offline"
        }
    }

    private var beatText: String {
        switch engine.tapStatus {
        case .active: return "Beat sync"
        case .pending: return "Click the YTM tab"
        case .failed: return "Steady (no audio tap)"
        case .off, nil: return "Steady"
        }
    }
}

// MARK: - Sections

private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                Label(title, systemImage: systemImage).font(.system(size: 13, weight: .semibold))
            }
            if isOn {
                VStack(alignment: .leading, spacing: 9) { content }
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

private struct GlowSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        SectionCard(title: "Edge glow", systemImage: "rectangle.dashed", isOn: $settings.glowEnabled) {
            Picker("Mode", selection: $settings.glowMode) {
                ForEach(GlowMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LabeledSlider(title: "Thickness", value: $settings.glowThickness, range: 8...160, format: { "\(Int($0)) pt" })
            LabeledSlider(title: "Intensity", value: $settings.glowIntensity, range: 0.1...1, format: { "\(Int($0 * 100))%" })

            ColorSourceRow(source: $settings.glowColorSource) {
                HexColorWell(hex: $settings.glowCustomA)
                HexColorWell(hex: $settings.glowCustomB)
            }
        }
    }
}

private struct LyricsSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        SectionCard(title: "Lyrics", systemImage: "music.mic", isOn: $settings.lyricsEnabled) {
            Picker("Style", selection: $settings.lyricsStyle) {
                ForEach(LyricsStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ColorSourceRow(source: $settings.lyricsColorSource) {
                HexColorWell(hex: $settings.lyricsCustomColor)
            }

            LabeledSlider(title: "Size", value: $settings.lyricsScale, range: 0.7...1.6, format: { String(format: "%.0f%%", $0 * 100) })

            HStack(spacing: 6) {
                Text("Timing").frame(width: 64, alignment: .leading)
                Button { settings.lyricsOffset = max(-5, settings.lyricsOffset - 0.1) } label: { Image(systemName: "minus") }
                Text(offsetText).monospacedDigit().frame(minWidth: 56)
                Button { settings.lyricsOffset = min(5, settings.lyricsOffset + 0.1) } label: { Image(systemName: "plus") }
                Spacer()
                Button("Reset") { settings.lyricsOffset = 0 }.disabled(settings.lyricsOffset == 0)
            }
            .font(.caption)

            if case .failed = engine.lyricsStatus {
                Button("Retry lyrics lookup") { engine.retryLyrics() }.font(.caption)
            }
        }
    }

    private var offsetText: String {
        let rounded = (settings.lyricsOffset * 10).rounded() / 10
        if rounded == 0 { return "0.0 s" }
        return String(format: "%+.1f s", rounded)
    }
}

private struct GeneralSection: View {
    var extensionSetup: ExtensionSetup
    var onQuit: () -> Void

    var body: some View {
        HStack {
            Button {
                extensionSetup.revealExtension()
            } label: {
                Label("Browser extension…", systemImage: "puzzlepiece.extension")
            }
            .help("Copies the Chrome extension to a stable folder and shows it in Finder. Load it from chrome://extensions → Load unpacked.")
            Spacer()
            Button("Quit", action: onQuit)
        }
        .font(.caption)
    }
}

// MARK: - Controls

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
        .font(.caption)
    }
}

private struct ColorSourceRow<Wells: View>: View {
    @Binding var source: ColorSource
    @ViewBuilder var wells: Wells

    var body: some View {
        HStack(spacing: 8) {
            Text("Colors").frame(width: 64, alignment: .leading)
            Picker("Colors", selection: $source) {
                ForEach(ColorSource.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            if source == .custom { wells }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}

/// Color well bound to a "#RRGGBB" string.
private struct HexColorWell: View {
    @Binding var hex: String

    var body: some View {
        ColorPicker("", selection: Binding(
            get: { (SRGBColor(hex: hex) ?? SRGBColor(r: 1, g: 1, b: 1)).swiftUI },
            set: { hex = SRGBColor($0).hex }
        ), supportsOpacity: false)
        .labelsHidden()
        .frame(width: 34)
    }
}
