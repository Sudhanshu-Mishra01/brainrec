// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrainRec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BrainRec",
            path: "Sources/BrainRec"
        )
    ]
)
