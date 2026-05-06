import AVFoundation
import CoreAudio
import AudioToolbox

/// Core Audio HAL wrapper for enumerating and switching the audio
/// device that AVAudioEngine renders to. macOS doesn't expose iOS-style
/// route picking, so we go directly to AudioObject* APIs and route the
/// engine's output AU via kAudioOutputUnitProperty_CurrentDevice.
enum OutputDeviceManager {
    /// All output-capable audio devices (built-in, USB, AirPlay, etc.).
    static func list() -> [OutputDevice] {
        var ids = listAllDeviceIDs()
        ids = ids.filter(hasOutputStreams)
        return ids.compactMap { id in
            guard let name = name(of: id) else { return nil }
            return OutputDevice(id: id, name: name)
        }
    }

    /// The device the given engine currently routes to. Falls back to
    /// the system default output if the engine doesn't expose its AU.
    static func current(of engine: AVAudioEngine) -> AudioDeviceID? {
        if let au = engine.outputNode.audioUnit {
            var deviceID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                &size
            )
            if status == noErr, deviceID != 0 { return deviceID }
        }
        return systemDefaultOutputDevice()
    }

    /// Routes the engine to a new output device. Stops and restarts the
    /// engine because changing CurrentDevice on a running output AU is
    /// not always safe. Returns `true` if the switch succeeded.
    @discardableResult
    static func set(deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let au = engine.outputNode.audioUnit else { return false }
        let wasRunning = engine.isRunning
        engine.pause()
        var device = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if wasRunning {
            try? engine.start()
        }
        return status == noErr
    }

    // MARK: - Internals

    private static func listAllDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, buf.baseAddress!
            )
        }
        return status == noErr ? ids : []
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (name as String) : nil
    }

    private static func systemDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}
