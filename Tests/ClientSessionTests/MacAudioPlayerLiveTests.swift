#if os(macOS)
import Foundation
import Testing
import VantageCore
@testable import VantageClientLogic
@testable import VantageSynthetic

/// `MacAudioPlayer` on the Mac client, through this Mac's real output device: the synthetic
/// chime, Opus-encoded like the host does, decoded and played for a few seconds. It makes sound,
/// so it's opt in: `VANTAGE_LIVE_MAC_AUDIO=1 xcrun swift test --filter MacAudioPlayerLiveTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_LIVE_MAC_AUDIO"] == "1"), .timeLimit(.minutes(1)))
@MainActor
struct MacAudioPlayerLiveTests {
    @Test func playsTheChimeAndStepsAsideForTheMicrophone() async throws {
        let player = MacAudioPlayer()
        let (packets, sink) = AsyncStream<AudioPacket>.makeStream()
        let encoder = try #require(AudioEncoder { sink.yield($0) })
        let source = SyntheticAudioSource()
        let feed = Task { @MainActor in for await packet in packets { player.handle(.audioPacket(packet)) } }
        defer { feed.cancel() }

        player.setWanted(true)
        player.handle(.audioConfig(encoder.config))
        try await source.start(onBlock: { encoder.encode($0) }, onStop: { _ in })
        try await waitFor { player.status == .playing }
        try await waitFor { player.stats.framesPlayed > 48_000 * 3 }
        let played = player.stats
        print("mac audio: played \(played.framesPlayed) frames, underruns \(played.underruns), skips \(played.skips), latency \(Int(played.milliseconds(played.smoothedDepthFrames))) ms")
        #expect(played.underruns <= 2)

        player.setMicrophoneActive(true)
        #expect(player.status == .paused)
        player.setMicrophoneActive(false)
        try await waitFor { player.status == .playing }

        await source.stop()
        player.setWanted(false)
        #expect(player.status == .off)
    }

    private func waitFor(seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
