// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SteadyTrain",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SteadyTrain", path: "Sources/SteadyTrain")
    ]
)
