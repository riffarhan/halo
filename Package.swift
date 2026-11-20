// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HaloAudio", path: "Sources/HaloAudio"),
        .executableTarget(name: "Halo", dependencies: ["HaloAudio"], path: "Sources/Halo"),
    ]
)
