import Foundation
import AVFoundation
import Combine
import AppKit
import MediaPlayer
import CoreAudio
import AudioToolbox

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
    @Published var sleepTimerEnd: Date? = nil
    @Published var availableOutputDevices: [OutputDevice] = []
    @Published var currentOutputDeviceID: AudioDeviceID? = nil
    @Published private(set) var customEQPresets: [EQPreset] = []

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq: AVAudioUnitEQ
    private var audioFile: AVAudioFile?
    private var seekFrame: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 44100
    private var ticker: Timer?
    private var sleepTimer: Timer?
    private var nowPlayingThrottle: Date = .distantPast
    private var hasRestoredState: Bool = false
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
        refreshOutputDevices()
        configureRemoteCommands()
        loadCustomEQPresets()
        restoreState()
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
        let bands = sharedFFTAnalyzer.process(buffer: buffer,
                                              bandCount: PlayerEngine.spectrumBandCount)
        Task { @MainActor [bands] in
            for i in 0..<min(self.spectrum.count, bands.count) {
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
        updateNowPlayingTimeIfNeeded()
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
                self.saveState()
            }
        }
    }

    /// Appends already-loaded `Track` values to the playlist, optionally
    /// starting playback at the first newly-added track. Each track is
    /// re-stamped with a fresh UUID so it is independent from the
    /// source (the library, for example) — removing it from the
    /// playlist later does not affect the original.
    func enqueue(_ incoming: [Track], andPlay: Bool = false) {
        guard !incoming.isEmpty else { return }
        let copies: [Track] = incoming.map { src in
            Track(url: src.url,
                  title: src.title,
                  artist: src.artist,
                  album: src.album,
                  duration: src.duration,
                  artwork: src.artwork,
                  replayGainDB: src.replayGainDB,
                  lyrics: src.lyrics)
        }
        let firstNewIndex = tracks.count
        tracks.append(contentsOf: copies)
        saveState()
        if andPlay {
            play(index: firstNewIndex)
        }
    }

    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int) {
        let nowPlayingID = currentTrack?.id
        tracks.move(fromOffsets: source, toOffset: destination)
        if let id = nowPlayingID {
            currentIndex = tracks.firstIndex(where: { $0.id == id })
        }
        saveState()
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
        saveState()
    }

    func clear() {
        stop()
        tracks.removeAll()
        currentIndex = nil
        duration = 0
        currentTime = 0
        saveState()
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
            // Replay Gain — apply per-track gain at the player node so the
            // user's main volume slider on the mixer is unaffected.
            if let db = track.replayGainDB {
                playerNode.volume = pow(10, db / 20)
            } else {
                playerNode.volume = 1
            }
            scheduleAndArm(file: file, startingFrame: 0)
            if autoplay {
                if !engine.isRunning { try? engine.start() }
                playerNode.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
            updateNowPlayingInfo()
            saveState()
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
        updateNowPlayingInfo()
    }

    func play() {
        if currentTrack == nil {
            if !tracks.isEmpty { play(index: 0) }
            return
        }
        if !engine.isRunning { try? engine.start() }
        playerNode.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        updateNowPlayingInfo()
        saveState()
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
        updateNowPlayingInfo()
        saveState()
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

    /// Captures the current EQ state as a named user preset and persists
    /// it to UserDefaults. Replaces an existing preset with the same name.
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EQPreset(name: trimmed,
                              preamp: preampGain,
                              bands: bandGains)
        customEQPresets.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        customEQPresets.append(preset)
        customEQPresets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveCustomEQPresets()
    }

    func deleteCustomEQPreset(_ preset: EQPreset) {
        customEQPresets.removeAll { $0.id == preset.id }
        saveCustomEQPresets()
    }

    private static let customEQKey = "minpaw.customEQPresets.v1"

    private func saveCustomEQPresets() {
        if let data = try? JSONEncoder().encode(customEQPresets) {
            UserDefaults.standard.set(data, forKey: Self.customEQKey)
        }
    }

    private func loadCustomEQPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.customEQKey),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data)
        else { return }
        customEQPresets = presets
    }

    // MARK: - Sleep timer

    /// Schedules a sleep timer that pauses playback after `minutes`.
    /// Pass `nil` to cancel.
    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes, minutes > 0 else {
            sleepTimerEnd = nil
            return
        }
        let interval = TimeInterval(minutes * 60)
        sleepTimerEnd = Date().addingTimeInterval(interval)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
                self?.sleepTimerEnd = nil
            }
        }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var tracks: [Track]
        var currentIndex: Int?
        var currentTime: TimeInterval
        var volume: Float
        var shuffle: Bool
        var repeatMode: String
        var preampGain: Float
        var bandGains: [Float]
        var eqEnabled: Bool
    }

    private static let stateKey = "minpaw.persistedState.v1"

    func saveState() {
        let state = PersistedState(
            tracks: tracks,
            currentIndex: currentIndex,
            currentTime: currentTime,
            volume: volume,
            shuffle: shuffle,
            repeatMode: repeatMode.rawValue,
            preampGain: preampGain,
            bandGains: bandGains,
            eqEnabled: eqEnabled
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func restoreState() {
        guard !hasRestoredState else { return }
        hasRestoredState = true
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }

        // Filter out tracks whose files have moved or been deleted, so a
        // stale playlist doesn't fail loading every track silently.
        tracks = state.tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        volume = state.volume
        shuffle = state.shuffle
        if let mode = RepeatMode(rawValue: state.repeatMode) {
            repeatMode = mode
        }
        eqEnabled = state.eqEnabled
        preampGain = state.preampGain
        for (i, g) in state.bandGains.enumerated() where i < bandGains.count {
            setBand(i, gain: g)
        }

        // Lazy-load missing artwork in the background so the UI shows it
        // soon after launch without blocking.
        Task { [tracks] in
            for (idx, track) in tracks.enumerated() where track.artwork == nil {
                if let refreshed = await Track.load(from: track.url) {
                    await MainActor.run {
                        guard idx < self.tracks.count, self.tracks[idx].id == track.id else { return }
                        self.tracks[idx].artwork = refreshed.artwork
                    }
                }
            }
        }

        if let savedIndex = state.currentIndex,
           savedIndex >= 0,
           savedIndex < tracks.count {
            currentIndex = savedIndex
            loadCurrent(autoplay: false)
            if state.currentTime > 0 && state.currentTime < duration {
                seek(to: state.currentTime)
            }
        }
        updateNowPlayingInfo()
    }

    // MARK: - Now Playing Center / remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
    }

    func updateNowPlayingInfo() {
        let info = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.artist { dict[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { dict[MPMediaItemPropertyAlbumTitle] = album }
        if let data = track.artwork, let img = NSImage(data: data) {
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            dict[MPMediaItemPropertyArtwork] = art
        }
        info.nowPlayingInfo = dict
        info.playbackState = isPlaying ? .playing : .paused
    }

    private func updateNowPlayingTimeIfNeeded() {
        // Don't spam the system; refresh elapsed-time at most once per second.
        let now = Date()
        guard now.timeIntervalSince(nowPlayingThrottle) > 1.0 else { return }
        nowPlayingThrottle = now
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Output device selection (Core Audio HAL)

    func refreshOutputDevices() {
        availableOutputDevices = OutputDeviceManager.list()
        currentOutputDeviceID = OutputDeviceManager.current(of: engine)
    }

    func setOutputDevice(_ id: AudioDeviceID) {
        guard OutputDeviceManager.set(deviceID: id, on: engine) else { return }
        currentOutputDeviceID = id
        // Re-install the spectrum tap because the engine's main mixer
        // output format can change with the device.
        installTap()
    }
}

// MARK: - Output device value type

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}
