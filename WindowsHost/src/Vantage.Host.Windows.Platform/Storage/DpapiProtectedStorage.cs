using System.Runtime.Versioning;
using System.Security.Cryptography;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Storage;

/// <summary>
/// <see cref="IProtectedStorage"/> as DPAPI-encrypted files (<see cref="ProtectedData"/>,
/// <see cref="DataProtectionScope.CurrentUser"/>): only this Windows user on this PC can read them.
/// The protocol library's <c>ProtectedIdentityStore</c> and <c>ProtectedTrustStore</c> sit on top.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class DpapiProtectedStorage : IProtectedStorage
{
    // Binds the blobs to this use, so a DPAPI blob from another app can't be swapped in.
    private static readonly byte[] s_entropy = "Vantage Host v1"u8.ToArray();

    private readonly string _directory;

    /// <param name="directory">Created if missing.</param>
    public DpapiProtectedStorage(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(directory);
    }

    /// <inheritdoc />
    public byte[]? Read(string name)
    {
        var path = PathFor(name);
        if (!File.Exists(path)) return null;
        try
        {
            return ProtectedData.Unprotect(File.ReadAllBytes(path), s_entropy, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException)
        {
            // Another user's or another machine's blob (a copied profile): treat as absent, so a
            // new identity or an empty trust list is made rather than failing to start.
            return null;
        }
    }

    /// <inheritdoc />
    public void Write(string name, byte[] data)
    {
        var path = PathFor(name);
        var sealedBytes = ProtectedData.Protect(data, s_entropy, DataProtectionScope.CurrentUser);
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllBytes(temp, sealedBytes);
        File.Move(temp, path, overwrite: true);
    }

    /// <inheritdoc />
    public void Delete(string name) => File.Delete(PathFor(name));

    private string PathFor(string name)
    {
        if (name.Length == 0 || name.IndexOfAny(['/', '\\', ':']) >= 0 || name is "." or "..")
            throw new ArgumentException("A storage name is one plain file name.", nameof(name));
        return Path.Combine(_directory, name);
    }
}
