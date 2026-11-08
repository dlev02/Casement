// swift-tools-version: 6.2
import PackageDescription

// Host-independent client regression tests; the shipping apps remain Xcode targets.
let package = Package(
    name: "VantageChecks",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "Packages/VantageCore")],
    targets: [
        .target(name: "VantageClientLogic", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "Vantage", exclude: ["Assets.xcassets", "en.lproj", "ContentView.swift", "VantageApp.swift", "UI", "Video",
                    "Input/RemoteInteractionView.swift",
                    "Model/DeviceStore.swift", "Net/TailscaleReachability.swift"],
                sources: ["Net/ClientSession.swift", "Model/SavedDevice.swift", "Model/ControlStripLayout.swift", "Model/SessionPreferences.swift", "Net/HostAvailability.swift", "Input/InputController.swift", "Input/PointerMapping.swift", "Model/Haptic.swift", "Input/CharacterKeyMap.swift", "Net/TailscaleAPI.swift", "Model/ClientOptions.swift", "Model/CloudSync.swift", "Model/DeviceSecrets.swift", "Model/Dictation.swift", "Model/HostShortcut.swift", "Model/HostNoun.swift", "Input/KeyRemap.swift", "Dictation/AudioResampler.swift",
                    "Audio/OpusDecoder.swift", "Audio/AudioJitterBuffer.swift", "Transfer/FileTransferController.swift", "Transfer/SharedFileInbox.swift",
                    "Transfer/FileLink.swift", "Transfer/FileTransferCenter.swift",
                    "Model/LocalDevice.swift", "Model/ClipboardSync.swift", "Audio/MacAudioPlayer.swift",
                    "Input/KeyTranslator.swift", "Input/KeyCapturePolicy.swift", "Input/ScrollTranslator.swift"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        // The Mac host's session (`HostSession`) with the synthetic stand-ins it runs on in tests
        // (`SyntheticHostEnvironment`: pretend display, test pattern, chime), its encoder and
        // adaptive controller, and dictation clip buffering. Nothing here touches ScreenCaptureKit,
        // the Keychain, launch options or a real display, so loopback tests can drive the same
        // session code the app ships.
        .target(name: "VantageHostSession", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost", exclude: ["en.lproj", "Assets.xcassets", "CasementHost.icon", "Info.plist", "VantageHost.entitlements"],
                sources: ["Engine/HostSession.swift", "Engine/HostEnvironment.swift", "Engine/SyntheticHostEnvironment.swift", "Engine/CaptureLifecycle.swift", "Engine/VideoPacer.swift",
                          "Engine/SyntheticFrameSource.swift", "Engine/FrameSource.swift", "Engine/MonotonicClock.swift",
                          "Engine/VideoEncoder.swift", "Engine/AdaptiveController.swift",
                          "Engine/AudioSource.swift", "Engine/SyntheticAudioSource.swift", "Engine/AudioEncoder.swift",
                          "Dictation/DictationClip.swift"]),
        // Host dictation (WAV, MacWhisper `mw` and SpeechAnalyzer runners).
        .target(name: "VantageHostDictation", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/Dictation", sources: ["HostTranscriber.swift", "WAVFile.swift"]),
        // Host keyboard sequencing and scroll momentum: the events the injector posts.
        .target(name: "VantageHostInput", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/Input", sources: ["KeyboardSequencer.swift", "ScrollMomentum.swift"]),
        .testTarget(name: "ClientSessionTests", dependencies: ["VantageClientLogic", "VantageHostSession", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/ClientSessionTests"),
        // The Mac host's session over loopback with synthetic adapters: handshake, stream start,
        // display sleep and wake, a missing picture.
        .testTarget(name: "HostSessionTests", dependencies: ["VantageHostSession", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostSessionTests"),
        .testTarget(name: "HostInputTests", dependencies: ["VantageHostInput", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostInputTests"),
        .testTarget(name: "HostDictationTests", dependencies: ["VantageHostDictation", "VantageHostSession", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostDictationTests"),
        // What the host does when files arrive (settings, batching, auto-open safety, wording).
        .target(name: "VantageHostFiles", path: "VantageHost/Transfer",
                exclude: ["FileArrivals.swift", "HostFileStore.swift", "HostNotifications.swift", "HostTransfer.swift"],
                sources: ["FileArrival.swift"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "HostFileArrivalTests", dependencies: ["VantageHostFiles"], path: "Tests/HostFileArrivalTests"),
        // When the host checks for and installs updates, and how the Updates row words each state.
        .target(name: "VantageHostUpdates", path: "VantageHost/Updates", sources: ["UpdatePolicy.swift", "UpdateRow.swift"]),
        .testTarget(name: "HostUpdateTests", dependencies: ["VantageHostUpdates"], path: "Tests/HostUpdateTests"),
        // The host's pasteboard bridge (change polling, applying the client's clipboard).
        .target(name: "VantageHostClipboard", dependencies: [.product(name: "VantageCore", package: "VantageCore")],
                path: "VantageHost/System", sources: ["ClipboardBridge.swift"]),
        .testTarget(name: "HostClipboardTests", dependencies: ["VantageHostClipboard", .product(name: "VantageCore", package: "VantageCore")],
                    path: "Tests/HostClipboardTests")
    ]
)
