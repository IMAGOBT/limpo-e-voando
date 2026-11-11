// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ImagoCare",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ImagoCare", path: "Sources/ImagoCare")
    ]
)
