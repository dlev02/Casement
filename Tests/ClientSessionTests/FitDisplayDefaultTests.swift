import Foundation
import Testing
@testable import VantageClientLogic

@Suite struct FitDisplayDefaultTests {
    /// A PC fits its display until the person turns it off; a Mac stays on its own display unless
    /// it was turned on. Earlier builds saved `false` on every Edit Computer save, so a stored
    /// `false` only counts once `fitDisplayChosen` says the person chose it, and an entry saved
    /// before the flag existed (or by an older build on another device) decodes as unchosen.
    @Test @MainActor func fitDisplayDefaultsOnForAPC() throws {
        #expect(SavedDevice.fitsDisplay(saved: nil, chosen: nil, platform: .windows))
        #expect(SavedDevice.fitsDisplay(saved: false, chosen: nil, platform: .windows), "an old build's false wasn't a choice")
        #expect(!SavedDevice.fitsDisplay(saved: false, chosen: true, platform: .windows), "turned off stays off")
        #expect(!SavedDevice.fitsDisplay(saved: nil, chosen: nil, platform: .macOS))
        #expect(!SavedDevice.fitsDisplay(saved: false, chosen: nil, platform: .macOS))
        #expect(SavedDevice.fitsDisplay(saved: true, chosen: nil, platform: .macOS), "a Mac turned on before the flag stays on")

        let older = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Desk PC","host":"desk.tail1234.ts.net","port":47820,"os":"Windows","connectionCount":1,"naturalScroll":true,"useVirtualDisplay":false}"#
        var device = try JSONDecoder().decode(SavedDevice.self, from: Data(older.utf8))
        #expect(device.fitDisplayChosen == nil && device.fitsDisplay(on: device.platform))
        device.useVirtualDisplay = false
        device.fitDisplayChosen = true
        let roundTrip = try JSONDecoder().decode(SavedDevice.self, from: JSONEncoder().encode(device))
        #expect(roundTrip.fitDisplayChosen == true && !roundTrip.fitsDisplay(on: .windows), "the choice survives a sync round trip")
    }
}
