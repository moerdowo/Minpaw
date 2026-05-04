import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var auto = false

    var body: some View {
        WinampPanel(title: "MINPAW EQUALIZER") {
            VStack(spacing: 4) {
                topRow
                slidersRow
            }
            .padding(6)
        }
    }

    private var topRow: some View {
        HStack(spacing: 4) {
            PlasticButton("ON",
                          pressed: player.eqEnabled,
                          width: 24, height: 12) {
                player.eqEnabled.toggle()
            }
            PlasticButton("AUTO",
                          pressed: auto,
                          width: 30, height: 12) {
                auto.toggle()
            }
            Spacer()
            Text("+12 dB")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim)
            Spacer()
            Menu {
                ForEach(EQPreset.presets) { preset in
                    Button(preset.name) { player.applyPreset(preset) }
                }
                Divider()
                Button("Reset") { player.resetEQ() }
            } label: {
                ZStack {
                    LinearGradient(colors: [Win.faceLight, Win.face],
                                   startPoint: .top, endPoint: .bottom)
                    Text("PRESETS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 56, height: 12)
                .overlay(Bevel())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var slidersRow: some View {
        HStack(alignment: .center, spacing: 0) {
            BandColumn(
                label: "PRE",
                value: Binding(get: { Double(player.preampGain) },
                               set: { player.preampGain = Float($0) })
            )
            .frame(width: 32)
            Rectangle().fill(Win.bevelDark).frame(width: 1, height: 90)
                .padding(.horizontal, 2)
            ForEach(0..<10, id: \.self) { i in
                BandColumn(
                    label: PlayerEngine.bandFrequencies[i] >= 1000
                        ? "\(Int(PlayerEngine.bandFrequencies[i]/1000))K"
                        : "\(Int(PlayerEngine.bandFrequencies[i]))",
                    value: Binding(
                        get: { Double(player.bandGains[i]) },
                        set: { player.setBand(i, gain: Float($0)) }
                    )
                )
                .frame(width: 28)
            }
        }
        .padding(.vertical, 2)
        .opacity(player.eqEnabled ? 1.0 : 0.55)
    }
}

private struct BandColumn: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 3) {
            EQSlider(value: $value, range: -12...12)
                .frame(height: 80)
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
