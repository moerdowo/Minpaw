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
        Group {
            if player.tracks.isEmpty {
                emptyState
            } else {
                PlaylistTable(
                    tracks: player.tracks,
                    selection: $selection,
                    currentTrackID: player.currentTrack?.id,
                    onPlay: { row in player.play(index: row) },
                    onMove: { from, to in player.moveTracks(fromOffsets: from, toOffset: to) },
                    onReveal: { track in NSWorkspace.shared.activateFileViewerSelecting([track.url]) },
                    onRemoveRows: { indices in
                        let removedIDs = indices.compactMap { idx -> UUID? in
                            guard idx < player.tracks.count else { return nil }
                            return player.tracks[idx].id
                        }
                        player.remove(at: indices)
                        for id in removedIDs { selection.remove(id) }
                    }
                )
                .background(Win.lcdBg)
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
            miscMenu
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

    private var miscMenu: some View {
        Menu {
            Section("Sleep timer") {
                Button(player.sleepTimerEnd == nil ? "Off" : "Off (cancel)") {
                    player.setSleepTimer(minutes: nil)
                }
                Button("In 15 minutes") { player.setSleepTimer(minutes: 15) }
                Button("In 30 minutes") { player.setSleepTimer(minutes: 30) }
                Button("In 60 minutes") { player.setSleepTimer(minutes: 60) }
                Button("In 90 minutes") { player.setSleepTimer(minutes: 90) }
            }
            Divider()
            Button("Clear playlist") {
                player.clear()
                selection.removeAll()
            }
            .disabled(player.tracks.isEmpty)
        } label: {
            ZStack {
                LinearGradient(colors: [Win.faceLight, Win.face],
                               startPoint: .top, endPoint: .bottom)
                Text("MISC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(player.sleepTimerEnd != nil ? Win.amber : .white.opacity(0.85))
                    .shadow(color: player.sleepTimerEnd != nil ? Win.amber.opacity(0.6) : .clear, radius: 1)
            }
            .frame(width: 32, height: 16)
            .overlay(Bevel())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose audio files or folders to add."
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
        if let flac = UTType("org.xiph.flac") { types.append(flac) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK {
            let expanded = panel.urls.flatMap { AudioFileFinder.expand($0) }
            if !expanded.isEmpty { player.addFiles(urls: expanded) }
        }
    }

    private func removeSelected() {
        let ids = selection
        let indices = IndexSet(player.tracks.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        player.remove(at: indices)
        selection.removeAll()
    }
}

