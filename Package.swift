// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vox",
            path: "Sources/Vox"
        )
    ],
    swiftLanguageVersions: [.v5]
)
