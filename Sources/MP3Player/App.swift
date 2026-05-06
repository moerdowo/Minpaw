import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerEngine?
    var statusBarController: StatusBarController?
    private var menuPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let bundleIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: bundleIcon) {
            NSApp.applicationIconImage = img
        } else {
            // swift-run path: pick up icons/AppIcon.icns next to the package
            let candidates = [
                "icons/AppIcon.icns",
                "../icons/AppIcon.icns",
                "../../icons/AppIcon.icns"
            ]
            for path in candidates {
                if let img = NSImage(contentsOfFile: path) {
                    NSApp.applicationIconImage = img
                    break
                }
            }
        }
        // Apply the rename now and again on the next runloop tick,
        // because SwiftUI sometimes installs its menu *after*
        // applicationDidFinishLaunching returns.
        renameAppMenuIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.renameAppMenuIfNeeded() }
        // Then keep enforcing it for ~3s — SwiftUI rebuilds the menu
        // when scenes appear or commands re-evaluate, and the rename
        // gets stomped each time. Polling is the simplest reliable
        // way to win that race without using private API.
        var ticks = 0
        menuPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            self?.renameAppMenuIfNeeded()
            ticks += 1
            if ticks >= 15 { timer.invalidate() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        player?.saveState()
    }

    /// Rewrites the macOS application menu to say "Minpaw" instead of
    /// the executable name (which is "MP3Player" when running via
    /// `swift run`, since SwiftPM keeps the module name). The bundled
    /// Minpaw.app already has CFBundleName=Minpaw so this is a no-op
    /// there.
    func renameAppMenuIfNeeded() {
        let target = "Minpaw"
        let current = ProcessInfo.processInfo.processName
        guard current != target,
              let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else { return }
        if appMenuItem.title != target {
            appMenuItem.title = target
        }
        if appMenu.title != target {
            appMenu.title = target
        }
        for item in appMenu.items {
            if item.title.contains(current) {
                item.title = item.title.replacingOccurrences(of: current, with: target)
            }
        }
    }
}

@main
struct MP3PlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerEngine()
    @AppStorage("showStatusBarMenulet") private var showStatusBarMenulet: Bool = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false

    var body: some Scene {
        Window("MINPAW", id: "main") {
            ContentView()
                .environmentObject(player)
                .frame(width: 380)
                .fixedSize()
                .background(WindowChrome())
                .onAppear {
                    appDelegate.player = player
                    if appDelegate.statusBarController == nil {
                        appDelegate.statusBarController = StatusBarController(player: player)
                    }
                    appDelegate.statusBarController?.setVisible(showStatusBarMenulet)
                    applyAlwaysOnTop(alwaysOnTop)
                    // SwiftUI installs its menu bar before `onAppear`,
                    // so by now we can safely retitle the app menu.
                    appDelegate.renameAppMenuIfNeeded()
                }
                .onChange(of: showStatusBarMenulet) { _, isVisible in
                    appDelegate.statusBarController?.setVisible(isVisible)
                }
                .onChange(of: alwaysOnTop) { _, on in
                    applyAlwaysOnTop(on)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Minpaw") { showAboutPanel() }
            }
            playlistFileCommands
            playbackCommands
            outputCommands
            viewCommands
        }

        Window("Lyrics", id: "lyrics") {
            LyricsView()
                .environmentObject(player)
                .frame(minWidth: 320, minHeight: 280)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 420)
    }

    @CommandsBuilder
    private var playlistFileCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Playlist…") { PlaylistFiles.openPlaylist(into: player) }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Save Playlist As…") { PlaylistFiles.savePlaylistAs(from: player) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    private func applyAlwaysOnTop(_ on: Bool) {
        for window in NSApp.windows {
            window.level = on ? .floating : .normal
        }
    }

    private func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Minpaw",
            .credits: NSAttributedString(
                string: "Native macOS MP3 player. Classic Winamp aesthetic.",
                attributes: [.foregroundColor: NSColor.labelColor,
                             .font: NSFont.systemFont(ofSize: 11)]
            ),
        ]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            options[.applicationVersion] = version
        } else {
            options[.applicationVersion] = "dev"
        }
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @CommandsBuilder
    private var viewCommands: some Commands {
        // Adds an item to the existing View menu instead of creating a
        // second one. `.toolbar` is the conventional placement at the
        // top of View; the toggle slots in cleanly above the system-
        // provided Enter Full Screen item.
        CommandGroup(after: .toolbar) {
            Toggle("Show Menu Bar Icon", isOn: $showStatusBarMenulet)
                .keyboardShortcut("M", modifiers: [.command, .shift])
            Toggle("Always on Top", isOn: $alwaysOnTop)
                .keyboardShortcut("T", modifiers: [.command, .shift])
            Divider()
            ShowLyricsCommand()
        }
    }

    @CommandsBuilder
    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Divider()
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Divider()
            Button("Seek Backward 5s") {
                player.seek(to: max(0, player.currentTime - 5))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Seek Forward 5s") {
                player.seek(to: min(player.duration, player.currentTime + 5))
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button("Volume Up") { player.volume = min(1, player.volume + 0.05) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Volume Down") { player.volume = max(0, player.volume - 0.05) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Divider()
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: [.command])
        }
    }

    @CommandsBuilder
    private var outputCommands: some Commands {
        CommandMenu("Output") {
            Button("Refresh Devices") { player.refreshOutputDevices() }
            Divider()
            ForEach(player.availableOutputDevices) { device in
                Button(action: { player.setOutputDevice(device.id) }) {
                    HStack {
                        if player.currentOutputDeviceID == device.id {
                            Text("✓ \(device.name)")
                        } else {
                            Text("    \(device.name)")
                        }
                    }
                }
            }
        }
    }
}

private struct ShowLyricsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Lyrics") { openWindow(id: "lyrics") }
            .keyboardShortcut("L", modifiers: [.command])
    }
}

private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.isMovableByWindowBackground = false
        window.title = ""
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        window.isOpaque = true
        window.hasShadow = true
    }
}
