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
        .package(url: "https://github.com/soniqo/speech-swift", revision: "a57702e6f523fa36ac5532d2bdc5f35f701a052c")
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
            ]),
        .executableTarget(name: "TapeUp", dependencies: ["TapeUpCore", "TapeUpSpeech"]),
        .testTarget(name: "TapeUpCoreTests", dependencies: ["TapeUpCore"]),
    ]
)
