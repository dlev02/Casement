using NSec.Cryptography;

namespace Vantage.Protocol.Auth;

/// <summary>
/// Ed25519 (RFC 8032, pure) behind an interface, since .NET has none built in. The default is
/// <see cref="NSecEd25519"/> (libsodium); a managed fallback can replace it if the native library
/// won't load.
/// </summary>
public interface IEd25519
{
    /// <summary>A new random 32-byte private seed.</summary>
    byte[] GenerateSeed();

    /// <summary>The 32-byte raw public key for a seed.</summary>
    byte[] PublicKeyFromSeed(ReadOnlySpan<byte> seed);

    /// <summary>A 64-byte signature of <paramref name="message"/>.</summary>
    byte[] Sign(ReadOnlySpan<byte> seed, ReadOnlySpan<byte> message);

    /// <summary>
    /// Whether <paramref name="signature"/> is valid for <paramref name="message"/> under
    /// <paramref name="publicKey"/>. False (never an exception) for malformed keys or signatures.
    /// CryptoKit signatures are randomized but standard; any RFC 8032 verifier accepts them.
    /// </summary>
    bool Verify(ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature);
}

/// <summary>Ed25519 through NSec (libsodium). Seeds are NSec's <c>RawPrivateKey</c> blobs.</summary>
public sealed class NSecEd25519 : IEd25519
{
    private static readonly SignatureAlgorithm s_algorithm = SignatureAlgorithm.Ed25519;

    /// <inheritdoc />
    public byte[] GenerateSeed()
    {
        var parameters = new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport };
        using var key = Key.Create(s_algorithm, parameters);
        return key.Export(KeyBlobFormat.RawPrivateKey);
    }

    /// <inheritdoc />
    public byte[] PublicKeyFromSeed(ReadOnlySpan<byte> seed)
    {
        using var key = Key.Import(s_algorithm, seed, KeyBlobFormat.RawPrivateKey);
        return key.PublicKey.Export(KeyBlobFormat.RawPublicKey);
    }

    /// <inheritdoc />
    public byte[] Sign(ReadOnlySpan<byte> seed, ReadOnlySpan<byte> message)
    {
        using var key = Key.Import(s_algorithm, seed, KeyBlobFormat.RawPrivateKey);
        return s_algorithm.Sign(key, message);
    }

    /// <inheritdoc />
    public bool Verify(ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (publicKey.Length != 32 || signature.Length != 64) return false;
        if (!PublicKey.TryImport(s_algorithm, publicKey, KeyBlobFormat.RawPublicKey, out var key) || key is null) return false;
        return s_algorithm.Verify(key, message, signature);
    }
}
