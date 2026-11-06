// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapeUp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TapeUp", targets: ["TapeUp"])
    ],
    targets: [
        .target(name: "TapeUpCore"),
        .executableTarget(name: "TapeUp", dependencies: ["TapeUpCore"]),
        .testTarget(name: "TapeUpCoreTests", dependencies: ["TapeUpCore"]),
    ]
)
