import Foundation
import Network
import XCTest

/// The synthetic Vantage Host a Mac UI test suite talks to.
///
/// The `VantageMacUITests` scheme's test pre-action starts them (`scripts/mac-ui-test-hosts.sh`):
/// the `VantageHost.app` built beside the tests, run from its executable with `--synthetic-capture`,
/// port 47856 or 47857, pairing code 246810 and `--exit-after`; the post-action stops them. The
/// tests can't start them: macOS runs the UI test runner in a sandbox, so a host it spawns
/// inherits the sandbox and can't listen, and one it opens through LaunchServices loses its
/// arguments (that left real hosts without `--port` fighting the live one on 47820).
///
/// `TEST_RUNNER_<variable>=127.0.0.1:<port>` points a suite at another host that's already up.
nonisolated enum SyntheticHost {
    /// The suite's host address, once something listens there (fails the suite otherwise).
    static func address(environmentVariable variable: String, defaultPort: UInt16) -> String {
        let address = ProcessInfo.processInfo.environment[variable] ?? "127.0.0.1:\(defaultPort)"
        let port = address.split(separator: ":").last.flatMap { UInt16($0) } ?? defaultPort
        if !waitForListener(port: port, timeout: 20) {
            XCTFail("nothing listens on \(address): run the VantageMacUITests scheme (its pre-action starts the synthetic hosts), or start one with --synthetic-capture --port \(port) --pairing-code 246810")
        }
        return address
    }

    private static func waitForListener(port: UInt16, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect(port: port) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private static func canConnect(port: UInt16) -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        let result = Flag()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: result.set(); done.signal()
            case .failed, .waiting, .cancelled: done.signal()
            default: break
            }
        }
        connection.start(queue: .global())
        _ = done.wait(timeout: .now() + 1)
        connection.cancel()
        return result.isSet
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
