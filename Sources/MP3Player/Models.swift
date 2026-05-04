import Foundation
import AVFoundation

struct Track: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval
    var artwork: Data?

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
