import Foundation
import Testing
import VantageCore
@testable import VantageHostSession

/// The capture lifecycle on a fake clock and a fake frame source: the rules a frozen or missing
/// picture depends on, which the loopback tests can only wait for in real time.
struct CaptureLifecycleTests {
    private let t0 = ContinuousClock.now
    private let select = SelectDisplay(selection: .fitViewport(Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)),
                                       targetFPS: 60, quality: .auto, preferredCodec: .h264)
    private let display = DisplayInfo(id: 7, name: "Studio Display", pixelWidth: 2420, pixelHeight: 1668, pointWidth: 1210, pointHeight: 834,
                                      scale: 2, originX: 0, originY: 0, isMain: true, isBuiltIn: false, isVirtual: false, refreshRate: 60)
    private let awake = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: false)
    private let asleep = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: true)

    private func starts(_ decisions: [CaptureLifecycle.Decision]) -> [CaptureLifecycle.StartRequest] {
        decisions.compactMap { if case .startCapture(let request) = $0 { request } else { nil } }
    }

    private func statuses(_ decisions: [CaptureLifecycle.Decision]) -> [HostStatus] {
        decisions.compactMap { if case .sendStatus(let status) = $0 { status } else { nil } }
    }

    /// A streaming session: the device asked, capture came up and framed.
    private func streaming() -> CaptureLifecycle {
        var lifecycle = CaptureLifecycle(restartsByDisplayID: true)
        _ = lifecycle.handle(.selectionRequested(select), now: t0)
        _ = lifecycle.handle(.statusChanged(awake), now: t0)
        _ = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: t0)
        _ = lifecycle.handle(.frameArrived, now: t0)
        return lifecycle
    }

    @Test func aRequestStartsMonitoringThenCaptureAndOnlyOneStartRunsAtATime() {
        var lifecycle = CaptureLifecycle(restartsByDisplayID: true)
        let first = lifecycle.handle(.selectionRequested(select), now: t0)
        #expect(first.first == .beginMonitoring)
        #expect(starts(first) == [CaptureLifecycle.StartRequest(targets: [select], reason: "device asked for a display", wakesSleepingDisplay: true)])
        #expect(lifecycle.isStarting)
        // A second request while starting waits, then goes out once the first reports back.
        let other = SelectDisplay(selection: .display(7), targetFPS: 30, quality: .auto)
        #expect(starts(lifecycle.handle(.selectionRequested(other), now: t0)).isEmpty)
        let after = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: t0)
        #expect(starts(after).map(\.targets) == [[other]])
        #expect(lifecycle.wanted?.targetFPS == 30)
        // While the capture hasn't framed, the watchdog ticks; once it has, it rests.
        _ = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: t0)
        #expect(lifecycle.wantsTicks)
        _ = lifecycle.handle(.frameArrived, now: t0)
        #expect(!lifecycle.wantsTicks)
    }

    @Test func sleepStopsCaptureAndWakeRestartsItWithTheSameCodec() {
        var lifecycle = streaming()
        let slept = lifecycle.handle(.statusChanged(asleep), now: t0 + .seconds(10))
        #expect(slept.contains(.stopCapture(reason: "display asleep")))
        #expect(statuses(slept) == [HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: true, isScreenUnavailable: false)])
        #expect(!lifecycle.isCapturing && lifecycle.isDisplayAsleep && !lifecycle.wantsTicks)
        // Input while asleep wakes the display instead of landing; releases still land; the moment
        // after Sleep Display is the hand that chose it.
        _ = lifecycle.handle(.sleepRequested, now: t0 + .seconds(10))
        #expect(lifecycle.admitsInput(isRelease: false, now: t0 + .seconds(11)) == .drop)
        #expect(lifecycle.admitsInput(isRelease: true, now: t0 + .seconds(11)) == .deliver)
        #expect(lifecycle.admitsInput(isRelease: false, now: t0 + .seconds(13)) == .wakeThenDrop)
        // The same asleep status again says nothing new to the device.
        #expect(statuses(lifecycle.handle(.statusChanged(asleep), now: t0 + .seconds(12))).isEmpty)

        let woke = lifecycle.handle(.statusChanged(awake), now: t0 + .seconds(20))
        #expect(statuses(woke).first?.isDisplayAsleep == false)
        let restart = try? #require(starts(woke).first)
        #expect(restart?.reason == "display woke")
        // The display it was on first, keeping the codec it was streaming, then the device's own choice.
        #expect(restart?.targets.map(\.selection) == [.display(7), select.selection])
        #expect(restart?.targets.first?.preferredCodec == .h264)
        #expect(lifecycle.admitsInput(isRelease: false, now: t0 + .seconds(20)) == .deliver)
    }

    @Test func aWakeWithCaptureStillRunningAsksForAKeyframe() {
        // The monitor said asleep while a start was under way, and the start came up anyway (the
        // panel woke before the monitor noticed): the wake has nothing to restart, so the picture
        // gets a keyframe instead.
        var lifecycle = CaptureLifecycle(restartsByDisplayID: true)
        _ = lifecycle.handle(.selectionRequested(select), now: t0)
        _ = lifecycle.handle(.statusChanged(asleep), now: t0)
        _ = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: t0 + .seconds(1))
        let woke = lifecycle.handle(.statusChanged(awake), now: t0 + .seconds(2))
        #expect(woke.contains(.requestKeyframe))
        #expect(starts(woke).isEmpty)
    }

    @Test func aMissingPictureIsRetriedWithBackoffExplainedAfterThreeSecondsAndClearedByAFrame() {
        var lifecycle = CaptureLifecycle(restartsByDisplayID: true)
        _ = lifecycle.handle(.selectionRequested(select), now: t0)
        _ = lifecycle.handle(.statusChanged(awake), now: t0)
        let failed = lifecycle.handle(.captureFailed(reason: "no displays"), now: t0)
        #expect(statuses(failed).isEmpty) // the awake status already went out, and nothing changed yet
        #expect(lifecycle.wantsTicks)

        // Retries at 0.5, 1, 2, 4, 5, 5 s after each failure.
        var now = t0
        var retriesAt: [Duration] = []
        var told: [Duration] = []
        while now - t0 < .seconds(20) {
            now += .milliseconds(250)
            let decisions = lifecycle.handle(.tick, now: now)
            if let start = starts(decisions).first {
                #expect(start.wakesDarkPanel && start.reason.hasPrefix("capture unavailable for"))
                retriesAt.append(now - t0)
                _ = lifecycle.handle(.captureFailed(reason: "no displays"), now: now)
            }
            if statuses(decisions).contains(where: { $0.isScreenUnavailable == true }) { told.append(now - t0) }
        }
        #expect(retriesAt.prefix(6) == [.milliseconds(500), .milliseconds(1500), .milliseconds(3500), .milliseconds(7500), .milliseconds(12500), .milliseconds(17500)])
        #expect(told == [.seconds(3)]) // said once, not on every tick

        // The next retry comes up and frames: the note clears, once.
        let start = lifecycle.handle(.tick, now: now + .seconds(5))
        #expect(!starts(start).isEmpty)
        _ = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: now + .seconds(5))
        let back = lifecycle.handle(.frameArrived, now: now + .seconds(6))
        #expect(statuses(back) == [HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: false, isScreenUnavailable: false)])
        #expect(!lifecycle.wantsTicks)
        #expect(statuses(lifecycle.handle(.frameArrived, now: now + .seconds(7))).isEmpty)
    }

    @Test func aCaptureThatStartsButNeverFramesCountsAsFailedAfterFiveSeconds() {
        var lifecycle = CaptureLifecycle(restartsByDisplayID: true)
        _ = lifecycle.handle(.selectionRequested(select), now: t0)
        _ = lifecycle.handle(.statusChanged(awake), now: t0)
        _ = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: t0)
        #expect(lifecycle.wantsTicks && lifecycle.isCapturing)
        #expect(lifecycle.handle(.tick, now: t0 + .seconds(4)).isEmpty)
        let gaveUp = lifecycle.handle(.tick, now: t0 + .milliseconds(5250))
        #expect(gaveUp.contains(.stopCapture(reason: "capture started but sent no frames")))
        #expect(!lifecycle.isCapturing && lifecycle.wantsTicks)
        // Then the usual watchdog: a retry half a second on, the device told at three.
        #expect(!starts(lifecycle.handle(.tick, now: t0 + .milliseconds(5750))).isEmpty)
        _ = lifecycle.handle(.captureFailed(reason: "still nothing"), now: t0 + .milliseconds(5750))
        let told = lifecycle.handle(.tick, now: t0 + .milliseconds(8250))
        #expect(statuses(told).first?.isScreenUnavailable == true)
    }

    @Test func retryFromTheDeviceStartsAtOnceAndDisplaysChangedIsDebounced() {
        var lifecycle = CaptureLifecycle(restartsByDisplayID: false)
        _ = lifecycle.handle(.selectionRequested(select), now: t0)
        _ = lifecycle.handle(.statusChanged(awake), now: t0)
        _ = lifecycle.handle(.captureFailed(reason: "no displays"), now: t0)
        let retry = lifecycle.handle(.wakeRequested, now: t0 + .milliseconds(100))
        #expect(retry.first == .wakeDisplay(reason: "Wake command"))
        // Synthetic displays are made per request: the only target is the device's own choice.
        #expect(starts(retry).first?.targets.map(\.selection) == [select.selection])
        _ = lifecycle.handle(.captureStarted(display: display, codec: .h264), now: t0 + .milliseconds(200))
        // Displays changing right after a start is the same wake; a little later it's a restart.
        #expect(starts(lifecycle.handle(.displaysChanged, now: t0 + .seconds(1))).isEmpty)
        #expect(starts(lifecycle.handle(.displaysChanged, now: t0 + .seconds(3))).first?.reason == "displays changed")
    }
}
