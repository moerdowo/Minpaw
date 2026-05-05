import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlaylistView: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var selection: Set<UUID> = []
    @State private var dropTargetID: UUID? = nil
    @State private var dropAtEnd: Bool = false

    var body: some View {
        WinampPanel(title: "MINPAW PLAYLIST") {
            VStack(spacing: 0) {
                trackList
                    .frame(height: 200)
                    .background(Win.lcdBg)
                    .overlay(Bevel(pressed: true))
                Rectangle().fill(Win.bevelDark).frame(height: 1)
                bottomBar
            }
            .padding(4)
        }
    }

    private var trackList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if player.tracks.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(player.tracks.enumerated()), id: \.element.id) { idx, track in
                            TrackRow(
                                index: idx,
                                track: track,
                                isPlaying: player.currentIndex == idx,
                                isSelected: selection.contains(track.id),
                                isDropTarget: dropTargetID == track.id
                            )
                            .id(track.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                player.play(index: idx)
                            }
                            .onTapGesture {
                                if selection.contains(track.id) {
                                    selection.remove(track.id)
                                } else {
                                    selection = [track.id]
                                }
                            }
                            .draggable(TrackTransfer(trackID: track.id))
                            .dropDestination(for: TrackTransfer.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                handleReorder(sourceID: payload.trackID, targetIndex: idx)
                                dropTargetID = nil
                                return true
                            } isTargeted: { targeted in
                                dropTargetID = targeted ? track.id : (dropTargetID == track.id ? nil : dropTargetID)
                            }
                            .contextMenu {
                                Button("Play") { player.play(index: idx) }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                                }
                                Divider()
                                Button("Remove") {
                                    player.remove(at: IndexSet(integer: idx))
                                    selection.remove(track.id)
                                }
                            }
                        }
                        Color.clear
                            .frame(height: 16)
                            .overlay(alignment: .top) {
                                if dropAtEnd {
                                    Rectangle()
                                        .fill(Win.lcdGreen)
                                        .frame(height: 2)
                                        .shadow(color: Win.lcdGreen.opacity(0.7), radius: 2)
                                }
                            }
                            .dropDestination(for: TrackTransfer.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                handleReorder(sourceID: payload.trackID, targetIndex: player.tracks.count)
                                dropAtEnd = false
                                return true
                            } isTargeted: { targeted in
                                dropAtEnd = targeted
                            }
                    }
                }
            }
            .onChange(of: player.currentIndex) { _, new in
                if let i = new, i < player.tracks.count {
                    withAnimation { proxy.scrollTo(player.tracks[i].id, anchor: .center) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 30)
            Text("DRAG MP3 FILES HERE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim)
            Text("OR CLICK ADD")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            PlasticButton("ADD",   width: 28, height: 16) { openFiles() }
            PlasticButton("REM",   width: 28, height: 16) { removeSelected() }
                .opacity(selection.isEmpty ? 0.55 : 1)
            PlasticButton("SEL",   width: 28, height: 16) {
                selection = Set(player.tracks.map(\.id))
            }
            PlasticButton("MISC",  width: 32, height: 16) { player.clear(); selection.removeAll() }
            Spacer()
            Text(positionText)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreen)
                .shadow(color: Win.lcdGreen.opacity(0.55), radius: 1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Win.lcdBg)
                .overlay(Bevel(pressed: true))
            Spacer().frame(width: 4)
            Text(totalText)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreen)
                .shadow(color: Win.lcdGreen.opacity(0.55), radius: 1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Win.lcdBg)
                .overlay(Bevel(pressed: true))
        }
        .padding(.top, 4)
    }

    private var positionText: String {
        let cur = formatTime(player.currentTime)
        let dur = formatTime(player.duration)
        return "\(cur)/\(dur)"
    }

    private var totalText: String {
        let total = player.tracks.reduce(0.0) { $0 + $1.duration }
        let s = Int(total)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let flac = UTType("org.xiph.flac") { types.append(flac) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK { player.addFiles(urls: panel.urls) }
    }

    private func removeSelected() {
        let ids = selection
        let indices = IndexSet(player.tracks.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        player.remove(at: indices)
        selection.removeAll()
    }

    private func handleReorder(sourceID: UUID, targetIndex: Int) {
        guard let from = player.tracks.firstIndex(where: { $0.id == sourceID }) else { return }
        let clamped = max(0, min(targetIndex, player.tracks.count))
        let toOffset = from < clamped ? clamped + (clamped == player.tracks.count ? 0 : 1) : clamped
        guard from != toOffset && from + 1 != toOffset else { return }
        player.moveTracks(fromOffsets: IndexSet(integer: from), toOffset: toOffset)
    }
}

struct TrackRow: View {
    let index: Int
    let track: Track
    let isPlaying: Bool
    let isSelected: Bool
    var isDropTarget: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%d.", index + 1))
                .frame(width: 24, alignment: .trailing)
            Text(displayLine)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(durationText)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(isPlaying ? Win.amber : (isSelected ? Color.white : Win.lcdGreen))
        .shadow(color: (isPlaying ? Win.amber : Win.lcdGreen).opacity(isSelected ? 0 : 0.45), radius: 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(isSelected ? Color(hex: 0x0A2F4D) : Color.clear)
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(Win.lcdGreen)
                    .frame(height: 2)
                    .shadow(color: Win.lcdGreen.opacity(0.7), radius: 2)
            }
        }
    }

    private var displayLine: String {
        if let artist = track.artist, !artist.isEmpty {
            return "\(artist) - \(track.title)"
        }
        return track.title
    }

    private var durationText: String {
        let s = Int(track.duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
