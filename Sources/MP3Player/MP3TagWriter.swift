import Foundation

/// Minimal ID3v2 writer for MP3 files. Parses the existing tag,
/// replaces the title (`TIT2`) / artist (`TPE1`) / album (`TALB`)
/// frames, preserves every other frame (artwork `APIC`, year, genre,
/// lyrics, etc.) byte-for-byte, then re-emits the tag in ID3v2.3
/// format and writes the file atomically.
///
/// Pass `nil` for any field to leave it untouched. Pass `""` to clear.
/// Other formats (FLAC, WAV) are not supported here — use
/// `TrackTagWriter` to dispatch on extension.
enum MP3TagWriter {
    enum WriteError: LocalizedError {
        case readFailed(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .readFailed(let m): return "Read failed: \(m)"
            case .writeFailed(let m): return "Write failed: \(m)"
            }
        }
    }

    static func write(url: URL,
                      title: String?,
                      artist: String?,
                      album: String?) throws {
        guard let raw = try? Data(contentsOf: url) else {
            throw WriteError.readFailed(url.lastPathComponent)
        }
        let (existingFrames, audioStart) = parseExistingTag(in: raw)
        var framesByID = Dictionary(uniqueKeysWithValues: existingFrames.map { ($0.id, $0) })

        if let title { framesByID["TIT2"] = makeTextFrame(id: "TIT2", text: title) }
        if let artist { framesByID["TPE1"] = makeTextFrame(id: "TPE1", text: artist) }
        if let album { framesByID["TALB"] = makeTextFrame(id: "TALB", text: album) }

        // Drop frames whose new value is an explicitly-empty string.
        for (key, frame) in framesByID {
            if isReplacedKey(key) && frame.payload.count <= 3 {
                framesByID.removeValue(forKey: key)
            }
        }

        var tagBody = Data()
        // Stable order: edited fields first, then everything else
        // alphabetically — keeps diffs predictable for spot-checks.
        let preferred = ["TIT2", "TPE1", "TALB"]
        for id in preferred {
            if let frame = framesByID[id] { tagBody.append(encodeFrame(frame)) }
        }
        for id in framesByID.keys.sorted() where !preferred.contains(id) {
            if let frame = framesByID[id] { tagBody.append(encodeFrame(frame)) }
        }
        // Trailing zero padding so future edits don't always have to
        // shift the audio data.
        tagBody.append(Data(repeating: 0, count: 1024))

        var output = Data()
        output.append(contentsOf: [0x49, 0x44, 0x33])  // "ID3"
        output.append(contentsOf: [0x03, 0x00])         // v2.3.0
        output.append(0x00)                             // flags
        output.append(contentsOf: synchsafeBytes(tagBody.count))
        output.append(tagBody)
        output.append(raw.subdata(in: audioStart..<raw.count))

        try atomicWrite(output, to: url)
    }

    // MARK: - Parsing

    struct ID3Frame {
        let id: String
        let flags: [UInt8]
        let payload: Data
    }

    private static func isReplacedKey(_ key: String) -> Bool {
        key == "TIT2" || key == "TPE1" || key == "TALB"
    }

    /// Returns the parsed frame list and the byte offset where audio
    /// data begins (10 + tagBodySize, or 0 if there's no tag).
    private static func parseExistingTag(in data: Data) -> ([ID3Frame], Int) {
        let bytes = Array(data.prefix(10))
        guard bytes.count == 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else {
            return ([], 0)
        }
        let majorVersion = bytes[3]
        let flags = bytes[5]
        let tagBodySize = synchsafeToInt(Array(bytes[6..<10]))
        let audioStart = 10 + tagBodySize
        guard audioStart <= data.count else { return ([], 0) }

        var bodyStart = 10
        // Skip extended header if present.
        if flags & 0x40 != 0 {
            guard data.count >= bodyStart + 4 else { return ([], audioStart) }
            let extHdr = Array(data.subdata(in: bodyStart..<(bodyStart + 4)))
            let extSize = (majorVersion == 4)
                ? synchsafeToInt(extHdr)
                : (Int(extHdr[0]) << 24) | (Int(extHdr[1]) << 16)
                  | (Int(extHdr[2]) << 8)  | Int(extHdr[3])
            bodyStart += extSize
        }

        var frames: [ID3Frame] = []
        var i = bodyStart
        let bodyEnd = 10 + tagBodySize
        while i + 10 <= bodyEnd {
            let header = Array(data.subdata(in: i..<(i + 10)))
            // Padding (zeros) marks the end of frames.
            if header[0..<4].allSatisfy({ $0 == 0 }) { break }
            guard let id = String(bytes: header[0..<4], encoding: .ascii),
                  isValidFrameID(id) else { break }
            let sizeBytes = Array(header[4..<8])
            let frameSize = (majorVersion == 4)
                ? synchsafeToInt(sizeBytes)
                : (Int(sizeBytes[0]) << 24) | (Int(sizeBytes[1]) << 16)
                  | (Int(sizeBytes[2]) << 8)  | Int(sizeBytes[3])
            let frameFlags = Array(header[8..<10])
            guard i + 10 + frameSize <= bodyEnd else { break }
            let payload = data.subdata(in: (i + 10)..<(i + 10 + frameSize))
            frames.append(ID3Frame(id: id, flags: frameFlags, payload: payload))
            i += 10 + frameSize
        }
        return (frames, audioStart)
    }

    private static func isValidFrameID(_ id: String) -> Bool {
        guard id.count == 4 else { return false }
        return id.allSatisfy { ch in
            ("A"..."Z").contains(ch) || ("0"..."9").contains(ch)
        }
    }

    // MARK: - Encoding

    private static func makeTextFrame(id: String, text: String) -> ID3Frame {
        // ID3v2.3 text frame:
        //   byte 0          encoding marker (1 = UTF-16 with BOM)
        //   bytes 1..2      BOM (0xFF 0xFE for LE)
        //   bytes 3..N      UTF-16 LE code units
        //   last 2 bytes    NULL terminator (0x00 0x00)
        var payload = Data([0x01, 0xFF, 0xFE])
        if let utf16 = text.data(using: .utf16LittleEndian) {
            payload.append(utf16)
        }
        payload.append(contentsOf: [0x00, 0x00])
        return ID3Frame(id: id, flags: [0x00, 0x00], payload: payload)
    }

    private static func encodeFrame(_ frame: ID3Frame) -> Data {
        var out = Data()
        out.append(contentsOf: Array(frame.id.utf8))
        let size = UInt32(frame.payload.count)
        // ID3v2.3 frame size: regular big-endian uint32 (NOT synchsafe).
        out.append(contentsOf: [
            UInt8((size >> 24) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ])
        out.append(contentsOf: frame.flags)
        out.append(frame.payload)
        return out
    }

    private static func synchsafeToInt(_ bytes: [UInt8]) -> Int {
        precondition(bytes.count == 4)
        return (Int(bytes[0]) << 21) | (Int(bytes[1]) << 14)
             | (Int(bytes[2]) << 7)  | Int(bytes[3])
    }

    private static func synchsafeBytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ]
    }

    // MARK: - Atomic write

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".minpaw-tag-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw WriteError.writeFailed(error.localizedDescription)
        }
    }
}
