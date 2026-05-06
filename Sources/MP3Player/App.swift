import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerEngine?
    var statusBarController: StatusBarController?

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        player?.saveState()
    }
}

@main
struct MP3PlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerEngine()
    @AppStorage("showStatusBarMenulet") private var showStatusBarMenulet: Bool = true

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
                }
                .onChange(of: showStatusBarMenulet) { _, isVisible in
                    appDelegate.statusBarController?.setVisible(isVisible)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            playbackCommands
            outputCommands
            viewCommands
        }
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
