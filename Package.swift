// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapeUp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TapeUp", targets: ["TapeUp"])
    ],
    dependencies: [
        // Qwen3-ASR and Silero voice detection on MLX, Apache-2.0. Pinned:
        // scripts/bundle.sh builds MLX's shaders from this exact checkout.
        .package(url: "https://github.com/soniqo/speech-swift", revision: "a57702e6f523fa36ac5532d2bdc5f35f701a052c"),
        // Only to cap MLX's buffer cache while finding speakers; the version speech-swift resolves to.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        // Updates (MIT). scripts/bundle.sh copies its framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "TapeUpCore"),
        // The only target that touches the speech models; everything it
        // decides is in TapeUpCore, where tests reach it without a model.
        .target(
            name: "TapeUpSpeech",
            dependencies: [
                "TapeUpCore",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]),
        .executableTarget(
            name: "TapeUp",
            dependencies: ["TapeUpCore", "TapeUpSpeech", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework sits in Contents/Frameworks in the app.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "TapeUpCoreTests", dependencies: ["TapeUpCore"]),
    ]
)
