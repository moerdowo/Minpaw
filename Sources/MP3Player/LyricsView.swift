import SwiftUI
import AppKit

/// Lyrics window — same Winamp chrome and LCD aesthetic as the rest of
/// the app. Reads `Track.lyrics` (USLT for ID3, ©lyr for MP4) and
/// scrolls them inside a bevelled panel that matches the playlist.
struct LyricsView: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        ZStack {
            Win.faceDark.ignoresSafeArea()
            WinampPanel(title: "MINPAW LYRICS") {
                VStack(spacing: 4) {
                    trackHeader
                    lyricsBody
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
        .background(LyricsWindowChrome())
        .preferredColorScheme(.dark)
    }

    private var trackHeader: some View {
        HStack(spacing: 0) {
            Text(headerText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreen)
                .shadow(color: Win.lcdGreen.opacity(0.55), radius: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Win.lcdBg)
        .overlay(Bevel(pressed: true))
    }

    private var lyricsBody: some View {
        Group {
            if let lyrics = player.currentTrack?.lyrics, !lyrics.isEmpty {
                ScrollView {
                    Text(lyrics)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Win.lcdGreen)
                        .shadow(color: Win.lcdGreen.opacity(0.45), radius: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .scrollContentBackground(.hidden)
            } else if player.currentTrack == nil {
                placeholder("PLAY A TRACK TO SEE LYRICS HERE")
            } else {
                placeholder("THIS TRACK HAS NO EMBEDDED LYRICS")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Win.lcdBg)
        .overlay(Bevel(pressed: true))
    }

    private var headerText: String {
        guard let track = player.currentTrack else { return "NO TRACK LOADED" }
        if let artist = track.artist, !artist.isEmpty {
            return "\(artist) - \(track.title)"
        }
        return track.title
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Win.lcdGreenDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window chrome (matches the main window's look but stays resizable)

private struct LyricsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { LyricsChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class LyricsChromeView: NSView {
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
        // Keep `.resizable` in the styleMask so the user can size the
        // lyrics window — unlike the fixed-size main window.
    }
}
