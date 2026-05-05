import Foundation
import AVFoundation
import Combine
import AppKit

@MainActor
final class PlayerEngine: ObservableObject {
    static let bandFrequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    static let spectrumBandCount = 20

    @Published var tracks: [Track] = []
    @Published var currentIndex: Int? = nil
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }
    @Published var balance: Float = 0 {
        didSet { engine.mainMixerNode.pan = balance }
    }
    @Published var shuffle: Bool = false {
        didSet {
            if shuffle && repeatMode != .off { repeatMode = .off }
        }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            if repeatMode != .off && shuffle { shuffle = false }
        }
    }
    @Published var preampGain: Float = 0 {
        didSet { eq.globalGain = preampGain }
    }
    @Published var eqEnabled: Bool = true {
        didSet { eq.bands.forEach { $0.bypass = !eqEnabled } }
    }
    @Published var bandGains: [Float]
    @Published var spectrum: [Float] = Array(repeating: 0, count: PlayerEngine.spectrumBandCount)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq: AVAudioUnitEQ
    private var audioFile: AVAudioFile?
    private var seekFrame: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 44100
    private var ticker: Timer?
    // Bumped every time we schedule (or invalidate) a buffer. The
    // completion handler captures the value at schedule time and only
    // fires `handleEnd` if the value still matches — so seeks, stops,
    // and track-changes don't trigger spurious end-of-track callbacks.
    private var scheduleToken: Int = 0

    var currentTrack: Track? {
        guard let i = currentIndex, i >= 0, i < tracks.count else { return nil }
        return tracks[i]
    }

    init() {
        eq = AVAudioUnitEQ(numberOfBands: 10)
        bandGains = Array(repeating: 0, count: 10)
        for (i, freq) in Self.bandFrequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 0.7
            band.gain = 0
            band.bypass = false
        }

        engine.attach(playerNode)
        engine.attach(eq)
        engine.connect(playerNode, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume

        do { try engine.start() } catch {
            NSLog("AudioEngine failed to start: \(error)")
        }

        installTap()
        startTicker()
    }

    // MARK: - Spectrum tap

    private func installTap() {
        let bus: AVAudioNodeBus = 0
        let format = engine.mainMixerNode.outputFormat(forBus: bus)
        engine.mainMixerNode.removeTap(onBus: bus)
        engine.mainMixerNode.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processSpectrum(buffer: buffer)
        }
    }

    nonisolated private func processSpectrum(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let bandCount = 20
        var bands = [Float](repeating: 0, count: bandCount)
        let chunk = max(1, frames / bandCount)
        for b in 0..<bandCount {
            let start = b * chunk
            let end = min(start + chunk, frames)
            var sum: Float = 0
            var count: Int = 0
            for f in start..<end {
                for c in 0..<channelCount {
                    let v = channelData[c][f]
                    sum += v * v
                    count += 1
                }
            }
            let rms = sqrtf(sum / Float(max(count, 1)))
            bands[b] = min(1, rms * 5)
        }
        Task { @MainActor [bands] in
            for i in 0..<self.spectrum.count {
                let target = bands[i]
                let cur = self.spectrum[i]
                self.spectrum[i] = max(target, cur * 0.78)
            }
        }
    }

    // MARK: - Time ticker

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        let absolute = Double(seekFrame) / fileSampleRate + played
        currentTime = max(0, min(duration, absolute))
        // End-of-track is detected via the schedule completion handler,
        // not from time tracking — playerTime stops updating once the
        // buffer is consumed, so a tick-based guard would never fire.
    }

    private func handleEnd() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            play()
        case .all:
            next()
        case .off:
            if shuffle {
                // With shuffle on, keep playing forever — the user has
                // to stop manually. Matches typical shuffle UX.
                next()
            } else if let i = currentIndex, i + 1 < tracks.count {
                next()
            } else {
                stop()
            }
        }
    }

    /// Schedules the given file (or segment of it) for playback and arms
    /// a completion handler that fires `handleEnd` once the audio has
    /// actually been rendered. Returns after the schedule call is queued.
    private func scheduleAndArm(file: AVAudioFile, startingFrame: AVAudioFramePosition) {
        scheduleToken &+= 1
        let token = scheduleToken
        if startingFrame == 0 {
            playerNode.scheduleFile(
                file,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.completionFired(token: token)
            }
        } else {
            let remaining = file.length - startingFrame
            guard remaining > 0 else { return }
            playerNode.scheduleSegment(
                file,
                startingFrame: startingFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.completionFired(token: token)
            }
        }
    }

    nonisolated private func completionFired(token: Int) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.scheduleToken == token,
                  self.isPlaying else { return }
            self.handleEnd()
        }
    }

    // MARK: - Library

    func addFiles(urls: [URL]) {
        Task {
            var loaded: [Track] = []
            for url in urls {
                if let t = await Track.load(from: url) {
                    loaded.append(t)
                }
            }
            await MainActor.run {
                self.tracks.append(contentsOf: loaded)
            }
        }
    }

    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int) {
        let nowPlayingID = currentTrack?.id
        tracks.move(fromOffsets: source, toOffset: destination)
        if let id = nowPlayingID {
            currentIndex = tracks.firstIndex(where: { $0.id == id })
        }
    }

    func remove(at indices: IndexSet) {
        let wasCurrent = currentIndex
        tracks.remove(atOffsets: indices)
        if let cur = wasCurrent, indices.contains(cur) {
            stop()
            currentIndex = nil
        } else if let cur = wasCurrent {
            let removedBefore = indices.filter { $0 < cur }.count
            currentIndex = cur - removedBefore
        }
    }

    func clear() {
        stop()
        tracks.removeAll()
        currentIndex = nil
        duration = 0
        currentTime = 0
    }

    // MARK: - Playback

    func play(index: Int) {
        guard index >= 0, index < tracks.count else { return }
        currentIndex = index
        loadCurrent(autoplay: true)
    }

    private func loadCurrent(autoplay: Bool) {
        guard let track = currentTrack else { return }
        do {
            let file = try AVAudioFile(forReading: track.url)
            audioFile = file
            fileSampleRate = file.processingFormat.sampleRate
            duration = Double(file.length) / fileSampleRate
            seekFrame = 0
            currentTime = 0
            playerNode.stop()
            scheduleAndArm(file: file, startingFrame: 0)
            if autoplay {
                if !engine.isRunning { try? engine.start() }
                playerNode.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
        } catch {
            NSLog("Failed to load \(track.url): \(error)")
        }
    }

    func togglePlay() {
        if currentTrack == nil {
            if !tracks.isEmpty { play(index: 0) }
            return
        }
        if isPlaying {
            playerNode.pause()
            isPlaying = false
        } else {
            if !engine.isRunning { try? engine.start() }
            playerNode.play()
            isPlaying = true
        }
    }

    func play() {
        if currentTrack == nil {
            if !tracks.isEmpty { play(index: 0) }
            return
        }
        if !engine.isRunning { try? engine.start() }
        playerNode.play()
        isPlaying = true
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func stop() {
        playerNode.stop()
        // Bump the token so any in-flight completion from the prior
        // schedule is ignored when it fires.
        scheduleToken &+= 1
        isPlaying = false
        seekFrame = 0
        currentTime = 0
        if let track = currentTrack, let file = try? AVAudioFile(forReading: track.url) {
            audioFile = file
            playerNode.scheduleFile(file, at: nil, completionHandler: nil)
        }
    }

    func next() {
        guard !tracks.isEmpty else { return }
        play(index: shuffle ? randomNextIndex() : ((currentIndex ?? -1) + 1) % tracks.count)
    }

    func previous() {
        guard !tracks.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        play(index: shuffle ? randomNextIndex() : ((currentIndex ?? 0) - 1 + tracks.count) % tracks.count)
    }

    private func randomNextIndex() -> Int {
        guard tracks.count > 1 else { return 0 }
        var pick = Int.random(in: 0..<tracks.count)
        while pick == currentIndex {
            pick = Int.random(in: 0..<tracks.count)
        }
        return pick
    }

    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        let target = max(0, min(duration, time))
        let frame = AVAudioFramePosition(target * fileSampleRate)
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        let wasPlaying = isPlaying
        playerNode.stop()
        seekFrame = frame
        scheduleAndArm(file: file, startingFrame: frame)
        currentTime = target
        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            playerNode.play()
            isPlaying = true
        }
    }

    // MARK: - EQ

    func setBand(_ index: Int, gain: Float) {
        guard index >= 0, index < eq.bands.count else { return }
        eq.bands[index].gain = gain
        bandGains[index] = gain
    }

    func applyPreset(_ preset: EQPreset) {
        preampGain = preset.preamp
        for (i, gain) in preset.bands.enumerated() where i < eq.bands.count {
            setBand(i, gain: gain)
        }
    }

    func resetEQ() {
        applyPreset(EQPreset.presets[0])
        preampGain = 0
    }
}
