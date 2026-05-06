import Accelerate
import AVFoundation

/// Process-wide singleton — `FFTAnalyzer` does no per-instance state
/// mutation that requires synchronization, and the audio tap callback
/// always runs on a single serial queue, so reuse across calls is safe.
let sharedFFTAnalyzer = FFTAnalyzer(size: 1024)

/// Real-FFT spectrum analyzer for the audio tap.
///
/// Apple-recommended path: vDSP.DFT (forward, real → complex), Hann
/// window, then magnitude → log-spaced visual bands. Used by
/// PlayerEngine's mainMixerNode tap to drive the on-screen vis bars
/// that react to actual frequency content (bass on the left, treble
/// on the right) instead of the previous RMS/level-meter approach.
final class FFTAnalyzer: @unchecked Sendable {
    let fftSize: Int
    private let dft: vDSP.DFT<Float>
    private let window: [Float]
    /// Auto-gain: tracks recent peak band magnitude so the visual bars
    /// react to the song's relative dynamics regardless of absolute
    /// amplitude. Mutated only from the audio-tap thread, which is
    /// serial.
    private var smoothedPeak: Float = 1
    private let peakDecay: Float = 0.985
    /// Keeps the reference from collapsing during silent passages so
    /// the bars don't suddenly explode when the next note hits.
    private let peakFloor: Float = 0.5

    init(size: Int = 1024) {
        precondition(size.nonzeroBitCount == 1, "FFT size must be a power of two")
        self.fftSize = size
        guard let d = vDSP.DFT(count: size,
                               direction: .forward,
                               transformType: .complexComplex,
                               ofType: Float.self) else {
            fatalError("Failed to create DFT setup of size \(size)")
        }
        self.dft = d
        self.window = vDSP.window(ofType: Float.self,
                                  usingSequence: .hanningDenormalized,
                                  count: size,
                                  isHalfWindow: false)
    }

    /// Returns `bandCount` log-spaced spectrum magnitudes in 0...1.
    /// Falls back to all-zeros if the buffer can't be analyzed.
    func process(buffer: AVAudioPCMBuffer, bandCount: Int) -> [Float] {
        let zeros = [Float](repeating: 0, count: bandCount)
        guard let channelData = buffer.floatChannelData else { return zeros }
        let frames = Int(buffer.frameLength)
        guard frames >= fftSize / 2 else { return zeros }

        let usable = min(frames, fftSize)
        let channelCount = Int(buffer.format.channelCount)

        // Mix to mono (dropping channels above 2 keeps the scale stable).
        var mono = [Float](repeating: 0, count: fftSize)
        for f in 0..<usable {
            var s: Float = 0
            for c in 0..<channelCount { s += channelData[c][f] }
            mono[f] = s / Float(max(channelCount, 1))
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP.multiply(mono, window, result: &windowed)

        let imagIn = [Float](repeating: 0, count: fftSize)
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)
        dft.transform(inputReal: windowed,
                      inputImaginary: imagIn,
                      outputReal: &realOut,
                      outputImaginary: &imagOut)

        let half = fftSize / 2
        var mags = [Float](repeating: 0, count: half)
        for i in 0..<half {
            mags[i] = sqrtf(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }

        // Log-space the visual bands across the audible range.
        let nyquist = Float(buffer.format.sampleRate) / 2
        let minFreq: Float = 60
        let maxFreq: Float = min(16_000, nyquist - 1)
        var bands = [Float](repeating: 0, count: bandCount)
        let denom = log(maxFreq / minFreq)
        for b in 0..<bandCount {
            let lowFreq = minFreq * exp(denom * Float(b) / Float(bandCount))
            let highFreq = minFreq * exp(denom * Float(b + 1) / Float(bandCount))
            let lowBin = max(0, Int((lowFreq / nyquist) * Float(half)))
            let highBin = max(lowBin + 1, Int((highFreq / nyquist) * Float(half)))
            var sum: Float = 0
            var n: Int = 0
            for i in lowBin..<min(highBin, half) {
                sum += mags[i]
                n += 1
            }
            bands[b] = n > 0 ? sum / Float(n) : 0
        }

        // Auto-gain — pin the bars to the recent peak so a loud song
        // doesn't peg everything red and a quiet song still shows
        // something. Decay is slow enough to give "VU meter" feel.
        let curPeak = bands.max() ?? 0
        smoothedPeak = max(curPeak, smoothedPeak * peakDecay)
        let reference = max(smoothedPeak, peakFloor)

        // Square-root compression on top of the normalized value gives
        // a typical spectrum-analyzer visual response curve: louder
        // transients pop, quiet detail still moves.
        return bands.map { v in
            let normalized = v / reference
            let scaled = sqrtf(min(normalized, 1.5))
            return min(1, max(0, scaled))
        }
    }
}
