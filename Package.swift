// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RTKMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RTKMeter", path: "Sources/RTKMeter")
    ]
)
