import Foundation
import AVFoundation

/// Tag writer for MP4 / M4A / AAC files. Uses
/// `AVAssetExportPresetPassthrough` so the audio stream is copied
/// without re-encoding, then atomically replaces the original file.
/// Existing metadata items are preserved unless their identifier
/// matches one of the fields we're updating.
enum M4ATagWriter {
    enum WriteError: LocalizedError {
        case sessionUnavailable
        case exportFailed(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "Couldn't create an export session for this file."
            case .exportFailed(let m):
                return "Export failed: \(m)"
            case .writeFailed(let m):
                return "Write failed: \(m)"
            }
        }
    }

    static func write(url: URL,
                      title: String?,
                      artist: String?,
                      album: String?) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw WriteError.sessionUnavailable
        }

        let existing = (try? await asset.load(.metadata)) ?? []
        var output: [AVMetadataItem] = existing.compactMap { item in
            // Drop items whose identifier matches what we're about to
            // write. Untouched items survive (artwork, year, etc.).
            if title  != nil, isTitle(item)  { return nil }
            if artist != nil, isArtist(item) { return nil }
            if album  != nil, isAlbum(item)  { return nil }
            return item
        }
        if let title  { output.append(make(.iTunesMetadataSongName, value: title)) }
        if let artist { output.append(make(.iTunesMetadataArtist,   value: artist)) }
        if let album  { output.append(make(.iTunesMetadataAlbum,    value: album)) }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".minpaw-tag-\(UUID().uuidString).m4a")
        session.outputURL = temp
        session.outputFileType = .m4a
        session.metadata = output

        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            let msg = session.error?.localizedDescription
                ?? "status=\(session.status.rawValue)"
            throw WriteError.exportFailed(msg)
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw WriteError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Identifier matching

    private static func isTitle(_ item: AVMetadataItem) -> Bool {
        match(item, identifiers: [
            .iTunesMetadataSongName,
            .commonIdentifierTitle,
            .quickTimeMetadataTitle
        ], keySuffix: "nam")
    }

    private static func isArtist(_ item: AVMetadataItem) -> Bool {
        match(item, identifiers: [
            .iTunesMetadataArtist,
            .commonIdentifierArtist,
            .quickTimeMetadataArtist
        ], keySuffix: "ART")
    }

    private static func isAlbum(_ item: AVMetadataItem) -> Bool {
        match(item, identifiers: [
            .iTunesMetadataAlbum,
            .commonIdentifierAlbumName,
            .quickTimeMetadataAlbum
        ], keySuffix: "alb")
    }

    private static func match(_ item: AVMetadataItem,
                              identifiers: [AVMetadataIdentifier],
                              keySuffix: String) -> Bool {
        if let identifier = item.identifier,
           identifiers.contains(identifier) {
            return true
        }
        let raw = item.identifier?.rawValue ?? ""
        if raw.hasSuffix(keySuffix) { return true }
        let key = (item.key as? String) ?? ""
        return key.hasSuffix(keySuffix)
    }

    private static func make(_ identifier: AVMetadataIdentifier,
                             value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }
}
