import Foundation
import VantageCore

/// Launch-argument driven options for headless testing (DEBUG only):
/// `-VantageSeedHost <host>` adds a device, `-VantageAutoConnect <host>` opens a session to it,
/// `-VantagePairingCode 123456` supplies the pairing code automatically.
enum ClientOptions {
    static var seedHost: String? { value(for: "-VantageSeedHost") }
    static var autoConnectHost: String? { value(for: "-VantageAutoConnect") }
    static var pairingCode: String? { value(for: "-VantagePairingCode") }
    static var seedSampleDevices: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-VantageSeedSamples")
        #else
        false
        #endif
    }

    private static func value(for flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }
}
