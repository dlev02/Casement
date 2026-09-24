import AppKit
import CoreGraphics
import Testing
import VantageCore

/// Every event the host posts carries `VantageProtocol.injectedEventMarker`.
@Suite struct InjectedEventMarkerTests {
    /// A same-Mac client recognizes the host's events by this stamp; it has to survive the trip
    /// from a CGEvent to the NSEvent AppKit hands the client.
    @Test func markerSurvivesIntoNSEvent() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x0C, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: VantageProtocol.injectedEventMarker)
        let nsEvent = try #require(NSEvent(cgEvent: event))
        #expect(nsEvent.cgEvent?.getIntegerValueField(.eventSourceUserData) == VantageProtocol.injectedEventMarker)
    }
}
