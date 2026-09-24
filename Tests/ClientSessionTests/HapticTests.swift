import Testing
@testable import VantageClientLogic

/// Connection haptics follow what you can't see: an open session dropping and coming back, or
/// giving up. Connecting and leaving are quiet because you're watching them happen.
@MainActor
struct HapticTests {
    private func play(_ states: [ClientSession.State]) -> [Haptic?] {
        var haptics = ConnectionHaptics()
        return zip(states, states.dropFirst()).map { haptics.haptic(from: $0, to: $1) }
    }

    @Test func connectingAndLeavingAreQuiet() {
        #expect(play([.idle, .connecting, .authenticating, .connected, .idle]) == [nil, nil, nil, nil])
        // The app going to the background and coming back reconnects from scratch.
        #expect(play([.connected, .suspended, .connecting, .authenticating, .connected]) == [nil, nil, nil, nil])
    }

    @Test func aDropWarnsAndTheReturnSucceeds() {
        #expect(play([.connected, .reconnecting, .reconnecting, .authenticating, .connected])
                == [.warning, nil, nil, .success])
    }

    @Test func givingUpIsAnError() {
        #expect(play([.connected, .reconnecting, .failed("Couldn’t reach the Mac.")]) == [.warning, .error])
        #expect(play([.connecting, .failed("The Mac ended the session.")]) == [.error])
    }

    /// Leaving mid-drop forgets it, so the next plain connect doesn't claim a recovery.
    @Test func leavingDuringADropForgetsIt() {
        #expect(play([.connected, .reconnecting, .idle, .connecting, .authenticating, .connected])
                == [.warning, nil, nil, nil, nil])
    }
}
