import Foundation
import AVFoundation
import Combine
import AppKit
import MediaPlayer
import CoreAudio
import AudioToolbox

extension Notification.Name {
    /// Posted by PlayerEngine when a track transitions to playing
    /// (user-initiated or auto-advance). `object` is the track's URL.
    /// LibraryStore observes this to maintain play count + history.
    static let minpawTrackStartedPlaying = Notification.Name("minpaw.trackStartedPlaying")
}

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
            // The pre-scheduled "next" was chosen under the previous
            // shuffle/repeat policy; tear it down so the next tick
            // re-picks under the new policy.
            cancelPendingTransition()
        }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            if repeatMode != .off && shuffle { shuffle = false }
            cancelPendingTransition()
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

    // MARK: - Transition / loudness toggles (default off)

    /// Pre-schedules the next track on the idle player so it begins
    /// playing the same instant the current one ends — no buffer
    /// underrun, no silence between tracks.
    @Published var gaplessEnabled: Bool = false {
        didSet {
            if oldValue != gaplessEnabled {
                cancelPendingTransition()
                saveTransitionPrefs()
            }
        }
    }
    /// Overlaps the tail of the current track with the head of the
    /// next, ramping volumes in opposite directions over
    /// `crossfadeSeconds`. Takes precedence over `gaplessEnabled` when
    /// both are on.
    @Published var crossfadeEnabled: Bool = false {
        didSet {
            if oldValue != crossfadeEnabled {
                cancelPendingTransition()
                saveTransitionPrefs()
            }
        }
    }
    /// Length of the crossfade overlap. Clamped to [1, 15].
    @Published var crossfadeSeconds: Double = 4 {
        didSet {
            let clamped = min(15, max(1, crossfadeSeconds))
            if clamped != crossfadeSeconds {
                // didSet recursion is safe — Swift only re-runs once
                // per assignment, and the clamped value matches.
                crossfadeSeconds = clamped
                return
            }
            cancelPendingTransition()
            saveTransitionPrefs()
        }
    }
    /// Applies each track's `replaygain_track_gain` tag to the player
    /// volume so loud and quiet tracks land at roughly the same
    /// perceived level.
    @Published var replayGainEnabled: Bool = false {
        didSet {
            if oldValue != replayGainEnabled {
                applyReplayGainVolumes()
                saveTransitionPrefs()
            }
        }
    }

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let preMixer = AVAudioMixerNode()
    private let eq: AVAudioUnitEQ

    /// Toggled to swap which node is "active" (playing the current
    /// track) and which is "idle" (used to pre-schedule the next one
    /// for gapless / crossfade).
    private var useA: Bool = true
    private var activePlayer: AVAudioPlayerNode { useA ? playerA : playerB }
    private var idlePlayer:   AVAudioPlayerNode { useA ? playerB : playerA }

    // Per-track state for the active player.
    private var audioFile: AVAudioFile?
    private var fileSampleRate: Double = 44100
    private var seekFrame: AVAudioFramePosition = 0

    /// Time-anchor model. `currentTime` is computed every tick as
    /// `activeStartSeconds + (sampleTime - anchorSampleTime) / rate`.
    /// Reset on track-load, seek, or transition swap.
    private var activeStartSeconds: Double = 0
    private var anchorSampleTime: AVAudioFramePosition? = nil

    // Pre-schedule state.
    private struct PendingNext {
        let file: AVAudioFile
        let trackIndex: Int
        /// True if the idle player has already been started
        /// (mid-crossfade); false if it is queued via `play(at:)`
        /// for gapless start.
        let crossfading: Bool
        let replayGainDB: Float?
    }
    private var pending: PendingNext?
    private var fadeTimer: Timer?
    private var fadeStartedAt: Date?
    private var fadeFromActiveRG: Float = 1
    private var fadeFromIdleRG: Float = 1

    private var ticker: Timer?
    private var sleepTimer: Timer?
    private var nowPlayingThrottle: Date = .distantPast
    private var hasRestoredState: Bool = false

    /// Per-player completion-callback tokens. Bumped every time we
    /// schedule (or invalidate) a buffer on the corresponding player.
    /// Callbacks captured at schedule time only fire if the value
    /// still matches — so seeks, stops, and track-changes don't
    /// trigger spurious end-of-track callbacks. With two player nodes,
    /// each has its own token so cancelling one doesn't disarm the
    /// other.
    private var tokenA: Int = 0
    private var tokenB: Int = 0

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

        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(preMixer)
        engine.attach(eq)
        // Both players feed a sub-mixer so a single EQ instance can
        // sit on the combined signal — and so crossfading two tracks
        // simultaneously is just two `volume` ramps.
        engine.connect(playerA, to: preMixer, fromBus: 0, toBus: 0, format: nil)
        engine.connect(playerB, to: preMixer, fromBus: 0, toBus: 1, format: nil)
        engine.connect(preMixer, to: eq, format: nil)
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
        loadTransitionPrefs()
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
              let nodeTime = activePlayer.lastRenderTime,
              let playerTime = activePlayer.playerTime(forNodeTime: nodeTime)
        else { return }
        if anchorSampleTime == nil {
            anchorSampleTime = playerTime.sampleTime
        }
        let anchor = anchorSampleTime ?? playerTime.sampleTime
        let played = max(0, Double(playerTime.sampleTime - anchor)) / playerTime.sampleRate
        let absolute = activeStartSeconds + played
        currentTime = max(0, min(duration, absolute))
        updateNowPlayingTimeIfNeeded()
        considerPreScheduling()
    }

    /// If we're approaching the end of the track and a transition is
    /// enabled, set up the next track on the idle player. No-op if
    /// neither toggle is on, if a pending transition already exists,
    /// or if there is no plausible next track.
    private func considerPreScheduling() {
        guard isPlaying,
              currentTrack != nil,
              pending == nil,
              gaplessEnabled || crossfadeEnabled
        else { return }
        guard let nextIndex = upcomingTrackIndex() else { return }
        // Crossfade needs more headroom (the whole overlap window);
        // gapless only needs enough to schedule + arm.
        let useCrossfade = crossfadeEnabled
        let lookahead = useCrossfade ? crossfadeSeconds + 0.25 : 0.5
        guard duration > 0, currentTime > duration - lookahead else { return }
        prepareNextTrack(index: nextIndex, crossfade: useCrossfade)
    }

    /// Predicts which playlist entry should follow the current track,
    /// honoring the active shuffle / repeat policy. Returns nil when
    /// playback should stop at the end (single play through).
    private func upcomingTrackIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }
        if shuffle {
            return randomNextIndex()
        }
        switch repeatMode {
        case .one:
            return currentIndex
        case .all:
            let cur = currentIndex ?? 0
            return (cur + 1) % tracks.count
        case .off:
            let cur = currentIndex ?? 0
            return cur + 1 < tracks.count ? cur + 1 : nil
        }
    }

    private func prepareNextTrack(index: Int, crossfade: Bool) {
        guard index >= 0, index < tracks.count else { return }
        let nextTrack = tracks[index]
        guard let file = try? AVAudioFile(forReading: nextTrack.url) else { return }

        let nextRG = volumeForRG(nextTrack.replayGainDB)
        if crossfade {
            // Idle player will ramp 0 → nextRG; start silent.
            idlePlayer.volume = 0
        } else {
            idlePlayer.volume = nextRG
        }

        scheduleAndArm(player: idlePlayer, file: file, startingFrame: 0)

        if crossfade {
            // Begin playback immediately so the overlap window starts.
            if !engine.isRunning { try? engine.start() }
            idlePlayer.play()
            startCrossfadeRamp(activeRG: currentTrackRGGain(), idleRG: nextRG)
        } else {
            // Gapless: queue the idle player to start at the precise
            // host time the active player runs out.
            scheduleNextStartAtEndOfCurrent()
        }

        pending = PendingNext(file: file,
                              trackIndex: index,
                              crossfading: crossfade,
                              replayGainDB: nextTrack.replayGainDB)
    }

    /// Computes the host time at which the active track's audio will
    /// stop and arms the idle player to start playing then. Falls back
    /// to a "play now" if the player isn't reporting a render time.
    private func scheduleNextStartAtEndOfCurrent() {
        guard let curNodeTime = activePlayer.lastRenderTime,
              let curPlayerTime = activePlayer.playerTime(forNodeTime: curNodeTime)
        else {
            if !engine.isRunning { try? engine.start() }
            idlePlayer.play()
            return
        }
        let remaining = max(0.05, duration - currentTime)
        let hostOffset = AVAudioTime.hostTime(forSeconds: remaining)
        let endHostTime = curPlayerTime.hostTime + hostOffset
        let when = AVAudioTime(hostTime: endHostTime)
        if !engine.isRunning { try? engine.start() }
        idlePlayer.play(at: when)
    }

    private func startCrossfadeRamp(activeRG: Float, idleRG: Float) {
        fadeTimer?.invalidate()
        fadeStartedAt = Date()
        fadeFromActiveRG = activeRG
        fadeFromIdleRG = idleRG
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCrossfade() }
        }
    }

    private func tickCrossfade() {
        guard let started = fadeStartedAt else { return }
        let dur = max(0.1, crossfadeSeconds)
        let progress = max(0, min(1, Date().timeIntervalSince(started) / dur))
        activePlayer.volume = fadeFromActiveRG * Float(1 - progress)
        idlePlayer.volume = fadeFromIdleRG * Float(progress)
        if progress >= 1 {
            fadeTimer?.invalidate()
            fadeTimer = nil
            // The active player's `.dataPlayedBack` callback fires
            // shortly after this — that's where the swap happens.
        }
    }

    /// Swaps active/idle pointers and rebases time accounting for the
    /// already-scheduled next track. Called from `handleEnd` when a
    /// pre-scheduled transition was in flight.
    private func commitTransition(_ pending: PendingNext) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStartedAt = nil

        let oldActive = activePlayer
        useA.toggle()
        // Old active is now idle: flush any leftover scheduled audio
        // and reset its volume so a future pre-schedule starts clean.
        oldActive.stop()
        oldActive.volume = 1

        // New active is whichever became `activePlayer` after toggle.
        audioFile = pending.file
        fileSampleRate = pending.file.processingFormat.sampleRate
        duration = Double(pending.file.length) / fileSampleRate
        seekFrame = 0
        // Crossfade has already been audible for `crossfadeSeconds`,
        // so the new track's wall-clock position is non-zero on entry.
        activeStartSeconds = pending.crossfading
            ? min(crossfadeSeconds, max(0, duration))
            : 0
        anchorSampleTime = nil
        activePlayer.volume = volumeForRG(pending.replayGainDB)

        currentIndex = pending.trackIndex
        isPlaying = true
        NotificationCenter.default.post(
            name: .minpawTrackStartedPlaying,
            object: tracks[pending.trackIndex].url
        )
        updateNowPlayingInfo()
        saveState()
        self.pending = nil
    }

    private func handleEnd() {
        // If a transition is pending, the next track is already
        // playing (crossfade) or queued (gapless). Just commit.
        if let p = pending {
            commitTransition(p)
            return
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            play()
        case .all:
            next()
        case .off:
            if shuffle {
                next()
            } else if let i = currentIndex, i + 1 < tracks.count {
                next()
            } else {
                stop()
            }
        }
    }

    /// Schedules the given file (or segment of it) on the given player
    /// node, arming a completion handler that fires `handleEnd` when
    /// that buffer is fully rendered AND the player is still the
    /// active one. Per-player tokens guard against stale callbacks.
    private func scheduleAndArm(player: AVAudioPlayerNode,
                                file: AVAudioFile,
                                startingFrame: AVAudioFramePosition) {
        let isA = (player === playerA)
        let token: Int
        if isA { tokenA &+= 1; token = tokenA }
        else   { tokenB &+= 1; token = tokenB }

        if startingFrame == 0 {
            player.scheduleFile(
                file,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.completionFired(isA: isA, token: token)
            }
        } else {
            let remaining = file.length - startingFrame
            guard remaining > 0 else { return }
            player.scheduleSegment(
                file,
                startingFrame: startingFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.completionFired(isA: isA, token: token)
            }
        }
    }

    nonisolated private func completionFired(isA: Bool, token: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cur = isA ? self.tokenA : self.tokenB
            guard cur == token, self.isPlaying else { return }
            // Only fire boundary for the player that is *currently*
            // active. An idle pre-schedule's completion will be reached
            // after the swap, at which point `useA` has been toggled
            // and `isA == useA` again — so the guard still passes.
            guard isA == self.useA else { return }
            self.handleEnd()
        }
    }

    /// Tear down a queued transition: stop the idle player (which
    /// flushes any `play(at:)` that hasn't fired), clear the fade
    /// timer, and reset `pending`. Bumps the idle player's token so
    /// any in-flight completion handler is ignored.
    private func cancelPendingTransition() {
        let wasFading = fadeTimer != nil
        if wasFading {
            fadeTimer?.invalidate()
            fadeTimer = nil
            fadeStartedAt = nil
        }
        if pending != nil {
            idlePlayer.stop()
            // Bump the idle player's token to invalidate any pending
            // completion callback.
            if useA { tokenB &+= 1 } else { tokenA &+= 1 }
            idlePlayer.volume = 1
            pending = nil
        }
        if wasFading {
            // The fade may have ramped the active player partway to
            // silence — restore it to its replay-gain baseline so the
            // current track keeps playing at the right level.
            activePlayer.volume = currentTrackRGGain()
        }
    }

    private func volumeForRG(_ db: Float?) -> Float {
        guard replayGainEnabled, let db else { return 1 }
        // Cap at +6 dB so a mistagged file can't blow the user's ears
        // out, and at -30 dB so we don't silence a track entirely.
        let clamped = min(6, max(-30, db))
        return pow(10, clamped / 20)
    }

    private func currentTrackRGGain() -> Float {
        volumeForRG(currentTrack?.replayGainDB)
    }

    private func applyReplayGainVolumes() {
        // Don't fight the crossfade ramp.
        guard fadeTimer == nil else { return }
        if currentTrack != nil {
            activePlayer.volume = currentTrackRGGain()
        } else {
            activePlayer.volume = 1
        }
        if let p = pending {
            idlePlayer.volume = volumeForRG(p.replayGainDB)
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
        // Indices for any pre-scheduled "next" are no longer reliable.
        cancelPendingTransition()
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
        cancelPendingTransition()
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
        // Tell the library so it can bump play count / last-played
        // for the underlying file (matched by URL).
        NotificationCenter.default.post(
            name: .minpawTrackStartedPlaying,
            object: tracks[index].url
        )
    }

    private func loadCurrent(autoplay: Bool) {
        guard let track = currentTrack else { return }
        do {
            let file = try AVAudioFile(forReading: track.url)
            cancelPendingTransition()
            // Stop the idle player too in case we're switching from
            // a transition that had already started ramping.
            idlePlayer.stop()
            idlePlayer.volume = 1
            audioFile = file
            fileSampleRate = file.processingFormat.sampleRate
            duration = Double(file.length) / fileSampleRate
            seekFrame = 0
            currentTime = 0
            activeStartSeconds = 0
            anchorSampleTime = nil
            activePlayer.stop()
            activePlayer.volume = volumeForRG(track.replayGainDB)
            scheduleAndArm(player: activePlayer, file: file, startingFrame: 0)
            if autoplay {
                if !engine.isRunning { try? engine.start() }
                activePlayer.play()
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
            // A scheduled `play(at:)` for gapless will fire on host
            // time even while we're paused, so cancel any pending
            // transition before pausing.
            cancelPendingTransition()
            activePlayer.pause()
            isPlaying = false
        } else {
            if !engine.isRunning { try? engine.start() }
            activePlayer.play()
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
        activePlayer.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        cancelPendingTransition()
        activePlayer.pause()
        isPlaying = false
        updateNowPlayingInfo()
        saveState()
    }

    func stop() {
        cancelPendingTransition()
        activePlayer.stop()
        idlePlayer.stop()
        // Bump tokens so any in-flight completion is ignored.
        tokenA &+= 1
        tokenB &+= 1
        isPlaying = false
        seekFrame = 0
        activeStartSeconds = 0
        anchorSampleTime = nil
        currentTime = 0
        // Re-arm the active player with the current file from the top
        // so a follow-up play() resumes at frame 0.
        if let track = currentTrack, let file = try? AVAudioFile(forReading: track.url) {
            audioFile = file
            activePlayer.scheduleFile(file, at: nil, completionHandler: nil)
        }
        updateNowPlayingInfo()
        saveState()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        // A user-initiated next throws away any in-flight transition.
        cancelPendingTransition()
        play(index: shuffle ? randomNextIndex() : ((currentIndex ?? -1) + 1) % tracks.count)
    }

    func previous() {
        guard !tracks.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        cancelPendingTransition()
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
        cancelPendingTransition()
        let wasPlaying = isPlaying
        activePlayer.stop()
        seekFrame = frame
        activeStartSeconds = target
        anchorSampleTime = nil
        activePlayer.volume = volumeForRG(currentTrack?.replayGainDB)
        scheduleAndArm(player: activePlayer, file: file, startingFrame: frame)
        currentTime = target
        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            activePlayer.play()
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

    // MARK: - Persistence (playlist + transition prefs)

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

    private struct TransitionPrefs: Codable {
        var gaplessEnabled: Bool
        var crossfadeEnabled: Bool
        var crossfadeSeconds: Double
        var replayGainEnabled: Bool
    }

    private static let transitionKey = "minpaw.transitionPrefs.v1"
    private var loadingTransitionPrefs: Bool = false

    private func saveTransitionPrefs() {
        // Avoid clobbering on initial load.
        guard !loadingTransitionPrefs else { return }
        let prefs = TransitionPrefs(
            gaplessEnabled: gaplessEnabled,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeSeconds: crossfadeSeconds,
            replayGainEnabled: replayGainEnabled
        )
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.transitionKey)
        }
    }

    private func loadTransitionPrefs() {
        guard let data = UserDefaults.standard.data(forKey: Self.transitionKey),
              let prefs = try? JSONDecoder().decode(TransitionPrefs.self, from: data)
        else { return }
        loadingTransitionPrefs = true
        gaplessEnabled = prefs.gaplessEnabled
        crossfadeEnabled = prefs.crossfadeEnabled
        crossfadeSeconds = prefs.crossfadeSeconds
        replayGainEnabled = prefs.replayGainEnabled
        loadingTransitionPrefs = false
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
