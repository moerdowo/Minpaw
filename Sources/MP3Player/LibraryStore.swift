import Foundation
import AppKit

/// Strings used when a track's metadata is missing. Shown in the
/// artist/album lists, on the track row, and used as the bucket name
/// when filtering by artist/album.
enum LibraryDefaults {
    static let unknownArtist = "Various Artists"
    static let unknownAlbum = "Unknown Album"
}

/// In-memory + on-disk index of audio tracks the user has imported into
/// the library. Walks the user-picked folders, reads metadata via
/// `Track.load`, persists to `~/Library/Application Support/Minpaw/library.json`.
@MainActor
final class LibraryStore: ObservableObject {
    enum Category: String, CaseIterable, Identifiable, Codable {
        case audio = "Audio"
        case mostPlayed = "Most Played"
        case recentlyAdded = "Recently Added"
        case recentlyPlayed = "Recently Played"
        case neverPlayed = "Never Played"
        case topRated = "Top Rated"

        var id: String { rawValue }
        var displayName: String { rawValue }
        var icon: String {
            switch self {
            case .audio: return "speaker.wave.2.fill"
            case .mostPlayed: return "chart.bar.fill"
            case .recentlyAdded: return "plus.square.fill"
            case .recentlyPlayed: return "clock.fill"
            case .neverPlayed: return "questionmark.square"
            case .topRated: return "star.fill"
            }
        }
    }

    @Published var tracks: [Track] = []
    @Published var addedDates: [URL: Date] = [:]
    @Published var playCount: [URL: Int] = [:]
    @Published var lastPlayedAt: [URL: Date] = [:]
    @Published var searchText: String = ""
    @Published var selectedCategory: Category = .audio
    @Published var selectedArtist: String? = nil
    @Published var selectedAlbum: String? = nil
    @Published var indexing: Bool = false
    @Published var indexProgress: (loaded: Int, total: Int) = (0, 0)

    private var playObserver: NSObjectProtocol?

    init() {
        load()
        // Listen for plays from PlayerEngine and bump our counters.
        playObserver = NotificationCenter.default.addObserver(
            forName: .minpawTrackStartedPlaying,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor in self?.recordPlay(url: url) }
        }
    }

    deinit {
        if let playObserver { NotificationCenter.default.removeObserver(playObserver) }
    }

    /// Updates the library's view of a track's title/artist/album.
    /// Only writes to the library index — the file's on-disk metadata
    /// is left untouched (re-indexing the file would restore the
    /// original tags).
    func updateTrack(id: UUID, title: String, artist: String?, album: String?) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[idx].title = title
        tracks[idx].artist = artist
        tracks[idx].album = album
        // If the active artist/album filter no longer matches the
        // edited track's bucket, drop the filter so it doesn't vanish
        // out from under the user.
        if let selected = selectedArtist, selected != displayArtist(tracks[idx]) {
            selectedArtist = nil
        }
        if let selected = selectedAlbum, selected != displayAlbum(tracks[idx]) {
            selectedAlbum = nil
        }
        save()
    }

    func recordPlay(url: URL) {
        playCount[url, default: 0] += 1
        lastPlayedAt[url] = Date()
        save()
    }

    // MARK: - Filtered views

    var filteredByCategory: [Track] {
        switch selectedCategory {
        case .audio:
            return tracks
        case .recentlyAdded:
            return tracks.sorted {
                (addedDates[$0.url] ?? .distantPast) > (addedDates[$1.url] ?? .distantPast)
            }
        case .mostPlayed:
            return tracks
                .filter { (playCount[$0.url] ?? 0) > 0 }
                .sorted { (playCount[$0.url] ?? 0) > (playCount[$1.url] ?? 0) }
        case .recentlyPlayed:
            return tracks
                .filter { lastPlayedAt[$0.url] != nil }
                .sorted {
                    (lastPlayedAt[$0.url] ?? .distantPast) > (lastPlayedAt[$1.url] ?? .distantPast)
                }
        case .neverPlayed:
            return tracks.filter { (playCount[$0.url] ?? 0) == 0 }
        case .topRated:
            // Ratings not yet implemented — surface everything for now.
            return tracks
        }
    }

    var filteredBySearch: [Track] {
        let pool = filteredByCategory
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return pool }
        return pool.filter { track in
            track.title.lowercased().contains(q)
                || (track.artist?.lowercased().contains(q) ?? false)
                || (track.album?.lowercased().contains(q) ?? false)
        }
    }

    var artists: [String] {
        var names = Set<String>()
        for t in filteredBySearch {
            names.insert(displayArtist(t))
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var albums: [String] {
        var names = Set<String>()
        for t in filteredBySearch where matchesArtist(t) {
            names.insert(displayAlbum(t))
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func displayArtist(_ track: Track) -> String {
        trim(track.artist) ?? LibraryDefaults.unknownArtist
    }

    func displayAlbum(_ track: Track) -> String {
        trim(track.album) ?? LibraryDefaults.unknownAlbum
    }

    var visibleTracks: [Track] {
        filteredBySearch
            .filter { matchesArtist($0) && matchesAlbum($0) }
            .sorted(by: trackOrder)
    }

    var totalSizeBytes: Int64 {
        var sum: Int64 = 0
        for t in visibleTracks {
            if let size = (try? FileManager.default.attributesOfItem(atPath: t.url.path)[.size] as? NSNumber)?.int64Value {
                sum += size
            }
        }
        return sum
    }

    var totalDuration: TimeInterval {
        visibleTracks.reduce(0) { $0 + $1.duration }
    }

    // MARK: - Mutations

    func indexFolder(prompt: Bool = true) {
        guard prompt else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder to add to your library."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let urls = AudioFileFinder.expand(folder)
        guard !urls.isEmpty else { return }
        Task { await indexURLs(urls) }
    }

    func clear() {
        tracks.removeAll()
        addedDates.removeAll()
        playCount.removeAll()
        lastPlayedAt.removeAll()
        selectedArtist = nil
        selectedAlbum = nil
        save()
    }

    /// Drops the given tracks (by ID) from the library index. Each
    /// removed track's `addedDates` entry is also cleaned up so the
    /// "Recently Added" view doesn't keep referencing dead URLs.
    func remove(trackIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removedURLs = tracks.compactMap { ids.contains($0.id) ? $0.url : nil }
        tracks.removeAll { ids.contains($0.id) }
        for url in removedURLs {
            addedDates.removeValue(forKey: url)
            playCount.removeValue(forKey: url)
            lastPlayedAt.removeValue(forKey: url)
        }
        // If the active artist/album filter no longer matches anything,
        // reset it so the user is not staring at an empty pane.
        if let artist = selectedArtist, !tracks.contains(where: { $0.artist == artist }) {
            selectedArtist = nil
        }
        if let album = selectedAlbum, !tracks.contains(where: { $0.album == album }) {
            selectedAlbum = nil
        }
        save()
    }

    func reset(filters: Bool) {
        searchText = ""
        if filters {
            selectedArtist = nil
            selectedAlbum = nil
        }
    }

    private func indexURLs(_ urls: [URL]) async {
        let existing = Set(tracks.map(\.url))
        let newURLs = urls.filter { !existing.contains($0) }
        guard !newURLs.isEmpty else { return }

        indexing = true
        indexProgress = (0, newURLs.count)
        let now = Date()

        for (i, url) in newURLs.enumerated() {
            if let track = await Track.load(from: url) {
                tracks.append(track)
                addedDates[url] = now
            }
            indexProgress = (i + 1, newURLs.count)
        }

        indexing = false
        save()
    }

    // MARK: - Helpers

    private func matchesArtist(_ t: Track) -> Bool {
        guard let selected = selectedArtist else { return true }
        return displayArtist(t) == selected
    }

    private func matchesAlbum(_ t: Track) -> Bool {
        guard let selected = selectedAlbum else { return true }
        return displayAlbum(t) == selected
    }

    private func trim(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private func trackOrder(_ a: Track, _ b: Track) -> Bool {
        let ar = (a.artist ?? "").lowercased()
        let br = (b.artist ?? "").lowercased()
        if ar != br { return ar < br }
        let aa = (a.album ?? "").lowercased()
        let ba = (b.album ?? "").lowercased()
        if aa != ba { return aa < ba }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var tracks: [Track]
        var addedDates: [String: Date]
        var playCount: [String: Int]
        var lastPlayedAt: [String: Date]

        enum CodingKeys: String, CodingKey {
            case tracks, addedDates, playCount, lastPlayedAt
        }

        init(tracks: [Track],
             addedDates: [String: Date],
             playCount: [String: Int],
             lastPlayedAt: [String: Date]) {
            self.tracks = tracks
            self.addedDates = addedDates
            self.playCount = playCount
            self.lastPlayedAt = lastPlayedAt
        }

        // Custom decoder so adding new keys is non-breaking — older
        // library.json files (pre play-history) still load cleanly.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tracks = try c.decode([Track].self, forKey: .tracks)
            addedDates = try c.decodeIfPresent([String: Date].self, forKey: .addedDates) ?? [:]
            playCount = try c.decodeIfPresent([String: Int].self, forKey: .playCount) ?? [:]
            lastPlayedAt = try c.decodeIfPresent([String: Date].self, forKey: .lastPlayedAt) ?? [:]
        }
    }

    private static let storeURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Minpaw", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("library.json")
    }()

    func save() {
        let persisted = Persisted(
            tracks: tracks,
            addedDates: stringKeyed(addedDates),
            playCount: stringKeyed(playCount),
            lastPlayedAt: stringKeyed(lastPlayedAt)
        )
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: Self.storeURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        tracks = persisted.tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        addedDates = urlKeyed(persisted.addedDates)
        playCount = urlKeyed(persisted.playCount)
        lastPlayedAt = urlKeyed(persisted.lastPlayedAt)
    }

    private func stringKeyed<V>(_ dict: [URL: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: dict.map { ($0.key.absoluteString, $0.value) })
    }

    private func urlKeyed<V>(_ dict: [String: V]) -> [URL: V] {
        Dictionary(uniqueKeysWithValues: dict.compactMap { (key, value) -> (URL, V)? in
            guard let url = URL(string: key) else { return nil }
            return (url, value)
        })
    }
}
