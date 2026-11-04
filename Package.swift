// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRTally",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TallyCore"),
        .testTarget(name: "TallyCoreTests", dependencies: ["TallyCore"]),
    ]
)
