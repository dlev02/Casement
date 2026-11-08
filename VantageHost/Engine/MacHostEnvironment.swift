import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VantageCore
import os

/// The real Mac behind a `HostSession`: ScreenCaptureKit displays and capture, a BetterDisplay
/// virtual display, the power assertion and `pmset`, the lock monitor, CGEvent input, the
/// pasteboard, the Mac's sound, the curtain, dictation engines and the Tailscale CLI.
nonisolated enum MacHostEnvironment {
    static func make(hostName: String, platform: HostPlatform, allowsSelfCurtain: Bool,
                     fileDestination: @escaping @Sendable () -> FileDestination, captureFailsFor: Duration?) -> HostEnvironment {
        HostEnvironment(hostName: hostName, platform: platform,
                        screen: MacScreen(),
                        screenRecordingGranted: { ScreenCapture.preflightPermission() },
                        accessibilityGranted: { InputInjector.hasPermission() },
                        makePower: { MacPower() },
                        makeStatusMonitor: { LockMonitor() },
                        makeInputSink: { frame in
                            #if DEBUG
                            InputEventLog.startIfRequested()
                            #endif
                            return InputInjector(displayFrame: frame)
                        },
                        makeClipboard: { ClipboardBridge() },
                        audio: MacAudio(), curtain: MacCurtain(allowsSelfCurtain: allowsSelfCurtain),
                        dictation: MacDictation(), peers: TailscalePeers(),
                        fileDestination: fileDestination, captureFailsFor: captureFailsFor, clock: SystemHostClock())
    }
}

/// ScreenCaptureKit's displays, with a virtual display fitted to the viewport when asked for.
nonisolated struct MacScreen: HostScreen {
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "session")

    var canRestartByDisplayID: Bool { true }
    var canManageVirtualDisplay: Bool { VirtualDisplayManager().isAvailable }

    func displays() async throws -> [DisplayInfo] {
        try await DisplayEnumerator.shareableDisplays().map(\.info)
    }

    func resolve(_ select: SelectDisplay) async throws -> DisplayInfo {
        let all = try await DisplayEnumerator.shareableDisplays()
        let mainID = CGMainDisplayID()
        if all.isEmpty { Self.log.error("ScreenCaptureKit lists no displays (main \(mainID), asleep \(DisplayPower.isAsleep()))") }
        switch select.selection {
        case .display(let id):
            guard let match = all.first(where: { $0.info.id == id }) else { throw CaptureError.displayNotFound }
            return match.info
        case .fitViewport(let viewport):
            // Only provision a virtual display when the client asked for one. The default path
            // must never wait on BetterDisplay: it costs the whole connect time.
            var virtualMatch: DisplayInfo?
            if select.useVirtualDisplay == true {
                // A display that already matches the viewport (for example a BetterDisplay screen
                // the user set up by hand) is used as-is; only otherwise ask the CLI.
                let wantedWidth = viewport.pixelWidth / 2, wantedHeight = viewport.pixelHeight / 2
                if let existing = all.first(where: { !$0.info.isBuiltIn && $0.info.pointWidth == wantedWidth && $0.info.pointHeight == wantedHeight }) {
                    virtualMatch = existing.info
                    Self.log.info("using existing display \(existing.info.id) that already matches the viewport")
                }
                let vdm = VirtualDisplayManager()
                if virtualMatch != nil {
                    // Nothing to provision.
                } else if vdm.isAvailable {
                    let started = MonotonicClock.nanos()
                    if let virtualID = try? await vdm.provision(pointWidth: viewport.pixelWidth / 2, pointHeight: viewport.pixelHeight / 2),
                       let match = try? await DisplayEnumerator.shareableDisplays().first(where: { $0.info.id == virtualID }) {
                        virtualMatch = match.info
                    } else {
                        Self.log.error("virtual display unavailable after \((MonotonicClock.nanos() - started) / 1_000_000) ms; using the main display")
                    }
                } else {
                    Self.log.info("virtual display requested but BetterDisplay CLI is not installed; using the main display")
                }
            }
            if let virtualMatch { return virtualMatch }
            if let match = all.first(where: { $0.info.id == mainID }) ?? all.first { return match.info }
            throw CaptureError.displayNotFound
        }
    }

    func makeCapture(for display: DisplayInfo, fps: Int, excludingClientOnThisComputer: Bool) -> any FrameSource {
        // A client on this same Mac (loopback, DEBUG builds only) is left out of the picture, or
        // its window would show itself showing itself.
        var excluded: [String] = []
        #if DEBUG
        if excludingClientOnThisComputer { excluded = AudioCapture.clientBundleIDs }
        #endif
        return ScreenCapture(displayID: display.id, pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight, fps: fps,
                             excludingBundleIDs: excluded)
    }

    func restoreDisplays() async {
        VirtualDisplayManager().disconnect()
    }
}

/// The session's power assertion, `IOPMAssertionDeclareUserActivity`, `pmset displaysleepnow`
/// and `SACLockScreenImmediate`.
nonisolated final class MacPower: HostPowerControl {
    private let manager = PowerManager()

    func keepAwake() { manager.begin() }
    func releaseKeepAwake() { manager.end() }

    @discardableResult
    func wakeDisplay(reason: String, minimumInterval: Duration) -> Bool {
        manager.wakeDisplay(reason: reason, minimumInterval: minimumInterval)
    }

    func sleepDisplay() { HostCommandRunner.sleepDisplay() }
    func lockScreen() { HostCommandRunner.lockScreen() }
    var isDisplayAsleep: Bool { DisplayPower.isAsleep() }
    var panel: (isOff: Bool, text: String) { DisplayPower.panelDescription() }
}

extension LockMonitor: HostStatusMonitor {}
extension InputInjector: InputSink {}
extension ClipboardBridge: HostClipboard {}

nonisolated struct MacAudio: HostAudio {
    func makeSource() -> any AudioSource { AudioCapture() }
    func message(for error: any Error) -> String { AudioCapture.message(for: error) }
}

/// `ScreenCurtain.shared`, plus the rule that a client on this same Mac can't raise it (it could
/// never get the Mac back) unless DEBUG `--allow-self-curtain` says so.
nonisolated struct MacCurtain: HostCurtain {
    let allowsSelfCurtain: Bool

    func adopt(_ holder: ObjectIdentifier, notify: @escaping @Sendable (CurtainStatus) -> Void) async -> Bool {
        await ScreenCurtain.shared.adopt(holder, notify: notify)
    }

    func set(_ wanted: Bool, for holder: ObjectIdentifier, fromThisComputer: Bool,
             notify: @escaping @Sendable (CurtainStatus) -> Void) async -> String? {
        if wanted, fromThisComputer, !allowsSelfCurtain { return "Curtain can't cover the Mac you're using it from." }
        return await ScreenCurtain.shared.set(wanted, for: holder, notify: notify)
    }

    func sessionEnded(_ holder: ObjectIdentifier) async {
        await ScreenCurtain.shared.sessionEnded(holder)
    }
}

nonisolated struct MacDictation: DictationService {
    func availableEngines() async -> [DictationEngineID] { await HostTranscriber.availableEngines() }

    func transcribe(samples: Data, requested: DictationEngineID?, language: String?) async -> DictationOutcome {
        do {
            let output = try await HostTranscriber.live().transcribe(samples: samples, requested: requested, language: language)
            return .text(output.text, engine: output.engine)
        } catch {
            return .failed(error.message)
        }
    }
}

nonisolated struct TailscalePeers: PeerDirectory {
    func userName(ofPeer address: String) -> String? { TailscaleCLI.whois(addr: address) }
    func deviceName(ofPeer host: String) -> String? { TailscaleCLI.deviceName(host: host) }
}
