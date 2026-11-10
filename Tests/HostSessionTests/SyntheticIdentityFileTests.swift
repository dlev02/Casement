import Foundation
import Synchronization
import Testing
import VantageCore
@testable import VantageHostSession

/// The synthetic host's key file: one identity however many hosts launch at once, and a file that
/// isn't what it should be is put right or replaced.
struct SyntheticIdentityFileTests {
    private func freshFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "SyntheticIdentity-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func mode(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
    }

    @Test func hostsLaunchedTogetherShareOneIdentity() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fingerprints = Mutex<Set<String>>([])
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let identity = SyntheticHostEnvironment.loadOrCreateIdentity(in: folder)
            fingerprints.withLock { _ = $0.insert(identity.fingerprint) }
        }
        let shared = fingerprints.withLock { $0 }
        #expect(shared.count == 1, "\(shared.count) different identities from one folder")
        // A later launch finds the same key, in a file and folder that are the user's alone.
        #expect(SyntheticHostEnvironment.loadOrCreateIdentity(in: folder).fingerprint == shared.first)
        #expect(try mode(of: folder) == 0o700)
        #expect(try mode(of: folder.appending(path: "device-identity")) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func aKeyFileThatIsntPrivateIsRepairedAndOneThatIsntAKeyIsReplaced() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "device-identity")
        let original = SyntheticHostEnvironment.loadOrCreateIdentity(in: folder)
        // A mode that drifted is put back, and the key kept.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
        #expect(SyntheticHostEnvironment.loadOrCreateIdentity(in: folder).fingerprint == original.fingerprint)
        #expect(try mode(of: file) == 0o600)
        // Not a key's length: replaced with a new key.
        try Data(repeating: 7, count: 10).write(to: file)
        let replaced = SyntheticHostEnvironment.loadOrCreateIdentity(in: folder)
        #expect(replaced.fingerprint != original.fingerprint)
        #expect(try Data(contentsOf: file).count == 32)
        #expect(SyntheticHostEnvironment.loadOrCreateIdentity(in: folder).fingerprint == replaced.fingerprint)
        // A symbolic link in its place is replaced with a regular file of the host's own.
        let elsewhere = folder.appending(path: "elsewhere")
        try replaced.rawRepresentation.write(to: elsewhere)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        let relinked = SyntheticHostEnvironment.loadOrCreateIdentity(in: folder)
        #expect(relinked.fingerprint != replaced.fingerprint)
        let kind = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.type] as? FileAttributeType
        #expect(kind == .typeRegular)
    }
}
