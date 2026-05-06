import AppKit
import UniformTypeIdentifiers

/// Reads and writes the extended M3U format. Tolerates unprefixed
/// (plain URL-per-line) playlists too.
enum M3UPlaylist {
    static func read(from url: URL) -> [URL] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let base = url.deletingLastPathComponent()
        var result: [URL] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and the directives that bracket entries.
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // Absolute path (file:// or /…), or relative to the .m3u dir.
            if let parsed = URL(string: line), parsed.scheme != nil {
                result.append(parsed)
            } else if line.hasPrefix("/") {
                result.append(URL(fileURLWithPath: line))
            } else {
                result.append(base.appendingPathComponent(line))
            }
        }
        return result.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func write(tracks: [Track], to url: URL) throws {
        var lines: [String] = ["#EXTM3U"]
        for track in tracks {
            let durationSecs = Int(track.duration.rounded())
            let label: String
            if let artist = track.artist, !artist.isEmpty {
                label = "\(artist) - \(track.title)"
            } else {
                label = track.title
            }
            lines.append("#EXTINF:\(durationSecs),\(label)")
            lines.append(track.url.path)
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// AppKit panel coordinators — small enough to keep here.
@MainActor
enum PlaylistFiles {
    static var playlistType: UTType {
        UTType(filenameExtension: "m3u") ?? .plainText
    }

    static func openPlaylist(into player: PlayerEngine) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [playlistType, .plainText]
        panel.message = "Choose an M3U playlist to open."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let urls = M3UPlaylist.read(from: url)
        if !urls.isEmpty { player.addFiles(urls: urls) }
    }

    static func savePlaylistAs(from player: PlayerEngine) {
        guard !player.tracks.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [playlistType]
        panel.nameFieldStringValue = "Minpaw.m3u"
        panel.message = "Save the current playlist as M3U."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try M3UPlaylist.write(tracks: player.tracks, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save playlist"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
