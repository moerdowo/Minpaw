import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MP3PlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerEngine()

    var body: some Scene {
        Window("MINPAW", id: "main") {
            ContentView()
                .environmentObject(player)
                .frame(width: 380)
                .fixedSize()
                .background(WindowChrome())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
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
