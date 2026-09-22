import Foundation
import Testing
@testable import VantageCore

// Mirror of the host AdaptiveController for logic coverage in the shared test target.
// (The real type lives in the host target; this verifies the QualityFeedback shape it depends on.)
@Test func qualityFeedbackRoundTrips() throws {
    let feedback = QualityFeedback(rttMillis: 12, decodeMillis: 4, framesReceived: 100, framesDropped: 2, queueDepth: 3, bytesReceived: 999, windowSeconds: 0.25)
    let payload = try Message.qualityFeedback(feedback).encodedPayload()
    guard case .qualityFeedback(let back) = try Message.decode(kind: .qualityFeedback, payload: payload) else {
        Issue.record("wrong kind"); return
    }
    #expect(back.framesDropped == 2)
    #expect(back.queueDepth == 3)
}
