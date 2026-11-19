// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Halo", path: "Sources/Halo"),
    ]
)
