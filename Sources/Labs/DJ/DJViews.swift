import AppKit
import SwiftUI

// SparkV DJ drawer page: a turntable synced to Now Playing, presets and a
// 10-band EQ, and live stats (spectrum spikes on the beat, BPM, level).

enum DJLayout {
    /// Content height of the page (NotchMetrics adds header and padding).
    static let contentHeight: CGFloat = 168
    static let deckWidth: CGFloat = 146
    static let statsWidth: CGFloat = 150
    static let neon = Color(red: 0.36, green: 0.85, blue: 1.0)
    static let hot = Color(red: 1.0, green: 0.36, blue: 0.62)
}

struct DJDrawerView: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var dj = DJController.shared
    @ObservedObject private var settings = DJSettings.shared
    @StateObject private var page = DJPageState()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DJDeck(media: media)
                .frame(width: DJLayout.deckWidth)
            controls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            DJStatsPanel()
                .frame(width: DJLayout.statsWidth)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { dj.pageAppeared() }
        .onDisappear { dj.pageDisappeared() }
    }

    // MARK: Center column

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                DJPowerButton(isOn: dj.isOn, isStarting: dj.status == .starting) { dj.toggle() }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sound FX")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    statusLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                DJModeToggle(showsEQ: $page.showsEQ)
            }
            ZStack(alignment: .topLeading) {
                if page.showsEQ {
                    DJEqualizer(gains: dj.displayedGains, isCustom: settings.preset == .custom) { index, gain in
                        dj.setBand(index, gain: gain)
                    }
                    .transition(.opacity)
                } else {
                    presetGrid.transition(.opacity)
                }
            }
            .frame(height: 88, alignment: .top)
            .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small)), value: page.showsEQ)
            HStack(spacing: 8) {
                Image(systemName: "dial.low")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                Slider(value: $settings.intensity, in: 0...1)
                    .controlSize(.mini)
                    .help("Intensity: how strongly the preset applies")
                Text("\(Int((settings.intensity * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 30, alignment: .trailing)
                Button {
                    dj.isBypassed.toggle()
                } label: {
                    Text("A/B")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(dj.isBypassed ? SparkVTheme.warning.opacity(0.35) : SparkVTheme.surface))
                        .foregroundStyle(dj.isBypassed ? SparkVTheme.warning : SparkVTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!dj.isOn)
                .opacity(dj.isOn ? 1 : 0.4)
                .help(dj.isBypassed ? "Bypassed: you hear the original. Click to hear the effect." : "Compare: hear the original sound")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch dj.status {
        case .off:
            Text("Off · plays untouched")
                .font(.system(size: 9.5)).foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        case .starting:
            Text("Starting…")
                .font(.system(size: 9.5)).foregroundStyle(SparkVTheme.textSecondary)
        case .running:
            Text(runningText)
                .font(.system(size: 9.5)).foregroundStyle(DJLayout.neon.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
                .help(runningText)
        case .needsPermission:
            Button("Needs System Audio access…") { dj.openPermissionSettings() }
                .buttonStyle(.link)
                .font(.system(size: 9.5))
                .lineLimit(1).minimumScaleFactor(0.8)
                .help(dj.permissionHelp)
        case .failed(let text):
            Text(text)
                .font(.system(size: 9.5)).foregroundStyle(SparkVTheme.warning)
                .lineLimit(1).minimumScaleFactor(0.8)
                .help(text)
        }
    }

    private var runningText: String {
        let rate = dj.sampleRate > 0 ? String(format: "%.1f kHz", dj.sampleRate / 1000).replacingOccurrences(of: ".0 ", with: " ") : ""
        let parts = [dj.isBypassed ? "Bypassed" : settings.preset.title, dj.outputName, rate].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private var presetGrid: some View {
        let presets: [DJPreset] = [.flat, .bass, .vocal, .spatial, .concert, .club]
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(presets) { preset in
                DJPresetChip(preset: preset, isSelected: settings.preset == preset) { dj.choose(preset) }
            }
        }
    }
}

// MARK: - Power

/// Two small icon tabs: presets grid / 10-band EQ.
struct DJModeToggle: View {
    @Binding var showsEQ: Bool

    var body: some View {
        HStack(spacing: 2) {
            tab("square.grid.3x2.fill", selected: !showsEQ, help: "Presets") { showsEQ = false }
            tab("slider.vertical.3", selected: showsEQ, help: "10-band EQ") { showsEQ = true }
        }
        .padding(2)
        .background(Capsule().fill(SparkVTheme.surface))
        .fixedSize()
    }

    private func tab(_ symbol: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.black : SparkVTheme.textSecondary)
                .frame(width: 26, height: 20)
                .background(Capsule().fill(selected ? DJLayout.neon : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DJPowerButton: View {
    let isOn: Bool
    let isStarting: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn ? DJLayout.neon.opacity(0.22) : SparkVTheme.surface)
                Circle()
                    .strokeBorder(isOn ? DJLayout.neon : SparkVTheme.stroke, lineWidth: 1.2)
                if isStarting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isOn ? DJLayout.neon : SparkVTheme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            .shadow(color: isOn ? DJLayout.neon.opacity(0.6) : .clear, radius: 6)
            .scaleEffect(hover.isOn ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(isOn ? "Turn Sound FX off (the Mac plays untouched)" : "Turn Sound FX on: presets and EQ for everything the Mac plays")
        .accessibilityLabel(isOn ? "Sound effects on" : "Sound effects off")
    }
}

struct DJPresetChip: View {
    let preset: DJPreset
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(preset.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.black : SparkVTheme.text.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(LinearGradient(colors: [DJLayout.neon, DJLayout.hot.opacity(0.85)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(preset.help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Equalizer

struct DJEqualizer: View {
    let gains: [Float]
    let isCustom: Bool
    let onChange: (Int, Float) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<DJBands.count, id: \.self) { index in
                    DJBandSlider(gain: index < gains.count ? gains[index] : 0) { onChange(index, $0) }
                }
            }
            .frame(height: 74)
            HStack(spacing: 4) {
                ForEach(0..<DJBands.count, id: \.self) { index in
                    Text(DJBands.label(index))
                        .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            if !isCustom {
                Text("Drag a band to make it your own (Custom)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }
}

struct DJBandSlider: View {
    let gain: Float
    let onChange: (Float) -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let range = DJBands.range
            let fraction = CGFloat((gain - range.lowerBound) / (range.upperBound - range.lowerBound))
            let y = h * (1 - fraction)
            ZStack(alignment: .top) {
                Capsule().fill(SparkVTheme.surface).frame(width: 4)
                // Fill from the 0 dB line to the knob.
                let mid = h / 2
                Capsule()
                    .fill(gain >= 0 ? DJLayout.neon : DJLayout.hot)
                    .frame(width: 4, height: max(2, abs(y - mid)))
                    .offset(y: min(y, mid))
                Circle()
                    .fill(Color.white)
                    .frame(width: hover.isOn ? 11 : 9, height: hover.isOn ? 11 : 9)
                    .shadow(color: DJLayout.neon.opacity(0.5), radius: 3)
                    .offset(y: y - (hover.isOn ? 5.5 : 4.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let f = 1 - min(1, max(0, value.location.y / h))
                let raw = range.lowerBound + Float(f) * (range.upperBound - range.lowerBound)
                onChange((raw * 2).rounded() / 2)
            })
            .onTapGesture(count: 2) { onChange(0) }
        }
        .onHover { hover.isOn = $0 }
        .help(String(format: "%+.1f dB (double-click resets)", gain))
    }
}

// MARK: - Turntable

/// Page state (SwiftUI's @State macro isn't available with the Command
/// Line Tools, so small ObservableObjects hold view state).
final class DJPageState: ObservableObject {
    @Published var showsEQ = false
}

final class DJDeckState: ObservableObject {
    @Published var baseAngle: Double = 0
    @Published var spinStart: Date?
    @Published var scrub: Double = 0
    @Published var isScrubbing = false
    var lastDragAngle: Double = 0
}

struct DJDeck: View {
    @ObservedObject var media: MediaEngine
    @StateObject private var deck = DJDeckState()

    /// 33⅓ rpm.
    private static let degreesPerSecond = 360.0 * 33.333 / 60

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: deck.spinStart == nil || SparkVMotion.reduceMotion)) { context in
                    let angle = currentAngle(at: context.date)
                    DJDisc(artwork: media.artwork, tint: media.artworkTint.map { Color(nsColor: $0) } ?? DJLayout.neon,
                           angle: angle, isPlaying: media.isPlaying)
                }
                .frame(width: 118, height: 118)
                .gesture(scrubGesture)
                .help(media.timing.isKnown ? "Drag around the record to scrub" : "Now Playing")
                DJTonearm(onRecord: media.isPlaying || deck.isScrubbing)
                    .frame(width: 34, height: 92)
                    .offset(x: 12, y: -2)
                    .allowsHitTesting(false)
            }
            .frame(width: DJLayout.deckWidth, height: 120, alignment: .leading)
            Text(media.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            HStack(spacing: 14) {
                deckButton("backward.fill") { media.send(.previousTrack) }
                deckButton(media.isPlaying ? "pause.fill" : "play.fill", size: 14) { media.send(.togglePlayPause) }
                deckButton("forward.fill") { media.send(.nextTrack) }
            }
        }
        .onAppear { syncSpin(media.isPlaying) }
        .onChange(of: media.isPlaying) { _, playing in syncSpin(playing) }
    }

    private func deckButton(_ symbol: String, size: CGFloat = 11, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(SparkVTheme.text.opacity(0.9))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currentAngle(at date: Date) -> Double {
        let spun = deck.spinStart.map { date.timeIntervalSince($0) * Self.degreesPerSecond } ?? 0
        return deck.baseAngle + spun + deck.scrub
    }

    private func syncSpin(_ playing: Bool) {
        if playing, deck.spinStart == nil {
            deck.spinStart = Date()
        } else if !playing, let start = deck.spinStart {
            deck.baseAngle += Date().timeIntervalSince(start) * Self.degreesPerSecond
            deck.spinStart = nil
        }
    }

    /// Circular drag: the change in angle around the centre scrubs the
    /// track (one turn = 10 s), applied once on release.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard media.timing.isKnown else { return }
                let c = CGPoint(x: 59, y: 59)
                let angle = atan2(value.location.y - c.y, value.location.x - c.x) * 180 / .pi
                if !deck.isScrubbing {
                    deck.isScrubbing = true
                    deck.lastDragAngle = atan2(value.startLocation.y - c.y, value.startLocation.x - c.x) * 180 / .pi
                }
                var step = angle - deck.lastDragAngle
                if step > 180 { step -= 360 }
                if step < -180 { step += 360 }
                deck.lastDragAngle = angle
                deck.scrub += step
            }
            .onEnded { _ in
                defer { deck.isScrubbing = false }
                guard media.timing.isKnown else { deck.scrub = 0; return }
                let seconds = deck.scrub / 360 * 10
                let target = media.timing.position(at: Date()) + seconds
                deck.baseAngle += deck.scrub
                deck.scrub = 0
                media.seek(to: max(0, min(media.timing.duration - 1, target)))
            }
    }
}

struct DJDisc: View {
    let artwork: NSImage?
    let tint: Color
    let angle: Double
    let isPlaying: Bool

    var body: some View {
        ZStack {
            // Platter shadow and vinyl.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.13), Color(white: 0.04)], center: .center, startRadius: 4, endRadius: 60))
                .shadow(color: tint.opacity(isPlaying ? 0.45 : 0.15), radius: isPlaying ? 9 : 4)
            // Grooves.
            ForEach(0..<9, id: \.self) { ring in
                Circle()
                    .stroke(Color.white.opacity(ring.isMultiple(of: 3) ? 0.07 : 0.035), lineWidth: 0.6)
                    .padding(CGFloat(7 + ring * 4))
            }
            // Label: the album art, turning with the record.
            ZStack {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [tint, DJLayout.hot], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            // Spindle.
            Circle().fill(Color(white: 0.75)).frame(width: 5, height: 5)
            // A marker so the spin is visible on plain art.
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 2, height: 10)
                .offset(y: -44)
        }
        .rotationEffect(.degrees(angle))
        // Static sheen (a light reflection doesn't turn with the record).
        .overlay(
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.08), .clear, .clear, .white.opacity(0.05), .clear],
                                          center: .center))
                .allowsHitTesting(false)
        )
        .accessibilityHidden(true)
    }
}

struct DJTonearm: View {
    let onRecord: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Circle().fill(Color(white: 0.55)).frame(width: 12, height: 12)
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.8), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: 70)
                .offset(y: 6)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.7))
                .frame(width: 8, height: 12)
                .offset(x: -1, y: 72)
        }
        .rotationEffect(.degrees(onRecord ? 24 : 4), anchor: UnitPoint(x: 0.5, y: 0.07))
        .animation(SparkVMotion.respecting(.spring(duration: 0.7, bounce: 0.15)), value: onRecord)
        .accessibilityHidden(true)
    }
}

// MARK: - Stats

/// Keeps the falling peak caps and the beat flash between frames.
final class DJVisualState: ObservableObject {
    var caps = [Float](repeating: 0, count: DJStats.barCount)
    var flash: Float = 0
    var lastBeat: UInt64 = 0
    var lastTime: Double = 0
    var bpm: Float = 0
}

struct DJStatsPanel: View {
    @ObservedObject private var dj = DJController.shared
    @StateObject private var visual = DJVisualState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: dj.pump == nil)) { context in
            let stats = dj.pump?.mailbox.load() ?? .idle
            let flash = advance(stats, now: context.date.timeIntervalSinceReferenceDate)
            VStack(alignment: .leading, spacing: 6) {
                DJSpectrum(bars: stats.bars, caps: visual.caps, flash: flash)
                    .frame(height: 84)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Circle()
                        .fill(DJLayout.hot)
                        .frame(width: 7, height: 7)
                        .scaleEffect(CGFloat(0.7 + 0.8 * flash))
                        .opacity(Double(0.35 + 0.65 * flash))
                    Text(visual.bpm > 0 ? "\(Int(visual.bpm.rounded()))" : "—")
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                    Text("BPM")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                    Spacer(minLength: 0)
                    bandReadout(stats.features)
                }
                DJLevelMeter(level: stats.features.isSilent ? 0 : stats.features.level)
                    .frame(height: 6)
                Text(dj.pump == nil ? dj.statsIdleText : (stats.features.isSilent ? "Waiting for sound…" : "Live"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visual.bpm > 0 ? "Tempo about \(Int(visual.bpm)) beats per minute" : "Live audio stats")
    }

    private func bandReadout(_ f: AmbientAudioFeatures) -> some View {
        HStack(spacing: 2) {
            ForEach([("L", f.bass), ("M", f.mid), ("H", f.treble)], id: \.0) { item in
                VStack(spacing: 1) {
                    Capsule()
                        .fill(DJLayout.neon.opacity(0.25 + 0.75 * Double(item.1)))
                        .frame(width: 4, height: CGFloat(4 + 12 * item.1))
                        .frame(height: 16, alignment: .bottom)
                    Text(item.0).font(.system(size: 6.5, weight: .bold)).foregroundStyle(SparkVTheme.textTertiary)
                }
            }
        }
    }

    /// Updates caps / flash / bpm; returns the flash level (0…1).
    private func advance(_ stats: DJStats, now: Double) -> Float {
        let dt = Float(visual.lastTime == 0 ? 1.0 / 30 : min(0.1, now - visual.lastTime))
        visual.lastTime = now
        let f = stats.features
        if f.beatCount != visual.lastBeat {
            if visual.lastBeat != 0, !f.isSilent { visual.flash = 1 }
            visual.lastBeat = f.beatCount
        }
        visual.flash = max(0, visual.flash - dt * 4.5)
        if f.bpm > 0, f.tempoConfidence > 0.2 {
            visual.bpm = visual.bpm == 0 ? f.bpm : visual.bpm * 0.9 + f.bpm * 0.1
        } else if f.isSilent {
            visual.bpm = 0
        }
        for index in visual.caps.indices where index < stats.bars.count {
            let v = min(1, stats.bars[index] * (1 + 0.35 * visual.flash))
            visual.caps[index] = v > visual.caps[index] ? v : max(0, visual.caps[index] - dt * 0.7)
        }
        return visual.flash
    }
}

struct DJSpectrum: View {
    let bars: [Float]
    let caps: [Float]
    let flash: Float

    var body: some View {
        Canvas { context, size in
            let count = max(1, bars.count)
            let gap: CGFloat = 1.5
            let w = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let boost = 1 + 0.35 * CGFloat(flash)
            for index in 0..<count {
                let x = CGFloat(index) * (w + gap)
                // On the beat the bars spike, the low end most.
                let lowWeight = 1 - CGFloat(index) / CGFloat(count) * 0.6
                let v = min(1, CGFloat(bars[index]) * (1 + (boost - 1) * lowWeight))
                let h = max(2, v * size.height)
                let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                let gradient = Gradient(colors: [DJLayout.neon, DJLayout.hot])
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, w / 2)),
                             with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: size.height),
                                                   endPoint: CGPoint(x: 0, y: 0)))
                if index < caps.count {
                    let capY = size.height - max(2, CGFloat(caps[index]) * size.height) - 2
                    context.fill(Path(CGRect(x: x, y: capY, width: w, height: 1.5)),
                                 with: .color(.white.opacity(0.85)))
                }
            }
            // Floor glow that pulses on the beat.
            let glow = CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)
            context.fill(Path(glow), with: .color(DJLayout.hot.opacity(0.3 + 0.7 * Double(flash))))
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.03)))
    }
}

struct DJLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let segments = 18
            let lit = Int((Float(segments) * min(1, max(0, level))).rounded())
            HStack(spacing: 1.5) {
                ForEach(0..<segments, id: \.self) { index in
                    let color: Color = index >= segments - 3 ? .red : (index >= segments - 7 ? .yellow : .green)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < lit ? color.opacity(0.9) : Color.white.opacity(0.06))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Hub tile

/// Agents hub tile (Media): click opens the DJ page; the tile lights while
/// Sound FX is on.
struct DJHubTile: View {
    @ObservedObject private var dj = DJController.shared
    let onOpen: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: onOpen) {
            MPHubTileFace(title: "DJ", systemImage: "opticaldisc.fill", tint: DJLayout.neon,
                          isActive: dj.isOn, isHovered: hover.isOn)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .contextMenu {
            Button(dj.isOn ? "Turn Sound FX Off" : "Turn Sound FX On") { dj.toggle() }
            Divider()
            ForEach([DJPreset.flat, .bass, .vocal, .spatial, .concert, .club]) { preset in
                Button(preset.title) { dj.choose(preset) }
            }
        }
        .help("DJ: turntable, presets, EQ and live beat stats. Right-click for presets.")
        .accessibilityLabel(dj.isOn ? "DJ, sound effects on" : "DJ")
    }
}
