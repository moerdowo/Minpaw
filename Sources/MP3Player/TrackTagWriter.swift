import Foundation

/// Routes Edit-Metadata writes to the right format-specific writer
/// based on the file's extension. Pass `nil` for any field you don't
/// want to change. MP3 goes through `MP3TagWriter` (synchronous,
/// in-place ID3v2.3); MP4-family files (M4A/AAC/MP4) go through
/// `M4ATagWriter` (async passthrough export). FLAC, WAV, AIFF, etc.
/// throw `unsupportedFormat`.
enum TrackTagWriter {
    enum WriteError: LocalizedError {
        case unsupportedFormat(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Editing tags for .\(ext) files isn't supported yet — only MP3 and M4A."
            }
        }
    }

    static func write(url: URL,
                      title: String?,
                      artist: String?,
                      album: String?) async throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3":
            try await Task.detached(priority: .userInitiated) {
                try MP3TagWriter.write(url: url, title: title, artist: artist, album: album)
            }.value
        case "m4a", "aac", "mp4":
            try await M4ATagWriter.write(url: url, title: title, artist: artist, album: album)
        default:
            throw WriteError.unsupportedFormat(ext.isEmpty ? "?" : ext)
        }
    }
}
