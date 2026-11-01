// swift-tools-version: 6.2
import PackageDescription

// Pure reading logic for Gatefold: layout per posture, the reading anchor that holds the place
// through every fold, preferences, themes, scrubber math and the "further ahead" suggestion.
// No UIKit and no Readium, so it tests on the Mac in seconds.
let package = Package(
    name: "GatefoldCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "GatefoldCore", targets: ["GatefoldCore"])],
    targets: [
        .target(name: "GatefoldCore"),
        .testTarget(name: "GatefoldCoreTests", dependencies: ["GatefoldCore"]),
    ]
)
