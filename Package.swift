// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RTKMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RTKMeter", path: "Sources/RTKMeter")
    ]
)
