// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VantageCore",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "VantageCore", targets: ["VantageCore"]),
    ],
    targets: [
        .target(
            name: "VantageCore",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "VantageCoreTests",
            dependencies: ["VantageCore"]
        ),
    ]
)
