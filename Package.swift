// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RMSMax",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "RMSMaxCore",
            targets: ["RMSMaxCore"]
        ),
        .executable(
            name: "RMSMax",
            targets: ["RMSMaxApp"]
        ),
    ],
    dependencies: [
        // Google WebRTC (BSD) as built by LiveKit: adds audio device selection, frame encryption
        // (E2E calls) and desktop capture. Media only — no telemetry endpoints.
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.08"),
        // Lottie (MIT, Airbnb): plays the animated emoji; renders locally, no network or telemetry.
        .package(url: "https://github.com/airbnb/lottie-ios.git", exact: "4.5.1"),
    ],
    targets: [
        .target(
            name: "RMSMaxCore",
            dependencies: [.product(name: "LiveKitWebRTC", package: "webrtc-xcframework")],
            path: "Sources/RMSMaxCore"
        ),
        .executableTarget(
            name: "RMSMaxApp",
            dependencies: ["RMSMaxCore", .product(name: "Lottie", package: "lottie-ios")],
            path: "Sources/RMSMaxApp"
        ),
        .testTarget(
            name: "RMSMaxCoreTests",
            dependencies: ["RMSMaxCore", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")],
            path: "Tests/RMSMaxCoreTests"
        ),
    ]
)
