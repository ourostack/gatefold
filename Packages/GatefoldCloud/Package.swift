// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GatefoldCloud",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "GatefoldCloud", targets: ["GatefoldCloud"]),
        .library(name: "GatefoldCloudReadium", targets: ["GatefoldCloudReadium"]),
    ],
    dependencies: [
        // Readium is iOS-only, so the adapter target links it on iOS and compiles to nothing on macOS.
        .package(url: "https://github.com/readium/swift-toolkit.git", exact: "3.11.1"),
        // One definition of a whole percent, shared with the reader.
        .package(path: "../GatefoldCore"),
    ],
    targets: [
        .target(
            name: "GatefoldCloud",
            dependencies: ["GatefoldCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GatefoldCloudReadium",
            dependencies: [
                "GatefoldCloud",
                .product(name: "ReadiumShared", package: "swift-toolkit", condition: .when(platforms: [.iOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GatefoldCloudTests",
            dependencies: ["GatefoldCloud"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GatefoldCloudReadiumTests",
            dependencies: ["GatefoldCloudReadium", "GatefoldCloud"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GatefoldCloudLiveTests",
            dependencies: ["GatefoldCloud"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
