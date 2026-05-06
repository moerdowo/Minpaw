import Foundation
import AVFoundation

struct Track: Identifiable, Hashable, Codable {
    let id: UUID
    let url: URL
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval
    var artwork: Data?
    /// `replaygain_track_gain` from the file's metadata, in dB. nil
    /// means no Replay Gain tag was present (no normalization applied).
    var replayGainDB: Float?
    /// Embedded lyrics text from the USLT (ID3) or ©lyr (MP4) frame.
    var lyrics: String?

    init(id: UUID = UUID(),
         url: URL,
         title: String,
         artist: String? = nil,
         album: String? = nil,
         duration: TimeInterval,
         artwork: Data? = nil,
         replayGainDB: Float? = nil,
         lyrics: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.replayGainDB = replayGainDB
        self.lyrics = lyrics
    }

    private enum CodingKeys: String, CodingKey {
        // Artwork and lyrics are intentionally omitted from persistence —
        // both can be 100s of KB. Restore reloads them lazily from the file.
        case id, url, title, artist, album, duration, replayGainDB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.url = try c.decode(URL.self, forKey: .url)
        self.title = try c.decode(String.self, forKey: .title)
        self.artist = try c.decodeIfPresent(String.self, forKey: .artist)
        self.album = try c.decodeIfPresent(String.self, forKey: .album)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.replayGainDB = try c.decodeIfPresent(Float.self, forKey: .replayGainDB)
        self.artwork = nil
        self.lyrics = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(artist, forKey: .artist)
        try c.encodeIfPresent(album, forKey: .album)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(replayGainDB, forKey: .replayGainDB)
    }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Track {
    static func load(from url: URL) async -> Track? {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist: String? = nil
        var album: String? = nil
        var artwork: Data? = nil
        var duration: TimeInterval = 0
        var replayGainDB: Float? = nil
        var lyrics: String? = nil

        if let dur = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(dur)
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let v: String = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    artwork = try? await item.load(.dataValue)
                default: break
                }
            }
        }
        // Replay Gain and lyrics live in format-specific metadata
        // (TXXX:REPLAYGAIN_TRACK_GAIN / USLT in ID3, ----:com.apple.iTunes
        // RPG / ©lyr in MP4). Walk every available format.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    if replayGainDB == nil,
                       let db = await Self.parseReplayGain(item: item) {
                        replayGainDB = db
                    }
                    if lyrics == nil,
                       let lyric = await Self.parseLyrics(item: item) {
                        lyrics = lyric
                    }
                }
            }
        }
        return Track(url: url, title: title, artist: artist, album: album,
                     duration: duration, artwork: artwork,
                     replayGainDB: replayGainDB, lyrics: lyrics)
    }

    private static func parseReplayGain(item: AVMetadataItem) async -> Float? {
        let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
        let lower = key.lowercased()
        guard lower.contains("replaygain_track_gain") || lower.contains("replaygain") else {
            return nil
        }
        guard let raw: String = try? await item.load(.stringValue) else { return nil }
        // Strings look like "-6.5 dB" or "+2.1". Strip whitespace and unit.
        let cleaned = raw
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        return Float(cleaned)
    }

    private static func parseLyrics(item: AVMetadataItem) async -> String? {
        let key = (item.key as? String) ?? ""
        let identifier = item.identifier?.rawValue ?? ""
        let isUSLT = key.uppercased().contains("USLT") || identifier.contains("USLT")
        let isMP4Lyric = identifier.lowercased().contains("lyr")
        let isCommonLyrics = item.commonKey == .commonKeyType && false  // none defined
        guard isUSLT || isMP4Lyric || isCommonLyrics else { return nil }
        let value: String? = try? await item.load(.stringValue)
        if let v = value, !v.isEmpty { return v }
        return nil
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
    var symbol: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

struct EQPreset: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let preamp: Float
    let bands: [Float]

    init(id: UUID = UUID(), name: String, preamp: Float, bands: [Float]) {
        self.id = id
        self.name = name
        self.preamp = preamp
        self.bands = bands
    }

    static let presets: [EQPreset] = [
        EQPreset(name: "Flat",         preamp: 0, bands: Array(repeating: 0, count: 10)),
        EQPreset(name: "Rock",         preamp: 0, bands: [5, 4, 3, 1, -1, -1, 1, 3, 5, 6]),
        EQPreset(name: "Pop",          preamp: 0, bands: [-1, 2, 4, 5, 4, 1, -1, -1, 0, 1]),
        EQPreset(name: "Jazz",         preamp: 0, bands: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        EQPreset(name: "Classical",    preamp: 0, bands: [4, 3, 2, 0, -1, -1, 0, 2, 3, 4]),
        EQPreset(name: "Bass Boost",   preamp: 0, bands: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", preamp: 0, bands: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
        EQPreset(name: "Vocal",        preamp: 0, bands: [-2, -3, -3, 1, 4, 4, 3, 1, 0, -1]),
        EQPreset(name: "Electronic",   preamp: 0, bands: [4, 4, 1, 0, -2, 2, 0, 1, 4, 5]),
    ]
}
