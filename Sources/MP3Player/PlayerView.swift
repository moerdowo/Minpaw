import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlayerView: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollTimer: Timer?

    var body: some View {
        WinampPanel(title: "MINPAW") {
            VStack(spacing: 4) {
                topRow
                visAndProgress
                transportRow
            }
            .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            TitleControls()
                .padding(.top, 2)
                .padding(.trailing, 4)
        }
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    PlayStateIcon(state: playState)
                    LCDDisplay(text: timeString,
                               color: Win.lcdGreen,
                               fontSize: 18,
                               alignment: .center)
                        .frame(width: 64, height: 22)
                }
                HStack(spacing: 2) {
                    StatusLED(label: "STEREO", on: isStereo)
                    StatusLED(label: "MONO",   on: !isStereo)
                }
            }
            ZStack {
                Win.lcdBg
                trackTicker
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .overlay(alignment: .bottomLeading) {
                kbpsKHzStrip
                    .padding(4)
            }
            .overlay(Bevel(pressed: true))
        }
    }

    private var trackTicker: some View {
        let displayText = trackDisplayText
        return GeometryReader { geo in
            HStack(spacing: 24) {
                Text(displayText)
                Text(displayText)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Win.lcdGreen)
            .shadow(color: Win.lcdGreen.opacity(0.55), radius: 1)
            .fixedSize()
            .offset(x: scrollOffset)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .onAppear { startScrolling() }
            .onChange(of: displayText) { _, _ in scrollOffset = 0 }
        }
    }

    private var kbpsKHzStrip: some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(spacing: 1) {
                Text("\(currentBitrate)")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Win.lcdGreen)
                    .shadow(color: Win.lcdGreen.opacity(0.55), radius: 1)
                Text("kbps")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Win.lcdGreenDim)
            }
            HStack(spacing: 1) {
                Text(currentSampleRateKHz)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Win.lcdGreen)
                    .shadow(color: Win.lcdGreen.opacity(0.55), radius: 1)
                Text("kHz")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(Win.lcdGreenDim)
            }
            Spacer()
        }
    }

    private var visAndProgress: some View {
        HStack(spacing: 6) {
            SpectrumBars(bands: player.spectrum)
                .frame(width: 76, height: 22)
            ProgressTrack()
                .frame(height: 10)
            PlasticButton("EQ", pressed: false, width: 22, height: 12) {}
                .opacity(0.55)
            PlasticButton("PL", pressed: false, width: 22, height: 12) {}
                .opacity(0.55)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 0) {
            PlasticButton(width: 22, height: 18, action: { player.previous() }) {
                TransportGlyph(.previous)
            }
            PlasticButton(width: 22, height: 18, action: { player.play() }) {
                TransportGlyph(.play)
            }
            PlasticButton(width: 22, height: 18, action: { player.pause() }) {
                TransportGlyph(.pause)
            }
            PlasticButton(width: 22, height: 18, action: { player.stop() }) {
                TransportGlyph(.stop)
            }
            PlasticButton(width: 22, height: 18, action: { player.next() }) {
                TransportGlyph(.next)
            }
            Spacer().frame(width: 4)
            PlasticButton(width: 22, height: 18, action: { openFiles() }) {
                TransportGlyph(.eject)
            }
            Spacer().frame(width: 8)
            VolumeKnob()
            BalanceKnob()
            Spacer()
            PlasticButton("SHUFFLE",
                          pressed: player.shuffle,
                          width: 50, height: 12) {
                player.shuffle.toggle()
            }
            PlasticButton("REPEAT",
                          pressed: player.repeatMode != .off,
                          width: 38, height: 12) {
                let modes = RepeatMode.allCases
                let i = modes.firstIndex(of: player.repeatMode) ?? 0
                player.repeatMode = modes[(i + 1) % modes.count]
            }
        }
    }

    // MARK: helpers

    private var playState: PlayStateIcon.State {
        if player.currentTrack == nil { return .stopped }
        return player.isPlaying ? .playing : .paused
    }

    private var timeString: String {
        let s = Int(max(0, player.currentTime))
        return String(format: "%2d:%02d", s / 60, s % 60)
    }

    private var trackDisplayText: String {
        guard let t = player.currentTrack else {
            return "MINPAW * REIMAGINED FOR MACOS"
        }
        let idx = (player.currentIndex ?? 0) + 1
        if let artist = t.artist, !artist.isEmpty {
            return "\(idx). \(artist) - \(t.title)"
        }
        return "\(idx). \(t.title)"
    }

    private var isStereo: Bool {
        player.currentTrack != nil
    }

    private var currentBitrate: Int {
        guard let t = player.currentTrack,
              let attrs = try? FileManager.default.attributesOfItem(atPath: t.url.path),
              let size = (attrs[.size] as? NSNumber)?.doubleValue,
              t.duration > 0 else { return 0 }
        return Int((size * 8 / 1000) / t.duration)
    }

    private var currentSampleRateKHz: String {
        guard player.currentTrack != nil else { return "00" }
        return "44"
    }

    private func startScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                scrollOffset -= 1
                if scrollOffset < -180 { scrollOffset = 0 }
            }
        }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let flac = UTType("org.xiph.flac") { types.append(flac) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK { player.addFiles(urls: panel.urls) }
    }
}

// MARK: - Transport glyphs

struct TransportGlyph: View {
    enum Kind { case previous, play, pause, stop, next, eject }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) * 0.55
            let cx = size.width / 2
            let cy = size.height / 2
            let color = GraphicsContext.Shading.color(.white.opacity(0.92))
            switch kind {
            case .play:
                var p = Path()
                p.move(to: CGPoint(x: cx - s/3, y: cy - s/2))
                p.addLine(to: CGPoint(x: cx + s/2, y: cy))
                p.addLine(to: CGPoint(x: cx - s/3, y: cy + s/2))
                p.closeSubpath()
                ctx.fill(p, with: color)
            case .pause:
                let bw: CGFloat = 2
                ctx.fill(Path(CGRect(x: cx - 4, y: cy - s/2, width: bw, height: s)), with: color)
                ctx.fill(Path(CGRect(x: cx + 2, y: cy - s/2, width: bw, height: s)), with: color)
            case .stop:
                ctx.fill(Path(CGRect(x: cx - s/2 + 1, y: cy - s/2 + 1, width: s - 2, height: s - 2)), with: color)
            case .previous:
                var p = Path()
                p.move(to: CGPoint(x: cx + s/2, y: cy - s/2))
                p.addLine(to: CGPoint(x: cx - s/4, y: cy))
                p.addLine(to: CGPoint(x: cx + s/2, y: cy + s/2))
                p.closeSubpath()
                ctx.fill(p, with: color)
                ctx.fill(Path(CGRect(x: cx - s/2, y: cy - s/2, width: 2, height: s)), with: color)
            case .next:
                var p = Path()
                p.move(to: CGPoint(x: cx - s/2, y: cy - s/2))
                p.addLine(to: CGPoint(x: cx + s/4, y: cy))
                p.addLine(to: CGPoint(x: cx - s/2, y: cy + s/2))
                p.closeSubpath()
                ctx.fill(p, with: color)
                ctx.fill(Path(CGRect(x: cx + s/2 - 2, y: cy - s/2, width: 2, height: s)), with: color)
            case .eject:
                var p = Path()
                p.move(to: CGPoint(x: cx, y: cy - s/2))
                p.addLine(to: CGPoint(x: cx + s/2, y: cy + s/8))
                p.addLine(to: CGPoint(x: cx - s/2, y: cy + s/8))
                p.closeSubpath()
                ctx.fill(p, with: color)
                ctx.fill(Path(CGRect(x: cx - s/2, y: cy + s/4, width: s, height: 2)), with: color)
            }
        }
    }
}

// MARK: - Play/pause/stop indicator beside time

struct PlayStateIcon: View {
    enum State { case playing, paused, stopped }
    let state: State
    var body: some View {
        ZStack {
            Win.lcdBg
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let s: CGFloat = 7
                let color = GraphicsContext.Shading.color(Win.lcdGreen)
                switch state {
                case .playing:
                    var p = Path()
                    p.move(to: CGPoint(x: cx - s/2, y: cy - s/2))
                    p.addLine(to: CGPoint(x: cx + s/2, y: cy))
                    p.addLine(to: CGPoint(x: cx - s/2, y: cy + s/2))
                    p.closeSubpath()
                    ctx.fill(p, with: color)
                case .paused:
                    ctx.fill(Path(CGRect(x: cx - 3, y: cy - 3, width: 2, height: 6)), with: color)
                    ctx.fill(Path(CGRect(x: cx + 1, y: cy - 3, width: 2, height: 6)), with: color)
                case .stopped:
                    ctx.fill(Path(CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)),
                             with: .color(Win.lcdGreen.opacity(0.18)))
                }
            }
        }
        .frame(width: 16, height: 22)
        .overlay(Bevel(pressed: true))
    }
}

// MARK: - Spectrum analyzer (Winamp-style green/yellow falling bars)

struct SpectrumBars: View {
    let bands: [Float]

    var body: some View {
        Canvas { ctx, size in
            let count = min(bands.count, 12)
            guard count > 0 else { return }
            let barW: CGFloat = floor(size.width / CGFloat(count)) - 1
            for i in 0..<count {
                let v = CGFloat(bands[i])
                let h = max(1, v * size.height)
                let x = CGFloat(i) * (barW + 1) + 1
                let segments = max(1, Int(h / 2))
                for s in 0..<segments {
                    let y = size.height - CGFloat(s) * 2 - 2
                    let normalized = CGFloat(s) / CGFloat(max(1, Int(size.height / 2)))
                    let color: Color
                    if normalized > 0.75 { color = Win.red }
                    else if normalized > 0.45 { color = Win.amber }
                    else { color = Win.lcdGreen }
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: barW, height: 1.5)),
                        with: .color(color)
                    )
                }
            }
        }
    }
}

// MARK: - Progress / scrubber bar

struct ProgressTrack: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var dragging = false
    @State private var dragVal: Double = 0

    var body: some View {
        GeometryReader { geo in
            let pct = max(0, min(1, (dragging ? dragVal : player.currentTime)
                                 / max(player.duration, 0.01)))
            let thumbW: CGFloat = 28
            let xRange = geo.size.width - thumbW
            ZStack(alignment: .leading) {
                Rectangle().fill(Win.eqTrack)
                    .overlay(Bevel(pressed: true))
                ZStack {
                    LinearGradient(
                        colors: [Win.faceLight, Win.face],
                        startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Win.bevelDark).frame(width: 1)
                }
                .frame(width: thumbW, height: geo.size.height)
                .overlay(Bevel())
                .offset(x: pct * xRange)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        let p = max(0, min(1, (v.location.x - thumbW/2) / xRange))
                        dragVal = p * player.duration
                    }
                    .onEnded { _ in
                        player.seek(to: dragVal)
                        dragging = false
                    }
            )
        }
    }
}

// MARK: - Volume / Balance compact horizontal sliders

struct VolumeKnob: View {
    @EnvironmentObject var player: PlayerEngine
    var body: some View {
        WinSlider(
            value: Binding(get: { Double(player.volume) },
                           set: { player.volume = Float($0) }),
            range: 0...1,
            fillTone: Win.lcdGreen,
            trackHeight: 6
        )
        .frame(width: 68, height: 14)
    }
}

struct BalanceKnob: View {
    @EnvironmentObject var player: PlayerEngine
    var body: some View {
        WinSlider(
            value: Binding(get: { Double(player.balance) },
                           set: { player.balance = Float($0) }),
            range: -1...1,
            fillTone: Win.lcdGreen,
            trackHeight: 6,
            showFill: false
        )
        .frame(width: 38, height: 14)
    }
}
