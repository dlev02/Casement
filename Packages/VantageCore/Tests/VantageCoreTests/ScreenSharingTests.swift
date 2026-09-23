import CryptoKit
import Foundation
import Testing
@testable import VantageCore

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

/// RFC 2409 Oakley group 2 (1024-bit), the same size screensharingd offers. Vectors from Python's pow().
private let prime = hex("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF")
private let clientSecret = hex("0000005fdd69d724756687ddc8b2b17973f1bc6a18c9364f9ff2fef657e467a8a8ba220657a8e8e175bc30f47747fb5859e1fae7199d4f669645a0a6291869798d4c28771797ff9fffa555f1e693f10a61515e2682e2ada32fcafdb0716e1a3ee90593bdeaaa3371f15bc61748c29143cb9a8235545640dc5bfa11ed3bf2bbfa")
private let serverPublic = hex("cfe44876ac50e0533440b9d6f56d851f9cbc850721e134b56e7ab9d1f0b4e0656a72195b6262816a3b2b0fde0c6d3260a3052b924811c03b345dfa4cb91245509fe4cff4dae23d19618463428dd8fb8176c64c947df32a0c8b8540b817d06cb7dc58ef615525c035ea7f67aa54dff4c7a034bed23f84f5bc126457fbc632d314")
private let clientPublic = hex("84fd83e922eb4a35f509a314ae9164bf871418143fd8983c31b03281ae1627a516a409ee757f362c785429aec3ebd97a367777c3a6bcfad2e0609974408525e582d6f26b7aefeda5a57d08b74114258024d0397e11c55f275624803c00b5a556808c11f0797f8f07011001b53e0ab451003e0945edeecc1a57dff4e754bfa3dc")
private let sharedSecret = hex("b9eed156440f5df8963e176a83e0b61cd885198a8deb8316e4903a5ea2978865194045563d29c0deca702e7d7012c32c4046a8bc8e3ed13e99ff6028f8949b139e82fc7c6893af95829d550599a144eb4fc193af8a2f1fe34a39699c464cc5c18e822cfb5f01448d22b893ad188aa795d9bcd5c2798274ec28018a5019392681")

@Test func modularExponentMatchesReference() {
    #expect(ModularExponent.power(base: [0, 2], exponent: clientSecret, modulus: prime) == clientPublic)
    #expect(ModularExponent.power(base: serverPublic, exponent: clientSecret, modulus: prime) == sharedSecret)
    #expect(ModularExponent.power(base: [5], exponent: [3], modulus: [23]) == [10]) // 125 mod 23
    #expect(ModularExponent.power(base: [30], exponent: [1], modulus: [23]) == [7])  // base above modulus
    #expect(ModularExponent.power(base: [2], exponent: [2], modulus: [8]) == nil)    // even modulus
}

@Test func aesECBMatchesFIPS197() {
    let key = hex("000102030405060708090a0b0c0d0e0f")
    let plain = hex("00112233445566778899aabbccddeeff")
    #expect(ScreenSharingTyper.aes128ECB(plain, key: key) == hex("69c4e0d86a7b0430d8cdb78070b4c55a"))
}

@Test func ardResponseEncryptsCredentialsWithSharedSecret() throws {
    let padding = [UInt8](repeating: 0xAB, count: 128)
    let response = try ScreenSharingTyper.ardResponse(generator: [0, 2], prime: prime, serverPublicKey: serverPublic,
                                                      username: "drew", password: "p@ss",
                                                      privateKey: clientSecret, padding: padding)
    #expect(response.count == 128 + prime.count)
    #expect(Array(response.suffix(prime.count)) == clientPublic)
    let key = Array(Insecure.MD5.hash(data: sharedSecret))
    #expect(key == hex("b8c7600800bb5185f539fe66998603d1"))
    let block = ScreenSharingTyper.credentialsBlock(username: "drew", password: "p@ss", padding: padding)
    #expect(Array(block[0..<5]) == Array("drew".utf8) + [0])
    #expect(Array(block[64..<69]) == Array("p@ss".utf8) + [0])
    #expect(block[5] == 0xAB && block[69] == 0xAB)
    #expect(Array(response.prefix(128)) == ScreenSharingTyper.aes128ECB(block, key: key))
}

@Test func keyEventsHoldShiftForShiftedCharacters() {
    let events = ScreenSharingTyper.keyEvents(for: "aB!", pressReturn: true)
    let expected: [(UInt32, Bool)] = [
        (0x61, true), (0x61, false),
        (0xFFE1, true), (0x42, true), (0x42, false), (0xFFE1, false),
        (0xFFE1, true), (0x21, true), (0x21, false), (0xFFE1, false),
        (0xFF0D, true), (0xFF0D, false),
    ]
    #expect(events.map(\.keysym) == expected.map(\.0))
    #expect(events.map(\.down) == expected.map(\.1))
    #expect(events[0].bytes == [4, 1, 0, 0, 0, 0, 0, 0x61])
    #expect(ScreenSharingTyper.keysym(for: "é") == 0xE9)
    #expect(ScreenSharingTyper.keysym(for: "€") == 0x0100_20AC)
}

/// Talks to this Mac's real screensharingd with a bogus account; expects a clean auth rejection.
/// Opt-in: VANTAGE_LIVE_SCREEN_SHARING=1 xcrun swift test --package-path Packages/VantageCore
@Test(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_LIVE_SCREEN_SHARING"] == "1"))
func liveScreenSharingRejectsUnknownAccount() async {
    do {
        try await ScreenSharingTyper.verify(host: "127.0.0.1", username: "vantage-protocol-check", password: "not-a-password")
        Issue.record("unexpectedly authenticated")
    } catch let error as ScreenSharingTyper.TypeError {
        print("live Screen Sharing result: \(error)")
        guard case .authenticationFailed = error else { Issue.record("expected auth failure, got \(error)"); return }
    } catch {
        Issue.record("unexpected error \(error)")
    }
}
