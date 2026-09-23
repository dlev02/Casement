import Foundation
import VantageCore

/// A device on the tailnet as reported by the Tailscale API.
nonisolated struct TailscaleDevice: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var hostname: String
    var os: String
    var addresses: [String]
    var clientVersion: String?
    var lastSeen: String?
    var connectedToControl: Bool? = nil
    var authorized: Bool?
    var user: String?
    var tags: [String]?

    /// MagicDNS name without the trailing dot.
    var magicDNSName: String { name.hasSuffix(".") ? String(name.dropLast()) : name }
    /// Tailnet IPv4 address (100.x.y.z), preferred for saved devices because it never needs DNS.
    var tailnetIPv4: String? { addresses.first { !$0.contains(":") } }
    /// Short display name: the hostname, or the first label of the MagicDNS name.
    var displayName: String {
        hostname.isEmpty ? String(magicDNSName.split(separator: ".").first ?? Substring(magicDNSName)) : hostname
    }

    enum Platform: Equatable, Sendable {
        case mac, windows, linux, iOS, android, other(String)
        var label: String {
            switch self {
            case .mac: "Mac"
            case .windows: "Windows"
            case .linux: "Linux"
            case .iOS: "iPhone or iPad"
            case .android: "Android"
            case .other(let raw): raw
            }
        }
        var symbol: String {
            switch self {
            case .mac: "macbook"
            case .windows: "pc"
            case .linux: "server.rack"
            case .iOS: "ipad.and.iphone"
            case .android: "smartphone"
            case .other: "display"
            }
        }
        /// Only Macs can run Vantage Host today.
        var isSupported: Bool { self == .mac }
    }

    var platform: Platform {
        let value = os.lowercased()
        if value.contains("mac") { return .mac }
        if value.contains("windows") { return .windows }
        if value.contains("linux") || value.contains("freebsd") { return .linux }
        if value.contains("ios") { return .iOS }
        if value.contains("android") { return .android }
        return .other(os)
    }

    var lastSeenDate: Date? {
        guard let lastSeen else { return nil }
        return ISO8601DateFormatter().date(from: lastSeen)
            ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: lastSeen) }()
    }

    /// Tailscale omits lastSeen while a device is connected to its control server.
    var isRecentlySeen: Bool {
        if connectedToControl == true { return true }
        guard let date = lastSeenDate else { return false }
        return Date().timeIntervalSince(date) < 5 * 60
    }
}

/// How Vantage authenticates to the Tailscale API. Tailscale has no end-user OAuth flow for
/// third-party apps, so the user creates either an API access token or an OAuth client
/// (with the devices:core:read scope) in the admin console and pastes it here.
nonisolated enum TailscaleCredential: Equatable, Sendable {
    case accessToken(String)
    case oauthClient(id: String, secret: String)

    var summary: String {
        switch self {
        case .accessToken: "API access token"
        case .oauthClient(let id, _): "OAuth client \(id)"
        }
    }
}

nonisolated enum TailscaleAPIError: LocalizedError, Equatable {
    case notSignedIn
    case unauthorized
    case forbidden
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to Tailscale first."
        case .unauthorized: "Tailscale rejected the key. Check that it was copied completely and hasn't expired."
        case .forbidden: "This key can't read devices. Create one with the devices:core:read scope."
        case .http(let code): "Tailscale returned an error (HTTP \(code))."
        case .malformed: "Tailscale returned an unexpected response."
        }
    }
}

/// Keychain-backed Tailscale API client. Read-only: it only ever lists devices.
@MainActor
@Observable
final class TailscaleAccount {
    static let keychainService = "com.benjaminlevinson.vantage.client"
    private static let tokenAccount = "tailscale-api-token"
    private static let oauthIDAccount = "tailscale-oauth-id"
    private static let oauthSecretAccount = "tailscale-oauth-secret"
    static var keychainAccounts: [String] { [tokenAccount, oauthIDAccount, oauthSecretAccount] }
    /// Local or iCloud Keychain, depending on whether sync is on.
    private static var keychain: KeychainStore { CloudSync.secretsStore(service: keychainService) }

    private(set) var credential: TailscaleCredential?
    private(set) var cachedDevices: [TailscaleDevice] = []
    private var bearer: (token: String, expires: Date)?

    var isSignedIn: Bool { credential != nil }

    init() {
        credential = Self.loadCredential()
    }

    private static func loadCredential() -> TailscaleCredential? {
        if let token = CloudSync.secret(tokenAccount, service: keychainService) { return .accessToken(token) }
        if let id = CloudSync.secret(oauthIDAccount, service: keychainService),
           let secret = CloudSync.secret(oauthSecretAccount, service: keychainService) {
            return .oauthClient(id: id, secret: secret)
        }
        return nil
    }

    /// Verifies the credential by listing devices, then stores it in the Keychain.
    func signIn(_ credential: TailscaleCredential) async throws -> [TailscaleDevice] {
        // The fixture accepts any key, so the setup pages can be exercised without a real tailnet.
        let result = if let fixture = ClientOptions.tailscaleFixture { (devices: fixture, cache: bearer) }
                     else { try await Self.fetchDevices(credential: credential, cache: bearer) }
        bearer = result.cache
        let devices = result.devices
        switch credential {
        case .accessToken(let token):
            try Self.keychain.set(token, for: Self.tokenAccount)
            CloudSync.removeSecret(Self.oauthIDAccount, service: Self.keychainService)
            CloudSync.removeSecret(Self.oauthSecretAccount, service: Self.keychainService)
        case .oauthClient(let id, let secret):
            try Self.keychain.set(id, for: Self.oauthIDAccount)
            try Self.keychain.set(secret, for: Self.oauthSecretAccount)
            CloudSync.removeSecret(Self.tokenAccount, service: Self.keychainService)
        }
        self.credential = credential
        cachedDevices = devices
        return devices
    }

    func signOut() {
        for account in Self.keychainAccounts { CloudSync.removeSecret(account, service: Self.keychainService) }
        credential = nil
        bearer = nil
        cachedDevices = []
    }

    func devices() async throws -> [TailscaleDevice] {
        if let fixture = ClientOptions.tailscaleFixture { return fixture }
        guard let credential else { throw TailscaleAPIError.notSignedIn }
        let result = try await Self.fetchDevices(credential: credential, cache: bearer)
        bearer = result.cache
        cachedDevices = result.devices
        return result.devices
    }

    // MARK: HTTP

    private static let base = URL(string: "https://api.tailscale.com/api/v2")!

    typealias BearerCache = (token: String, expires: Date)?

    private static func fetchDevices(credential: TailscaleCredential, cache: BearerCache) async throws -> (devices: [TailscaleDevice], cache: BearerCache) {
        let (token, newCache) = try await bearerToken(for: credential, cache: cache)
        var request = URLRequest(url: base.appending(path: "tailnet/-/devices"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        struct Envelope: Decodable { var devices: [TailscaleDevice] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw TailscaleAPIError.malformed }
        return (envelope.devices.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }, newCache)
    }

    private static func bearerToken(for credential: TailscaleCredential, cache: BearerCache) async throws -> (String, BearerCache) {
        switch credential {
        case .accessToken(let token):
            return (token, nil)
        case .oauthClient(let id, let secret):
            if let cache, cache.expires > Date().addingTimeInterval(60) { return (cache.token, cache) }
            var request = URLRequest(url: base.appending(path: "oauth/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("client_id=\(id.urlFormEncoded)&client_secret=\(secret.urlFormEncoded)".utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response)
            struct TokenResponse: Decodable { var access_token: String; var expires_in: Double? }
            guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw TailscaleAPIError.malformed }
            return (token.access_token, (token.access_token, Date().addingTimeInterval(token.expires_in ?? 3600)))
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw TailscaleAPIError.malformed }
        switch http.statusCode {
        case 200 ..< 300: return
        case 401: throw TailscaleAPIError.unauthorized
        case 403: throw TailscaleAPIError.forbidden
        default: throw TailscaleAPIError.http(http.statusCode)
        }
    }
}

private extension String {
    var urlFormEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
