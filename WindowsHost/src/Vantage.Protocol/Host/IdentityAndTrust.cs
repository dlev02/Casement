namespace Vantage.Protocol.Host;

/// <summary>
/// Small named secrets at rest: the host's key seed and the trust list. Windows: DPAPI
/// (<c>ProtectedData</c>, CurrentUser) files under <c>%LOCALAPPDATA%\Vantage Host\</c>
/// (<c>Vantage Host (Synthetic)</c> for DEBUG/synthetic hosts, so they never share a trust list with
/// the real one). The protocol library's <see cref="Auth.FileProtectedStorage"/> keeps them as plain
/// owner-only files, for macOS tests and the synthetic host.
/// </summary>
public interface IProtectedStorage
{
    /// <summary>The blob stored under <paramref name="name"/> (e.g. "identity.bin", "trusted-clients.json"), or null if there is none.</summary>
    byte[]? Read(string name);

    /// <summary>Stores <paramref name="data"/> under <paramref name="name"/>, replacing it atomically (write a temp file, then move).</summary>
    void Write(string name, byte[] data);

    /// <summary>Removes the blob; no error if it doesn't exist.</summary>
    void Delete(string name);
}

/// <summary>The host's long-lived Ed25519 identity.</summary>
public interface IIdentityStore
{
    /// <summary>
    /// The host key, created and stored on first use (a 32-byte seed, CryptoKit's
    /// <c>rawRepresentation</c>). The same key every launch; the client pins nothing, but paired
    /// clients' trust is keyed by their own keys, not this one.
    /// </summary>
    HostIdentity LoadOrCreate();
}

/// <summary>A loaded Ed25519 key pair.</summary>
/// <param name="Seed">32-byte private seed. Keep in memory only.</param>
/// <param name="PublicKey">32-byte raw public key, sent as <c>Challenge.hostPublicKey</c>.</param>
public sealed record HostIdentity(byte[] Seed, byte[] PublicKey);

/// <summary>A paired client device.</summary>
/// <param name="Fingerprint">Lowercase hex of the first 8 bytes of SHA-256(raw public key): 16 characters.</param>
/// <param name="Name"><c>Hello.clientName</c> when it paired (iOS says just "iPad"; the UI may show the whois name instead).</param>
/// <param name="AddedAt">When it paired.</param>
public sealed record TrustedClient(string Fingerprint, string Name, DateTimeOffset AddedAt);

/// <summary>
/// The trust list: which client keys may connect without a pairing code (spec §7.1). The protocol
/// library provides <see cref="Auth.ProtectedTrustStore"/> over an <see cref="IProtectedStorage"/>;
/// a platform only needs its own storage.
/// </summary>
public interface ITrustStore
{
    /// <summary>Whether a client with this fingerprint is paired.</summary>
    bool IsTrusted(string fingerprint);

    /// <summary>Adds a client after a correct pairing code. No-op if it's already there.</summary>
    void Trust(string fingerprint, string name);

    /// <summary>Removes a client. Returns false if it wasn't there. The listener also closes its sessions and file channels.</summary>
    bool Revoke(string fingerprint);

    /// <summary>Everyone paired, oldest first.</summary>
    IReadOnlyList<TrustedClient> List();

    /// <summary>Raised (any thread) after <see cref="Trust"/> or <see cref="Revoke"/> changes the list.</summary>
    event Action? Changed;
}
