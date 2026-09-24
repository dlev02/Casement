using System.Security.Cryptography;
using System.Text;

namespace Vantage.Protocol.Auth;

/// <summary>The signed challenge transcript and fingerprints (<c>Identity/DeviceIdentity.swift</c>).</summary>
public static class AuthTranscript
{
    /// <summary>The domain separator, "vantage-auth-v1" in UTF-8 (15 bytes).</summary>
    public static ReadOnlySpan<byte> Domain => "vantage-auth-v1"u8;

    /// <summary>
    /// <c>"vantage-auth-v1" ‖ nonce(32) ‖ hostPublicKey(32) ‖ clientPublicKey(32)</c>: a plain
    /// concatenation, 111 bytes for well-formed inputs.
    /// </summary>
    public static byte[] Bytes(ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> hostPublicKey, ReadOnlySpan<byte> clientPublicKey)
    {
        var result = new byte[Domain.Length + nonce.Length + hostPublicKey.Length + clientPublicKey.Length];
        var span = result.AsSpan();
        Domain.CopyTo(span);
        span = span[Domain.Length..];
        nonce.CopyTo(span);
        span = span[nonce.Length..];
        hostPublicKey.CopyTo(span);
        span = span[hostPublicKey.Length..];
        clientPublicKey.CopyTo(span);
        return result;
    }

    /// <summary>Checks the client's signature over the transcript. False for any malformed input.</summary>
    public static bool Verify(IEd25519 ed25519, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> nonce,
                              ReadOnlySpan<byte> hostPublicKey, ReadOnlySpan<byte> clientPublicKey) =>
        ed25519.Verify(clientPublicKey, Bytes(nonce, hostPublicKey, clientPublicKey), signature);

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
