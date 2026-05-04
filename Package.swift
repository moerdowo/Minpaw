// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MP3Player",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MP3Player",
            path: "Sources/MP3Player"
        )
    ]
)
