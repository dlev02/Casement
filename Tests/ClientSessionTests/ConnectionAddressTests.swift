import Testing
@testable import VantageClientLogic

@MainActor struct ConnectionAddressTests {
    @Test func acceptsPastedEndpointsAndIPv6() throws {
        let pasted = try ConnectionAddress(host: " 100.100.100.100:47821\n", port: "47820")
        #expect(pasted.host == "100.100.100.100")
        #expect(pasted.port == 47821)
        #expect(try ConnectionAddress(host: "studio.example.ts.net", port: "47820").host == "studio.example.ts.net")
        #expect(try ConnectionAddress(host: "[fd7a:115c:a1e0::1]:47821", port: "47820").port == 47821)
        #expect(try ConnectionAddress(host: "fd7a:115c:a1e0::1", port: "47820").host == "fd7a:115c:a1e0::1")
    }

    @Test func rejectsMalformedAddressesAndPorts() {
        for host in ["", "host name", "https://host", "host/path", "user@host", "[bad]:47820", "host:", "host:0", "host:65536"] {
            #expect(throws: (any Error).self) { try ConnectionAddress(host: host, port: "47820") }
        }
        for port in ["", "0", "-1", "65536", "abc"] {
            #expect(throws: (any Error).self) { try ConnectionAddress(host: "host", port: port) }
        }
    }
}
