import Foundation
import AppKit

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
    @Published var searchText: String = ""
    @Published var selectedCategory: Category = .audio
    @Published var selectedArtist: String? = nil
    @Published var selectedAlbum: String? = nil
    @Published var indexing: Bool = false
    @Published var indexProgress: (loaded: Int, total: Int) = (0, 0)

    init() {
        load()
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
        case .mostPlayed, .recentlyPlayed, .neverPlayed, .topRated:
            // Play history / ratings not yet tracked. Surface the same
            // catalog as Audio for now so the rows are not blank.
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
        let names = Set(filteredBySearch.compactMap { trim($0.artist) })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var albums: [String] {
        let pool = filteredBySearch.filter { matchesArtist($0) }
        let names = Set(pool.compactMap { trim($0.album) })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        selectedArtist = nil
        selectedAlbum = nil
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
        return trim(t.artist) == selected
    }

    private func matchesAlbum(_ t: Track) -> Bool {
        guard let selected = selectedAlbum else { return true }
        return trim(t.album) == selected
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
        let datesByString = Dictionary(uniqueKeysWithValues:
            addedDates.map { ($0.key.absoluteString, $0.value) })
        let persisted = Persisted(tracks: tracks, addedDates: datesByString)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: Self.storeURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        // Drop tracks whose files no longer exist on disk.
        tracks = persisted.tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let datesByURL = persisted.addedDates.compactMap { (key, value) -> (URL, Date)? in
            guard let url = URL(string: key) else { return nil }
            return (url, value)
        }
        addedDates = Dictionary(uniqueKeysWithValues: datesByURL)
    }
}
