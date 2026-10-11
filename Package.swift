// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tokometer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tokometer",
            path: "Sources/Tokometer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
