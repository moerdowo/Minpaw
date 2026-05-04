import SwiftUI
import AppKit

// MARK: - Classic Winamp palette

enum Win {
    static let face         = Color(hex: 0x2A2A2A)
    static let faceDark     = Color(hex: 0x1E1E1E)
    static let faceLight    = Color(hex: 0x3D3D3D)

    static let titleBar1    = Color(hex: 0x1B3550)  // active title gradient top
    static let titleBar2    = Color(hex: 0x0F1F30)  // active title gradient bottom
    static let titleText    = Color(hex: 0x6F94B7)  // dim blue-gray italic

    static let lcdBg        = Color(hex: 0x000000)
    static let lcdGreen     = Color(hex: 0x1FE83C)
    static let lcdGreenDim  = Color(hex: 0x0E5C19)
    static let amber        = Color(hex: 0xFFC811)
    static let amberDim     = Color(hex: 0x6E5400)
    static let red          = Color(hex: 0xFF3939)

    static let bevelLight   = Color(hex: 0x747474)
    static let bevelMid     = Color(hex: 0x4A4A4A)
    static let bevelDark    = Color(hex: 0x000000)
    static let separator    = Color(hex: 0x141414)

    static let eqYellow     = Color(hex: 0xFFEF65)
    static let eqYellowDark = Color(hex: 0x9C8A1B)
    static let eqTrack      = Color(hex: 0x102A38)
}

// MARK: - Bevel overlay (Win95 raised/recessed look)

struct Bevel: View {
    var pressed: Bool = false
    var lightColor: Color? = nil
    var darkColor: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let light = lightColor ?? (pressed ? Win.bevelDark : Win.bevelLight)
            let dark  = darkColor  ?? (pressed ? Win.bevelLight : Win.bevelDark)
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0.5, y: h))
                    p.addLine(to: CGPoint(x: 0.5, y: 0.5))
                    p.addLine(to: CGPoint(x: w, y: 0.5))
                }.stroke(light, lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: w - 0.5, y: 0))
                    p.addLine(to: CGPoint(x: w - 0.5, y: h - 0.5))
                    p.addLine(to: CGPoint(x: 0, y: h - 0.5))
                }.stroke(dark, lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Winamp panel with title bar

struct WinampPanel<Content: View>: View {
    let title: String
    var trailingTitleSpace: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Win.titleBar1, Win.titleBar2],
                               startPoint: .top, endPoint: .bottom)
                WindowDragHandle()
                HStack(spacing: 4) {
                    Spacer().frame(width: trailingTitleSpace)
                    Text(title)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .italic()
                        .tracking(2)
                        .foregroundStyle(Win.titleText)
                        .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
                        .allowsHitTesting(false)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .allowsHitTesting(false)
            }
            .frame(height: 14)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Win.bevelDark),
                alignment: .bottom
            )

            content()
                .frame(maxWidth: .infinity)
                .background(Win.face)
        }
        .frame(maxWidth: .infinity)
        .background(Win.face)
        .overlay(Bevel())
    }
}

// MARK: - Plastic button

struct PlasticButton<Label: View>: View {
    var pressed: Bool = false
    var width: CGFloat? = nil
    var height: CGFloat = 18
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var isDown = false

    var body: some View {
        Button(action: action) {
            ZStack {
                LinearGradient(
                    colors: (pressed || isDown)
                        ? [Win.faceDark, Win.face]
                        : [Win.faceLight, Win.face],
                    startPoint: .top, endPoint: .bottom
                )
                label()
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(pressed ? 0.95 : 0.85))
                    .offset(x: (pressed || isDown) ? 0.5 : 0, y: (pressed || isDown) ? 0.5 : 0)
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay(Bevel(pressed: pressed || isDown))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDown { isDown = true } }
                .onEnded { _ in isDown = false }
        )
    }
}

extension PlasticButton where Label == Text {
    init(_ text: String, pressed: Bool = false, width: CGFloat? = nil,
         height: CGFloat = 18, action: @escaping () -> Void) {
        self.pressed = pressed
        self.width = width
        self.height = height
        self.action = action
        self.label = { Text(text) }
    }
}

// MARK: - LCD time display

struct LCDDisplay: View {
    let text: String
    var color: Color = Win.lcdGreen
    var fontSize: CGFloat = 22
    var alignment: Alignment = .center

    var body: some View {
        ZStack(alignment: alignment) {
            Win.lcdBg
            Text(text)
                .font(.system(size: fontSize, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.7), radius: 1.5)
                .padding(.horizontal, 4)
                .monospacedDigit()
        }
        .overlay(Bevel(pressed: true))
    }
}

// MARK: - LED-style status pill

struct StatusLED: View {
    let label: String
    var on: Bool
    var color: Color = Win.lcdGreen

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(on ? color : color.opacity(0.18))
            .shadow(color: on ? color.opacity(0.6) : .clear, radius: 1.2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Win.lcdBg)
            .overlay(Bevel(pressed: true))
    }
}

// MARK: - Tiny LED indicator dot

struct LEDDot: View {
    var on: Bool
    var color: Color = Win.lcdGreen
    var body: some View {
        Circle()
            .fill(on ? color : color.opacity(0.18))
            .shadow(color: on ? color.opacity(0.7) : .clear, radius: 1.5)
            .frame(width: 5, height: 5)
    }
}

// MARK: - Horizontal slider (volume / balance / progress)

struct WinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var fillTone: Color = Win.lcdGreen
    var trackTone: Color = Win.eqTrack
    var trackHeight: CGFloat = 8
    var showFill: Bool = true
    var onEditingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let pct = max(0, min(1, (value - range.lowerBound) / max(span, 0.0001)))
            let thumbW: CGFloat = 14
            let thumbH = geo.size.height
            let xRange = geo.size.width - thumbW
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(trackTone)
                    .frame(height: trackHeight)
                    .frame(maxHeight: .infinity)
                    .overlay(Bevel(pressed: true).frame(height: trackHeight))
                if showFill {
                    Rectangle()
                        .fill(fillTone.opacity(0.85))
                        .frame(width: max(0, pct * xRange + thumbW / 2), height: trackHeight)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                ZStack {
                    Rectangle().fill(LinearGradient(
                        colors: [Win.faceLight, Win.face],
                        startPoint: .top, endPoint: .bottom))
                    Rectangle()
                        .fill(Win.bevelDark)
                        .frame(width: 1, height: thumbH * 0.5)
                }
                .frame(width: thumbW, height: thumbH)
                .overlay(Bevel())
                .offset(x: pct * xRange)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onEditingChanged?(true)
                        let p = max(0, min(1, (v.location.x - thumbW / 2) / xRange))
                        value = range.lowerBound + p * span
                    }
                    .onEnded { _ in onEditingChanged?(false) }
            )
        }
    }
}

// MARK: - Vertical EQ slider (yellow plastic)

struct EQSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let pct = max(0, min(1, (value - range.lowerBound) / max(span, 0.0001)))
            let thumbH: CGFloat = 11
            let trackW: CGFloat = 7
            let usable = geo.size.height - thumbH
            ZStack {
                // Track
                ZStack {
                    Rectangle().fill(Win.eqTrack)
                    Rectangle().fill(Win.bevelDark).frame(width: 1)
                }
                .frame(width: trackW)
                .overlay(Bevel(pressed: true).frame(width: trackW))
                .frame(maxHeight: .infinity)

                // Center notch
                Rectangle()
                    .fill(Win.bevelDark)
                    .frame(width: trackW + 2, height: 1)

                // Yellow thumb
                ZStack {
                    LinearGradient(
                        colors: [Win.eqYellow, Win.eqYellowDark],
                        startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Win.eqYellowDark.opacity(0.8))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(width: 17, height: thumbH)
                .overlay(Bevel())
                .offset(y: usable * (0.5 - pct))
            }
            .frame(width: geo.size.width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let p = max(0, min(1, 1 - (v.location.y - thumbH/2) / usable))
                        value = range.lowerBound + p * span
                    }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

// MARK: - Window drag handle (call performDrag from a real NSView)

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - Custom title-bar window controls

struct TitleControls: View {
    var body: some View {
        HStack(spacing: 1) {
            ChromeButton(symbol: "minus") {
                NSApp.keyWindow?.miniaturize(nil)
            }
            ChromeButton(symbol: "square") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            ChromeButton(symbol: "xmark") {
                NSApp.keyWindow?.performClose(nil)
            }
        }
    }
}

private struct ChromeButton: View {
    let symbol: String
    let action: () -> Void
    @State private var down = false
    var body: some View {
        Button(action: action) {
            ZStack {
                LinearGradient(
                    colors: down ? [Win.faceDark, Win.face]
                                 : [Win.faceLight, Win.face],
                    startPoint: .top, endPoint: .bottom)
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 12, height: 10)
            .overlay(Bevel(pressed: down))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in down = true }
                .onEnded { _ in down = false }
        )
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
