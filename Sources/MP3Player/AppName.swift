import Foundation
import ObjectiveC

/// Forces `Bundle.main` to report `CFBundleName` / `CFBundleDisplayName`
/// as "Minpaw" — even under `swift run`, where there is no Info.plist
/// and the system would otherwise fall back to the executable name
/// ("MP3Player"). macOS reads those bundle keys to render the bold app
/// name at the top-left of the menu bar, so just relabelling the
/// in-memory `mainMenu` items is not enough.
///
/// Bundled Minpaw.app already has `CFBundleName=Minpaw` baked into its
/// Info.plist, so the swizzle is a transparent no-op there.
enum AppName {
    static let target = "Minpaw"

    static func install() {
        // Reference the lazy `Void` so the swizzle runs exactly once.
        _ = installOnce
    }

    private static let installOnce: Void = {
        guard
            let original = class_getInstanceMethod(
                Bundle.self,
                #selector(Bundle.object(forInfoDictionaryKey:))),
            let replacement = class_getInstanceMethod(
                Bundle.self,
                #selector(Bundle.minpaw_object(forInfoDictionaryKey:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

private extension Bundle {
    @objc func minpaw_object(forInfoDictionaryKey key: String) -> Any? {
        if self === Bundle.main {
            switch key {
            case "CFBundleName", "CFBundleDisplayName":
                return AppName.target
            default:
                break
            }
        }
        // After exchange, calling `minpaw_object` actually invokes
        // the original implementation.
        return self.minpaw_object(forInfoDictionaryKey: key)
    }
}
