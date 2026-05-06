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

    init(id: UUID = UUID(),
         url: URL,
         title: String,
         artist: String? = nil,
         album: String? = nil,
         duration: TimeInterval,
         artwork: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
    }

    private enum CodingKeys: String, CodingKey {
        // Artwork is intentionally omitted from persistence — it can be
        // 100s of KB per track. Restore reloads it lazily from the file.
        case id, url, title, artist, album, duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.url = try c.decode(URL.self, forKey: .url)
        self.title = try c.decode(String.self, forKey: .title)
        self.artist = try c.decodeIfPresent(String.self, forKey: .artist)
        self.album = try c.decodeIfPresent(String.self, forKey: .album)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.artwork = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(artist, forKey: .artist)
        try c.encodeIfPresent(album, forKey: .album)
        try c.encode(duration, forKey: .duration)
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
        return Track(url: url, title: title, artist: artist, album: album,
                     duration: duration, artwork: artwork)
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

struct EQPreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let preamp: Float
    let bands: [Float]

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
