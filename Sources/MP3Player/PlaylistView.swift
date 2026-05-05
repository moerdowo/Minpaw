import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlaylistView: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var selection: Set<UUID> = []

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
            Group {
                if player.tracks.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(Array(player.tracks.enumerated()), id: \.element.id) { idx, track in
                            TrackRow(
                                index: idx,
                                track: track,
                                isPlaying: player.currentIndex == idx,
                                isSelected: selection.contains(track.id)
                            )
                            .id(track.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
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
                        .onMove { from, to in
                            player.moveTracks(fromOffsets: from, toOffset: to)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Win.lcdBg)
                    .alternatingRowBackgrounds(.disabled)
                    .environment(\.defaultMinListRowHeight, 18)
                    .onChange(of: player.currentIndex) { _, new in
                        if let i = new, i < player.tracks.count {
                            withAnimation { proxy.scrollTo(player.tracks[i].id, anchor: .center) }
                        }
                    }
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
}

struct TrackRow: View {
    let index: Int
    let track: Track
    let isPlaying: Bool
    let isSelected: Bool

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(hex: 0x0A2F4D) : Color.clear)
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
