import Foundation

/// Read-only probes that explain how the Mac will behave after a reboot or when locked.
nonisolated enum Readiness {
    struct Report: Sendable, Equatable {
        var fileVaultOn: Bool?
        var remoteLoginEnabled: Bool
        var screenSharingEnabled: Bool
        var authRestartSupported: Bool
    }

    static func probe() -> Report {
        Report(fileVaultOn: fileVaultStatus(),
               remoteLoginEnabled: portOpen(22),
               screenSharingEnabled: portOpen(5900),
               authRestartSupported: SafeRestart.isSupported())
    }

    /// `fdesetup status` works for standard users and prints "FileVault is On." / "Off.".
    private static func fileVaultStatus() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let group = DispatchGroup()
        group.enter()
        var output = Data()
        DispatchQueue.global().async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        if text.contains("FileVault is On") { return true }
        if text.contains("FileVault is Off") { return false }
        return nil
    }

    /// Non-blocking loopback TCP probe with a short timeout.
    private static func portOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
