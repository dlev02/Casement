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
                    "Input/RemoteInteractionView.swift",
                    "Model/DeviceStore.swift", "Net/TailscaleReachability.swift"],
                sources: ["Net/ClientSession.swift", "Model/SavedDevice.swift", "Model/ControlStripLayout.swift", "Model/SessionPreferences.swift", "Net/HostAvailability.swift", "Input/InputController.swift", "Input/PointerMapping.swift", "Model/Haptic.swift", "Input/CharacterKeyMap.swift", "Net/TailscaleAPI.swift", "Model/ClientOptions.swift", "Model/CloudSync.swift", "Model/DeviceSecrets.swift", "Model/Dictation.swift", "Model/MacShortcut.swift", "Dictation/AudioResampler.swift",
                    "Audio/OpusDecoder.swift", "Audio/AudioJitterBuffer.swift", "Transfer/FileTransferController.swift", "Transfer/SharedFileInbox.swift",
                    "Transfer/FileLink.swift", "Transfer/FileTransferCenter.swift",
                    "Model/ClipboardSync.swift"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "VantageSynthetic", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/Engine", exclude: ["AdaptiveController.swift", "DisplayEnumerator.swift", "HostController.swift",
                    "HostOptions.swift", "HostSession.swift", "ScreenCapture.swift", "VideoEncoder.swift", "AudioCapture.swift"],
                // Also the host's audio path minus ScreenCaptureKit, so loopback tests can stream the synthetic chime.
                sources: ["SyntheticFrameSource.swift", "FrameSource.swift", "MonotonicClock.swift",
                          "AudioSource.swift", "SyntheticAudioSource.swift", "AudioEncoder.swift"]),
        // Host dictation (clip buffering, WAV, MacWhisper `mw` and SpeechAnalyzer runners).
        .target(name: "VantageHostDictation", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/Dictation"),
        // Host keyboard sequencing: the events the injector posts for each key and chord.
        .target(name: "VantageHostInput", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/Input", sources: ["KeyboardSequencer.swift"]),
        .testTarget(name: "ClientSessionTests", dependencies: ["VantageClientLogic", "VantageSynthetic", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/ClientSessionTests"),
        .testTarget(name: "HostInputTests", dependencies: ["VantageHostInput", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostInputTests"),
        .testTarget(name: "HostDictationTests", dependencies: ["VantageHostDictation", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostDictationTests"),
        // What the host does when files arrive (settings, batching, auto-open safety, wording).
        .target(name: "VantageHostFiles", path: "VantageHost/Transfer",
                exclude: ["FileArrivals.swift", "HostFileStore.swift", "HostNotifications.swift", "HostTransfer.swift"],
                sources: ["FileArrival.swift"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "HostFileArrivalTests", dependencies: ["VantageHostFiles"], path: "Tests/HostFileArrivalTests"),
        // The host's pasteboard bridge (change polling, applying the client's clipboard).
        .target(name: "VantageHostClipboard", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/System", sources: ["ClipboardBridge.swift"]),
        .testTarget(name: "HostClipboardTests", dependencies: ["VantageHostClipboard", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostClipboardTests")
    ]
)
