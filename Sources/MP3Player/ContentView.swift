import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var player: PlayerEngine
    @AppStorage("showEqualizer") private var showEqualizer: Bool = true
    @AppStorage("showPlaylist") private var showPlaylist: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            PlayerView()
            if showEqualizer {
                EqualizerView()
            }
            if showPlaylist {
                PlaylistView()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Win.faceDark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .preferredColorScheme(.dark)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let urls = AudioFileFinder.expand(url)
                if !urls.isEmpty {
                    lock.lock(); collected.append(contentsOf: urls); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { player.addFiles(urls: collected) }
        }
        return true
    }
}

/// Walks dropped/imported URLs and returns just the audio files,
/// recursing into folders. Filtered by extension so it skips
/// album-art and metadata side-files inside a directory.
enum AudioFileFinder {
    static let allowedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "alac"
    ]

    static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return []
        }
        if !isDir.boolValue {
            return allowedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        var found: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let fileURL as URL in enumerator {
            if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                found.append(fileURL)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
