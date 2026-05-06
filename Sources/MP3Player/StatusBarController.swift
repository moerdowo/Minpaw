import AppKit
import Combine

/// Drives the menu-bar icon. Click → menu with current track + transport
/// + a few quick toggles. Updates dynamically via Combine subscriptions
/// to PlayerEngine's @Published properties.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let player: PlayerEngine
    private let item: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(player: PlayerEngine) {
        self.player = player
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = makeIconImage()
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // Refresh title/menu whenever relevant state changes.
        Publishers.Merge4(
            player.$isPlaying.map { _ in () },
            player.$currentIndex.map { _ in () },
            player.$tracks.map { _ in () },
            player.$sleepTimerEnd.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refreshTitle() }
        .store(in: &cancellables)

        refreshTitle()
    }

    deinit {
        // status item is auto-removed via system on app termination
    }

    func setVisible(_ visible: Bool) {
        item.isVisible = visible
    }

    // MARK: - Title

    private func refreshTitle() {
        guard let button = item.button else { return }
        if let track = player.currentTrack {
            let prefix = player.isPlaying ? "▶ " : "❚❚ "
            let label: String
            if let artist = track.artist, !artist.isEmpty {
                label = "\(artist) — \(track.title)"
            } else {
                label = track.title
            }
            // Trim long titles so the menu bar doesn't push other items off.
            button.title = " " + prefix + truncate(label, max: 30)
        } else {
            button.title = ""
        }
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        return s.prefix(max - 1) + "…"
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        // Header line — current track (disabled, info only).
        let header: String
        if let track = player.currentTrack {
            let artist = (track.artist?.isEmpty == false) ? "\(track.artist!) — " : ""
            header = "\(artist)\(track.title)"
        } else {
            header = "No track loaded"
        }
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if player.currentTrack != nil {
            let timeItem = NSMenuItem(
                title: "  \(formatTime(player.currentTime)) / \(formatTime(player.duration))",
                action: nil,
                keyEquivalent: ""
            )
            timeItem.isEnabled = false
            menu.addItem(timeItem)
        }

        menu.addItem(.separator())

        // Transport.
        let playPause = NSMenuItem(
            title: player.isPlaying ? "Pause" : "Play",
            action: #selector(togglePlay),
            keyEquivalent: " "
        )
        playPause.keyEquivalentModifierMask = []
        playPause.target = self
        menu.addItem(playPause)

        let prev = NSMenuItem(title: "Previous", action: #selector(playerPrev),
                              keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prev.keyEquivalentModifierMask = [.command]
        prev.target = self
        menu.addItem(prev)

        let next = NSMenuItem(title: "Next", action: #selector(playerNext),
                              keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        next.keyEquivalentModifierMask = [.command]
        next.target = self
        menu.addItem(next)

        let stop = NSMenuItem(title: "Stop", action: #selector(playerStop),
                              keyEquivalent: ".")
        stop.keyEquivalentModifierMask = [.command]
        stop.target = self
        menu.addItem(stop)

        menu.addItem(.separator())

        if let end = player.sleepTimerEnd {
            let remaining = max(0, Int(end.timeIntervalSinceNow / 60))
            let sleep = NSMenuItem(
                title: "Sleep timer: \(remaining) min remaining (cancel)",
                action: #selector(cancelSleepTimer),
                keyEquivalent: ""
            )
            sleep.target = self
            menu.addItem(sleep)
        }

        // Show window / Quit.
        let show = NSMenuItem(title: "Show Window",
                              action: #selector(showWindow),
                              keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let quit = NSMenuItem(title: "Quit Minpaw",
                              action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func togglePlay() { player.togglePlay() }
    @objc private func playerPrev() { player.previous() }
    @objc private func playerNext() { player.next() }
    @objc private func playerStop() { player.stop() }
    @objc private func cancelSleepTimer() { player.setSleepTimer(minutes: nil) }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the main window forward.
        for window in NSApp.windows where window.isVisible == false {
            window.makeKeyAndOrderFront(nil)
        }
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Helpers

    private func makeIconImage() -> NSImage? {
        // Use the embedded app icon if present, otherwise a music-note SF symbol.
        if let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Minpaw") {
            icon.isTemplate = true
            return icon
        }
        return nil
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
