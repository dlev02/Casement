import Foundation
import Testing
@testable import VantageCore

/// `isDisplayAsleep` is optional so hosts and clients of either age keep understanding each other.
@Suite struct HostStatusTests {
    @Test func olderHostStatusDecodesWithoutTheDisplayField() throws {
        let old = Data(#"{"isScreenLocked":false,"isSecureInputActive":true,"inputPath":"native","message":"typing is blocked"}"#.utf8)
        guard case .hostStatus(let status) = try Message.decode(kind: .hostStatus, payload: old) else {
            Issue.record("wrong kind"); return
        }
        #expect(status.isSecureInputActive && status.isDisplayAsleep == nil && status.isScreenUnavailable == nil)
    }

    @Test func screenUnavailableRoundTrips() throws {
        let waiting = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native,
                                 isDisplayAsleep: false, isScreenUnavailable: true)
        guard case .hostStatus(let back) = try Message.decode(kind: .hostStatus, payload: try Message.hostStatus(waiting).encodedPayload()) else {
            Issue.record("wrong kind"); return
        }
        #expect(back == waiting)
    }

    @Test func asleepRoundTripsAndOlderClientsIgnoreIt() throws {
        let asleep = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: true)
        let payload = try Message.hostStatus(asleep).encodedPayload()
        guard case .hostStatus(let back) = try Message.decode(kind: .hostStatus, payload: payload) else {
            Issue.record("wrong kind"); return
        }
        #expect(back == asleep)

        // What a client built before the field existed decodes: the same JSON minus the new key.
        struct OlderHostStatus: Decodable { var isScreenLocked: Bool; var isSecureInputActive: Bool; var inputPath: HostInputPath; var message: String? }
        let older = try JSONDecoder().decode(OlderHostStatus.self, from: payload)
        #expect(!older.isScreenLocked && !older.isSecureInputActive && older.inputPath == .native)
    }

    @Test func awakeHostsLeaveNoTraceForOldClients() throws {
        let status = HostStatus(isScreenLocked: true, isSecureInputActive: false, inputPath: .native, message: "The Mac is locked")
        let json = try #require(String(data: try Message.hostStatus(status).encodedPayload(), encoding: .utf8))
        #expect(!json.contains("isDisplayAsleep")) // nil isn't written at all
    }
}
