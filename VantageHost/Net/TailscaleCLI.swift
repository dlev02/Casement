import Foundation
import os

/// Reads Tailscale state on the host by shelling out to the `tailscale` CLI, which robustly
/// finds the GUI variant's LocalAPI regardless of the app flavor. Read-only: never runs
/// `up`/`down`/`set`. Every invocation is wrapped in a watchdog so a hung CLI can't block.
nonisolated enum TailscaleCLI {
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "tailscale")

    static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static var executablePath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Status: Codable, Sendable {
        struct Peer: Codable, Sendable {
            var hostName: String?
            var dnsName: String?
            var tailscaleIPs: [String]?
            var os: String?
            var online: Bool?
            var relay: String?
            var curAddr: String?
            enum CodingKeys: String, CodingKey {
                case hostName = "HostName", dnsName = "DNSName", tailscaleIPs = "TailscaleIPs"
                case os = "OS", online = "Online", relay = "Relay", curAddr = "CurAddr"
            }
        }
        struct SelfNode: Codable, Sendable {
            var hostName: String?
            var dnsName: String?
            var tailscaleIPs: [String]?
            var online: Bool?
            enum CodingKeys: String, CodingKey {
                case hostName = "HostName", dnsName = "DNSName", tailscaleIPs = "TailscaleIPs", online = "Online"
            }
        }
        var backendState: String?
        var magicDNSSuffix: String?
        var selfNode: SelfNode?
        var peers: [String: Peer]?
        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState", magicDNSSuffix = "MagicDNSSuffix"
            case selfNode = "Self", peers = "Peer"
        }
    }

    static func isRunning() -> Bool {
        (try? status())?.backendState == "Running"
    }

    static func status() throws -> Status {
        let data = try run(["status", "--json", "--peers"])
        return try JSONDecoder().decode(Status.self, from: data)
    }

    private static let whoisLock = NSLock()
    nonisolated(unsafe) private static var whoisCache: [String: String?] = [:]

    /// Identifies the tailnet node behind a peer IP using LocalAPI whois via the CLI. The result
    /// is cached per address for the life of the process so reconnects don't pay for a subprocess
    /// on the handshake path.
    static func whois(addr: String) -> String? {
        let address = addr.split(separator: ":").first.map(String.init) ?? addr
        whoisLock.lock()
        if let cached = whoisCache[address] { whoisLock.unlock(); return cached }
        whoisLock.unlock()

        var name: String?
        if let data = try? run(["whois", "--json", address], timeout: 2),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let userProfile = object["UserProfile"] as? [String: Any] {
            name = userProfile["LoginName"] as? String ?? userProfile["DisplayName"] as? String
        }
        whoisLock.lock()
        whoisCache[address] = name
        whoisLock.unlock()
        return name
    }

    /// The connected device's own name on the tailnet ("Drew's iPad Pro", or its machine name
    /// "drew-ipad-pro" where iOS reports "localhost"), for notifications and paired devices.
    /// Nil when the address isn't a tailnet peer (loopback tests) or the CLI isn't there.
    static func deviceName(host: String) -> String? {
        guard let data = try? run(["whois", "--json", host], timeout: 2),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = object["Node"] as? [String: Any] else { return nil }
        if let hostinfo = node["Hostinfo"] as? [String: Any], let hostname = hostinfo["Hostname"] as? String,
           !hostname.isEmpty, hostname != "localhost" {
            return hostname
        }
        return (node["ComputedName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 6) throws -> Data {
        guard let path = executablePath else { throw TailscaleError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        var output = Data()
        DispatchQueue.global().async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw TailscaleError.timedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TailscaleError.exit(process.terminationStatus) }
        return output
    }

    static let adminConsoleURL = URL(string: "https://login.tailscale.com/admin/machines")!
}

enum TailscaleError: Error {
    case notInstalled
    case timedOut
    case exit(Int32)
}
