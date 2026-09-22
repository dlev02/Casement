import Foundation
import Testing
@testable import VantageClientLogic

struct TailscaleAPITests {
    @Test func decodesDevicesAndClassifiesPlatforms() throws {
        let json = """
        {"devices":[
          {"addresses":["100.64.0.5","fd7a:115c:a1e0::5"],"id":"123","nodeId":"nabc","user":"drew@example.com",
           "name":"studio.tail1234.ts.net.","hostname":"Studio","clientVersion":"1.90.1","os":"macOS",
           "lastSeen":"2026-09-22T20:00:00Z","authorized":true,"tags":["tag:home"]},
          {"addresses":["100.64.0.9"],"id":"456","name":"pc.tail1234.ts.net","hostname":"Drew-PC","os":"windows"},
          {"addresses":["100.64.0.10"],"id":"789","name":"phone.tail1234.ts.net","hostname":"","os":"iOS"}
        ]}
        """
        struct Envelope: Decodable { var devices: [TailscaleDevice] }
        let devices = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).devices
        #expect(devices.count == 3)
        #expect(devices[0].platform == .mac)
        #expect(devices[0].magicDNSName == "studio.tail1234.ts.net")
        #expect(devices[0].tailnetIPv4 == "100.64.0.5")
        #expect(devices[0].displayName == "Studio")
        #expect(devices[0].lastSeenDate != nil)
        #expect(devices[1].platform == .windows && !devices[1].platform.isSupported)
        #expect(devices[2].platform == .iOS)
        #expect(devices[2].displayName == "phone")
    }
}
