import Foundation
import Testing
@testable import VantageClientLogic

/// The same Mac saved separately on two devices has to end up as one entry, under one id, on
/// both: otherwise edits never sync and secrets kept under the id are never found.
@MainActor @Suite struct DeviceMergeTests {
    let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!

    @Test func twoDevicesConvergeOnTheLowerIDWithTheNewerSettings() {
        let older = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)
        // The iPad added it as "studio.example.ts.net" first; the iPhone as "Studio.example.ts.net." later, and renamed it.
        let onIPad = SavedDevice(id: high, name: "Studio", host: "studio.example.ts.net", updatedAt: older)
        let onIPhone = SavedDevice(id: low, name: "Studio Mac", host: "Studio.example.ts.net.", updatedAt: newer)

        // iCloud has the iPad's list; the iPhone merges it and keeps its own id (the lower one).
        let iPhone = DeviceMerge.merge(local: [onIPhone], remote: [onIPad])
        #expect(iPhone.devices == [onIPhone])
        #expect(iPhone.replaced.isEmpty)
        #expect(iPhone.remoteNeedsUpdate) // iCloud still has the iPad's id

        // The iPhone's list reaches the iPad: it takes the id and the newer settings, and its secrets follow.
        let iPad = DeviceMerge.merge(local: [onIPad], remote: iPhone.devices)
        #expect(iPad.devices == [onIPhone])
        #expect(iPad.replaced == [.init(old: onIPad, new: onIPhone)])
        #expect(!iPad.remoteNeedsUpdate)

        // Settled: another round changes nothing either way.
        let again = DeviceMerge.merge(local: iPad.devices, remote: iPhone.devices)
        #expect(again == .init(devices: [onIPhone], replaced: [], remoteNeedsUpdate: false))
    }

    @Test func aMatchingHostKeyIsTheSameComputerAtAnyAddress() {
        let key = Data(repeating: 7, count: 32)
        let byName = SavedDevice(id: high, name: "Studio", host: "studio.example.ts.net", hostPublicKey: key)
        let byIP = SavedDevice(id: low, name: "Studio", host: "100.64.0.7", hostPublicKey: key)
        let other = SavedDevice(name: "Office", host: "office.example.ts.net")
        let result = DeviceMerge.merge(local: [byName], remote: [byIP, other])
        #expect(result.devices.map(\.id) == [low, other.id])
        #expect(result.replaced.map(\.old.id) == [high])
    }
}
