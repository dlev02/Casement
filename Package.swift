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
                sources: ["Net/ClientSession.swift", "Model/SavedDevice.swift", "Model/ControlStripLayout.swift", "Model/SessionPreferences.swift", "Net/HostAvailability.swift", "Input/InputController.swift", "Input/CharacterKeyMap.swift", "Net/TailscaleAPI.swift", "Model/ClientOptions.swift", "Model/CloudSync.swift", "Model/DeviceSecrets.swift", "Model/Dictation.swift", "Dictation/AudioResampler.swift",
                    "Audio/OpusDecoder.swift", "Audio/AudioJitterBuffer.swift"],
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
        .testTarget(name: "ClientSessionTests", dependencies: ["VantageClientLogic", "VantageSynthetic", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/ClientSessionTests"),
        .testTarget(name: "HostDictationTests", dependencies: ["VantageHostDictation", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostDictationTests")
    ]
)
