import SwiftUI
import AppKit

/// Winamp-style library window — sidebar of categories, Artist/Album
/// pickers, track table, with search and persistent folder index.
/// Double-click a track to add it to the playlist and play it.
struct LibraryView: View {
    @StateObject private var store = LibraryStore()
    @EnvironmentObject var player: PlayerEngine

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
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader("LOCAL LIBRARY")
            ForEach(LibraryStore.Category.allCases) { cat in
                sidebarRow(cat: cat)
            }
            Spacer().frame(height: 6)
            sidebarSectionHeader("PLAYLISTS")
            sidebarStatic(label: "Bookmarks", icon: "bookmark.fill")
            sidebarStatic(label: "History", icon: "clock.arrow.circlepath")
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

    private func sidebarStatic(label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9)).frame(width: 12)
            Text(label).font(.system(size: 10, weight: .bold, design: .monospaced))
            Spacer()
        }
        .foregroundStyle(Win.lcdGreenDim.opacity(0.7))
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim)
            ZStack(alignment: .leading) {
                Win.lcdBg
                TextField("", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Win.lcdGreen)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .overlay(Bevel(pressed: true))
            .frame(maxWidth: 260)
            Button("Clear Search") { store.searchText = "" }
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
        HStack(spacing: 0) {
            Text(track.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artist ?? "—")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 130, alignment: .leading)
            Text(track.album ?? "—")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 140, alignment: .leading)
            Text(formatDuration(track.duration))
                .frame(width: 60, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Win.lcdGreen)
        .shadow(color: Win.lcdGreen.opacity(0.4), radius: 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            player.enqueue([track], andPlay: true)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Play") {
                let pool = store.visibleTracks
                if !pool.isEmpty {
                    player.enqueue(pool, andPlay: true)
                }
            }
            .buttonStyle(SoftButton())
            .disabled(store.visibleTracks.isEmpty)

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
