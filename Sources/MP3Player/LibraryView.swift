import SwiftUI
import AppKit

/// Winamp-style library window — sidebar of categories, Artist/Album
/// pickers, track table, with search and persistent folder index.
/// Double-click a track to add it to the playlist and play it.
struct LibraryView: View {
    @StateObject private var store = LibraryStore()
    @EnvironmentObject var player: PlayerEngine
    @State private var trackSelection: Set<UUID> = []
    @State private var selectionAnchor: UUID? = nil
    @State private var editingTrack: Track? = nil

    var body: some View {
        ZStack {
            Win.faceDark.ignoresSafeArea()
            WinampPanel(title: "MINPAW LIBRARY") {
                HStack(spacing: 4) {
                    sidebar
                    mainArea
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                TitleControls()
                    .padding(.top, 2)
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(LibraryWindowChrome())
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .sheet(item: $editingTrack) { track in
            EditMetadataSheet(track: track) { newTitle, newArtist, newAlbum in
                // After a successful file-tag write the sheet calls
                // back with the values that were written. Reflect them
                // in the library index too.
                store.updateTrack(id: track.id,
                                  title: newTitle,
                                  artist: newArtist,
                                  album: newAlbum)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader("LOCAL LIBRARY")
            ForEach(LibraryStore.Category.allCases) { cat in
                sidebarRow(cat: cat)
            }
            Spacer()
        }
        .frame(width: 150)
        .padding(.vertical, 4)
        .background(Win.lcdBg)
        .overlay(Bevel(pressed: true))
    }

    private func sidebarSectionHeader(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
            Spacer()
        }
        .foregroundStyle(Win.lcdGreenDim)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func sidebarRow(cat: LibraryStore.Category) -> some View {
        let isSelected = store.selectedCategory == cat
        return Button(action: {
            store.selectedCategory = cat
            store.selectedArtist = nil
            store.selectedAlbum = nil
        }) {
            HStack(spacing: 6) {
                Image(systemName: cat.icon)
                    .font(.system(size: 9))
                    .frame(width: 12)
                Text(cat.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Win.lcdGreen)
            .shadow(color: isSelected ? .clear : Win.lcdGreen.opacity(0.45), radius: 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .background(isSelected ? Color(hex: 0x0A2F4D) : Color.clear)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main area

    private var mainArea: some View {
        VStack(spacing: 4) {
            searchBar
            HStack(spacing: 4) {
                listColumn(title: "Artist",
                           items: store.artists,
                           allLabel: "All (\(store.artists.count) artist\(store.artists.count == 1 ? "" : "s"))",
                           isAllSelected: store.selectedArtist == nil,
                           isItemSelected: { store.selectedArtist == $0 },
                           selectAll: {
                               store.selectedArtist = nil
                               store.selectedAlbum = nil
                           },
                           select: { artist in
                               store.selectedArtist = artist
                               store.selectedAlbum = nil
                           })
                listColumn(title: "Album",
                           items: store.albums,
                           allLabel: "All (\(store.albums.count) album\(store.albums.count == 1 ? "" : "s"))",
                           isAllSelected: store.selectedAlbum == nil,
                           isItemSelected: { store.selectedAlbum == $0 },
                           selectAll: { store.selectedAlbum = nil },
                           select: { store.selectedAlbum = $0 })
            }
            .frame(maxHeight: .infinity)
            tracksTable
                .frame(maxHeight: .infinity)
            footer
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Text("Search:")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim)
            ZStack(alignment: .leading) {
                Win.lcdBg
                TextField("", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Win.lcdGreen)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
            }
            .overlay(Bevel(pressed: true))
            .frame(width: 160, height: 18)
            Button("Clear") { store.searchText = "" }
                .buttonStyle(SoftButton())
                .disabled(store.searchText.isEmpty)
            Spacer()
        }
    }

    // MARK: - Artist / Album list columns

    private func listColumn(title: String,
                            items: [String],
                            allLabel: String,
                            isAllSelected: Bool,
                            isItemSelected: @escaping (String) -> Bool,
                            selectAll: @escaping () -> Void,
                            select: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Win.lcdGreenDim)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(LinearGradient(colors: [Win.faceLight, Win.face],
                                        startPoint: .top, endPoint: .bottom))
            .overlay(Bevel())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    listRow(text: allLabel,
                            selected: isAllSelected,
                            bold: true,
                            action: selectAll)
                    ForEach(items, id: \.self) { item in
                        listRow(text: item,
                                selected: isItemSelected(item),
                                bold: false,
                                action: { select(item) })
                    }
                }
            }
            .background(Win.lcdBg)
            .overlay(Bevel(pressed: true))
        }
    }

    private func listRow(text: String, selected: Bool, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: bold ? .bold : .regular, design: .monospaced))
                .foregroundStyle(selected ? Color.white : Win.lcdGreen)
                .shadow(color: selected ? .clear : Win.lcdGreen.opacity(0.4), radius: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color(hex: 0x0A2F4D) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Track table

    private var tracksTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("Title").frame(maxWidth: .infinity, alignment: .leading)
                tableHeader("Artist").frame(width: 130, alignment: .leading)
                tableHeader("Album").frame(width: 140, alignment: .leading)
                tableHeader("Track #").frame(width: 60, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(LinearGradient(colors: [Win.faceLight, Win.face],
                                        startPoint: .top, endPoint: .bottom))
            .overlay(Bevel())

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleTracks) { track in
                        trackRow(track: track)
                    }
                }
            }
            .background(Win.lcdBg)
            .overlay(Bevel(pressed: true))
        }
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Win.lcdGreenDim)
    }

    private func trackRow(track: Track) -> some View {
        let isSelected = trackSelection.contains(track.id)
        return HStack(spacing: 0) {
            Text(track.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(store.displayArtist(track))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 130, alignment: .leading)
            Text(store.displayAlbum(track))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 140, alignment: .leading)
            Text(formatDuration(track.duration))
                .frame(width: 60, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(isSelected ? Color.white : Win.lcdGreen)
        .shadow(color: isSelected ? .clear : Win.lcdGreen.opacity(0.4), radius: 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(hex: 0x0A2F4D) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click adds to the playlist (no autoplay) — the
            // user starts playback explicitly from the player window.
            let targets = contextTargets(clicked: track)
            player.enqueue(targets, andPlay: false)
        }
        .onTapGesture {
            updateSelection(clicked: track)
        }
        .contextMenu {
            let targets = contextTargets(clicked: track)
            Button("Add to Playlist") {
                player.enqueue(targets, andPlay: false)
            }
            Button("Add to Playlist & Play") {
                player.enqueue(targets, andPlay: true)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
            }
            Divider()
            Button("Edit Metadata…") {
                // Always edit the right-clicked track, regardless of
                // multi-selection — keeps the dialog unambiguous.
                editingTrack = track
            }
            Divider()
            Button("Remove from Library", role: .destructive) {
                let ids = Set(targets.map(\.id))
                store.remove(trackIDs: ids)
                trackSelection.subtract(ids)
                if let anchor = selectionAnchor, ids.contains(anchor) {
                    selectionAnchor = nil
                }
            }
        }
    }

    /// Mac-convention right-click target: if the right-clicked row is in
    /// the current selection, the menu acts on the whole selection;
    /// otherwise it acts on just the clicked row.
    private func contextTargets(clicked: Track) -> [Track] {
        if trackSelection.contains(clicked.id) {
            return store.visibleTracks.filter { trackSelection.contains($0.id) }
        }
        return [clicked]
    }

    /// Single-click selection logic that mirrors macOS table behavior:
    /// plain click replaces, ⌘-click toggles, ⇧-click extends a range
    /// from the last anchor.
    private func updateSelection(clicked: Track) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor {
            let visible = store.visibleTracks
            if let i = visible.firstIndex(where: { $0.id == anchor }),
               let j = visible.firstIndex(where: { $0.id == clicked.id }) {
                let lo = min(i, j), hi = max(i, j)
                trackSelection = Set(visible[lo...hi].map(\.id))
                return
            }
        }
        if flags.contains(.command) {
            if trackSelection.contains(clicked.id) {
                trackSelection.remove(clicked.id)
            } else {
                trackSelection.insert(clicked.id)
            }
            selectionAnchor = clicked.id
            return
        }
        trackSelection = [clicked.id]
        selectionAnchor = clicked.id
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Add Folder…") { store.indexFolder() }
                .buttonStyle(SoftButton())

            Button("Clear Library") { store.clear() }
                .buttonStyle(SoftButton())
                .disabled(store.tracks.isEmpty)

            Spacer()

            if store.indexing {
                Text("Indexing \(store.indexProgress.loaded)/\(store.indexProgress.total)…")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Win.amber)
                    .shadow(color: Win.amber.opacity(0.5), radius: 1)
            } else {
                Text(statsText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Win.lcdGreenDim)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var statsText: String {
        let count = store.visibleTracks.count
        guard count > 0 else { return "no items" }
        let mb = Double(store.totalSizeBytes) / 1_048_576
        let dur = Int(store.totalDuration)
        let h = dur / 3600
        let m = (dur % 3600) / 60
        let s = dur % 60
        let durStr = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
        return "\(count) item\(count == 1 ? "" : "s") · [\(durStr)] · [\(String(format: "%.2f MB", mb))]"
    }
}

// MARK: - Edit Metadata sheet

private struct EditMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let onSave: (String, String?, String?) -> Void

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    init(track: Track, onSave: @escaping (String, String?, String?) -> Void) {
        self.track = track
        self.onSave = onSave
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist ?? "")
        _album = State(initialValue: track.album ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Metadata")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                row(label: "Title",  text: $title,  required: true)
                row(label: "Artist", text: $artist, required: false)
                row(label: "Album",  text: $album,  required: false)
            }
            Text("Saves write to both the file's tags and the library.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(saving ? "Saving…" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || trimmed(title).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(label: String, text: Binding<String>, required: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label + (required ? " *" : ""))
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(saving)
        }
    }

    private func commit() {
        let cleanTitle = trimmed(title)
        guard !cleanTitle.isEmpty else { return }
        let cleanArtist = trimmed(artist).nilIfEmpty
        let cleanAlbum = trimmed(album).nilIfEmpty

        saving = true
        errorMessage = nil

        Task {
            do {
                try await TrackTagWriter.write(
                    url: track.url,
                    title: cleanTitle,
                    artist: cleanArtist,
                    album: cleanAlbum
                )
                await MainActor.run {
                    onSave(cleanTitle, cleanArtist, cleanAlbum)
                    saving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saving = false
                }
            }
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Window chrome

private struct LibraryWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { LibraryChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class LibraryChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.title = ""
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        window.isOpaque = true
        window.hasShadow = true
        // Stays resizable by default — leave .resizable in styleMask.
    }
}
