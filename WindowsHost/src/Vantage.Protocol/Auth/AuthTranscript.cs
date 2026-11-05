using System.Security.Cryptography;
using System.Text;

namespace Vantage.Protocol.Auth;

/// <summary>
/// What a connection is for (<c>AuthPurpose</c> in Swift). Bound into the client's signature, so a
/// signature a client made for an availability check can't be replayed to open a screen session.
/// </summary>
public enum AuthPurpose : byte
{
    Screen = 0,
    Probe = 1,
    Files = 2,
}

/// <summary>
/// The handshake transcripts both sides sign and verify, and fingerprints (<c>Identity/DeviceIdentity.swift</c>).
/// A client that sends <c>Hello.clientNonce</c> expects <see cref="HostBytes"/> signed back in the
/// challenge and itself signs <see cref="ClientBytes"/>, which binds both nonces, both keys and the
/// purpose. A client without a nonce signs the older <see cref="Bytes"/>, still accepted.
/// </summary>
public static class AuthTranscript
{
    /// <summary>The older client transcript's domain separator, "vantage-auth-v1" in UTF-8 (15 bytes).</summary>
    public static ReadOnlySpan<byte> Domain => "vantage-auth-v1"u8;
    /// <summary>The client transcript's domain separator, "vantage-auth-v2" (15 bytes).</summary>
    public static ReadOnlySpan<byte> ClientDomain => "vantage-auth-v2"u8;
    /// <summary>The host transcript's domain separator, "vantage-host-auth-v1" (20 bytes).</summary>
    public static ReadOnlySpan<byte> HostDomain => "vantage-host-auth-v1"u8;
    /// <summary>Every nonce is this long, so the plain concatenations can't be shifted.</summary>
    public const int NonceLength = 32;

    /// <summary>
    /// <c>"vantage-auth-v1" ‖ nonce(32) ‖ hostPublicKey(32) ‖ clientPublicKey(32)</c>: a plain
    /// concatenation, 111 bytes for well-formed inputs.
    /// </summary>
    public static byte[] Bytes(ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> hostPublicKey, ReadOnlySpan<byte> clientPublicKey) =>
        Concat(Domain.ToArray(), nonce.ToArray(), hostPublicKey.ToArray(), clientPublicKey.ToArray());

    /// <summary>Checks the client's signature over the older transcript. False for any malformed input.</summary>
    public static bool Verify(IEd25519 ed25519, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> nonce,
                              ReadOnlySpan<byte> hostPublicKey, ReadOnlySpan<byte> clientPublicKey) =>
        ed25519.Verify(clientPublicKey, Bytes(nonce, hostPublicKey, clientPublicKey), signature);

    /// <summary>
    /// What the client signs: <c>"vantage-auth-v2" ‖ clientNonce(32) ‖ hostNonce(32) ‖ hostPublicKey(32)
    /// ‖ clientPublicKey(32) ‖ purpose(1)</c>, 144 bytes.
    /// </summary>
    public static byte[] ClientBytes(ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> hostNonce, ReadOnlySpan<byte> hostPublicKey,
                                     ReadOnlySpan<byte> clientPublicKey, AuthPurpose purpose) =>
        Concat(ClientDomain.ToArray(), clientNonce.ToArray(), hostNonce.ToArray(), hostPublicKey.ToArray(), clientPublicKey.ToArray(), [(byte)purpose]);

    /// <summary>Checks the client's signature over <see cref="ClientBytes"/>. False for a nonce of the wrong length.</summary>
    public static bool VerifyClient(IEd25519 ed25519, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> hostNonce,
                                    ReadOnlySpan<byte> hostPublicKey, ReadOnlySpan<byte> clientPublicKey, AuthPurpose purpose) =>
        clientNonce.Length == NonceLength && hostNonce.Length == NonceLength
        && ed25519.Verify(clientPublicKey, ClientBytes(clientNonce, hostNonce, hostPublicKey, clientPublicKey, purpose), signature);

    /// <summary>
    /// What the host signs: <c>"vantage-host-auth-v1" ‖ clientNonce(32) ‖ hostNonce(32) ‖ hostPublicKey(32)
    /// ‖ clientPublicKey(32)</c>, 148 bytes.
    /// </summary>
    public static byte[] HostBytes(ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> hostNonce, ReadOnlySpan<byte> hostPublicKey,
                                   ReadOnlySpan<byte> clientPublicKey) =>
        Concat(HostDomain.ToArray(), clientNonce.ToArray(), hostNonce.ToArray(), hostPublicKey.ToArray(), clientPublicKey.ToArray());

    /// <summary>Checks a host's signature over <see cref="HostBytes"/> (what a client does with a challenge).</summary>
    public static bool VerifyHost(IEd25519 ed25519, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> clientNonce, ReadOnlySpan<byte> hostNonce,
                                  ReadOnlySpan<byte> hostPublicKey, ReadOnlySpan<byte> clientPublicKey) =>
        clientNonce.Length == NonceLength && hostNonce.Length == NonceLength
        && ed25519.Verify(hostPublicKey, HostBytes(clientNonce, hostNonce, hostPublicKey, clientPublicKey), signature);

    /// <summary>The purpose a hello declares (the client binds the same one into its signature).</summary>
    public static AuthPurpose Purpose(Messages.Hello hello) =>
        hello.IsReadinessProbe == true ? AuthPurpose.Probe
        : hello.Features?.FilesOnly == true ? AuthPurpose.Files
        : AuthPurpose.Screen;

    /// <summary>A plain concatenation, no lengths: the fixed sizes above keep it unambiguous.</summary>
    private static byte[] Concat(params byte[][] parts)
    {
        var result = new byte[parts.Sum(part => part.Length)];
        var offset = 0;
        foreach (var part in parts)
        {
            part.CopyTo(result, offset);
            offset += part.Length;
        }
        return result;
    }

    /// <summary>32 bytes from the CSPRNG.</summary>
    public static byte[] RandomNonce() => RandomNumberGenerator.GetBytes(32);

    /// <summary>
    /// Lowercase hex of the first 8 bytes of SHA-256(raw 32-byte public key): 16 characters. The
    /// trust list's key.
    /// </summary>
    public static string Fingerprint(ReadOnlySpan<byte> publicKey)
    {
        Span<byte> digest = stackalloc byte[32];
        SHA256.HashData(publicKey, digest);
        var builder = new StringBuilder(16);
        foreach (var b in digest[..8]) builder.Append(b.ToString("x2", System.Globalization.CultureInfo.InvariantCulture));
        return builder.ToString();
    }
}
