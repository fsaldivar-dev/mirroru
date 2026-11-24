// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mirroru",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "mirroru", path: "Sources/mirroru"),
    ]
)
