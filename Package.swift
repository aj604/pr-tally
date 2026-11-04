// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRTally",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TallyCore"),
        .target(name: "TallyUI", dependencies: ["TallyCore"]),
        .executableTarget(name: "PRTally", dependencies: ["TallyCore", "TallyUI"]),
        // Dev tool: renders the popover with live data to a PNG.
        .executableTarget(name: "PopoverSnapshot", dependencies: ["TallyCore", "TallyUI"]),
        .testTarget(name: "TallyCoreTests", dependencies: ["TallyCore"]),
        .testTarget(name: "TallyUITests", dependencies: ["TallyCore", "TallyUI"]),
    ]
)
