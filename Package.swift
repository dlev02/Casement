// swift-tools-version: 6.2
import PackageDescription

// Host-independent client regression tests; the shipping apps remain Xcode targets.
let package = Package(
    name: "VantageChecks",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "Packages/VantageCore")],
    targets: [
        .target(name: "VantageClientLogic", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "Vantage", exclude: ["Assets.xcassets", "ContentView.swift", "VantageApp.swift", "UI", "Video",
                    "Input/RemoteInteractionView.swift", "Model/ClipboardSync.swift",
                    "Model/DeviceStore.swift", "Net/TailscaleReachability.swift"],
                sources: ["Net/ClientSession.swift", "Model/SavedDevice.swift", "Model/SessionPreferences.swift", "Net/HostAvailability.swift", "Input/InputController.swift", "Input/CharacterKeyMap.swift", "Net/TailscaleAPI.swift", "Model/ClientOptions.swift"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "VantageSynthetic", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/Engine", exclude: ["AdaptiveController.swift", "DisplayEnumerator.swift", "HostController.swift",
                    "HostOptions.swift", "HostSession.swift", "ScreenCapture.swift", "VideoEncoder.swift"],
                sources: ["SyntheticFrameSource.swift", "FrameSource.swift", "MonotonicClock.swift"]),
        .testTarget(name: "ClientSessionTests", dependencies: ["VantageClientLogic", "VantageSynthetic", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/ClientSessionTests")
    ]
)
