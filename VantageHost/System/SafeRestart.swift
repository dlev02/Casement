import AppKit
import CoreServices
import Foundation
import os

/// Lets a planned restart skip the FileVault unlock screen once.
///
/// `fdesetup authrestart -delayminutes -1` stashes a one-time FileVault unlock key (in memory and
/// the SMC) and does not restart by itself; the next ordinary restart consumes it, so apps still
/// get to save and quit normally. It needs root and a FileVault-enabled account's password, which
/// the user types into our own prompt. The password reaches fdesetup through a FIFO in a private
/// temporary directory, so it never lands on disk or in any process's arguments. After the restart
/// the Mac comes up at the login window with the disk already unlocked.
nonisolated enum SafeRestart {
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "restart")

    enum Failure: LocalizedError {
        case fifo(Int32)
        case fdesetup(String)

        var errorDescription: String? {
            switch self {
            case .fifo(let code): "Couldn't prepare the unlock key (error \(code))."
            case .fdesetup(let message): message
            }
        }
    }

    static let promptExplanation = "Enter your Mac password so FileVault can unlock by itself once. The Mac then restarts normally and comes back at the login window with the disk unlocked, where you can log in remotely with Screen Sharing."

    /// `fdesetup supportsauthrestart` runs without root and prints "true" or "false".
    static func isSupported() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["supportsauthrestart"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Stashes the unlock key for the next restart. Blocks while fdesetup runs (a second or two).
    @MainActor
    static func stageUnlockKey(username: String, password: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vantage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("unlock").path
        guard mkfifo(fifo, 0o600) == 0 else { throw Failure.fifo(errno) }

        let writer = FIFOWriter(path: fifo, data: inputPlist(username: username, password: password))
        writer.start()
        defer { writer.cancel() }

        let command = "/usr/bin/fdesetup authrestart -delayminutes -1 -inputplist < " + shellQuoted(fifo)
        let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges "
            + "user name \(appleScriptQuoted(username)) password \(appleScriptQuoted(password))"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "fdesetup failed."
            log.error("authrestart staging failed: \(message, privacy: .public)")
            throw Failure.fdesetup(friendly(message))
        }
        log.info("FileVault unlock key staged for the next restart")
    }

    /// Asks loginwindow for an ordinary restart, exactly like Apple menu → Restart: every app is
    /// asked to quit and can save first. Returns false if macOS refused (e.g. Automation denied),
    /// in which case the user restarts from the Apple menu instead.
    @MainActor
    static func requestRestart() -> Bool {
        let loginwindow = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAERestart),
                                           targetDescriptor: loginwindow, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            log.info("asked loginwindow to restart")
            return true
        } catch {
            log.error("loginwindow restart request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func inputPlist(username: String, password: String) -> Data {
        let plist: [String: String] = ["Username": username, "Password": password]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("user name or password") || lower.contains("incorrect") || lower.contains("authentication") {
            return "That password wasn't accepted. Use the password you log in to this Mac with."
        }
        return message
    }
}

/// Feeds the input plist to whoever opens the FIFO for reading, then gives up after 30 seconds.
private final class FIFOWriter: @unchecked Sendable {
    private let path: String
    private let data: Data
    private let lock = NSLock()
    private var cancelled = false

    init(path: String, data: Data) {
        self.path = path
        self.data = data
    }

    func start() {
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !isCancelled {
                // O_NONBLOCK makes open fail with ENXIO until a reader is waiting, instead of hanging.
                let fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 {
                    _ = fcntl(fd, F_SETFL, 0)
                    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
                    close(fd)
                    return
                }
                usleep(20_000)
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// The password prompt shown on the Mac before a safe restart.
@MainActor
enum SafeRestartPrompt {
    /// Asks for the password and stages the key. Returns true once the key is staged.
    static func run(explanation: String) -> Bool {
        let username = NSUserName()
        while true {
            let alert = NSAlert()
            alert.messageText = "Restart Without the FileVault Screen"
            alert.informativeText = explanation
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "Password for \(username)"
            alert.accessoryView = field
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            NSApp.activate()
            alert.window.level = .modalPanel
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            guard !field.stringValue.isEmpty else { continue }
            do {
                try SafeRestart.stageUnlockKey(username: username, password: field.stringValue)
                return true
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Couldn't Prepare the Restart"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "Try Again")
                failure.addButton(withTitle: "Cancel")
                if failure.runModal() != .alertFirstButtonReturn { return false }
            }
        }
    }
}
