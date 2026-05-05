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
        let allowed: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "alac"]
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url, allowed.contains(u.pathExtension.lowercased()) {
                    lock.lock(); collected.append(u); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { player.addFiles(urls: collected) }
        }
        return true
    }
}
