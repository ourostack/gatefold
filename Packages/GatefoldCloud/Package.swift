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
        // Our fork, on the same revision as the app (project.yml): 3.11.1 plus #109's release fix.
        .package(url: "https://github.com/ourostack/swift-toolkit.git", revision: "a0eb21330d0f8c37476859922bd967073e7b73f4"),
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
