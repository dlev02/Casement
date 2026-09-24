using System.Text.Json;
using System.Text.Json.Serialization;
using Vantage.Protocol.Host;

namespace Vantage.Protocol.Auth;

/// <summary>
/// <see cref="IProtectedStorage"/> as plain files in one folder, owner-only on Unix. For macOS tests
/// and the synthetic host; Windows uses DPAPI instead.
/// </summary>
public sealed class FileProtectedStorage : IProtectedStorage
{
    private readonly string _directory;

    /// <param name="directory">Created if missing.</param>
    public FileProtectedStorage(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(directory);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    /// <inheritdoc />
    public byte[]? Read(string name)
    {
        var path = PathFor(name);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    /// <inheritdoc />
    public void Write(string name, byte[] data)
    {
        var path = PathFor(name);
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllBytes(temp, data);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temp, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.Move(temp, path, overwrite: true);
    }

    /// <inheritdoc />
    public void Delete(string name) => File.Delete(PathFor(name));

    private string PathFor(string name)
    {
        if (name.Length == 0 || name.IndexOfAny(['/', '\\']) >= 0 || name is "." or "..")
            throw new ArgumentException("A storage name is one plain file name.", nameof(name));
        return Path.Combine(_directory, name);
    }
}

/// <summary>The host key as a 32-byte seed in <c>identity.bin</c>.</summary>
public sealed class ProtectedIdentityStore(IProtectedStorage storage, IEd25519 ed25519) : IIdentityStore
{
    /// <summary>Storage name of the seed.</summary>
    public const string FileName = "identity.bin";

    private readonly Lock _lock = new();
    private HostIdentity? _loaded;

    /// <inheritdoc />
    public HostIdentity LoadOrCreate()
    {
        lock (_lock)
        {
            if (_loaded is not null) return _loaded;
            var seed = storage.Read(FileName);
            if (seed is not { Length: 32 })
            {
                seed = ed25519.GenerateSeed();
                storage.Write(FileName, seed);
            }
            _loaded = new HostIdentity(seed, ed25519.PublicKeyFromSeed(seed));
            return _loaded;
        }
    }
}

/// <summary>The trust list as JSON (<c>[{fingerprint, name, addedAt}]</c>) in <c>trusted-clients.json</c>.</summary>
public sealed class ProtectedTrustStore : ITrustStore
{
    /// <summary>Storage name of the list.</summary>
    public const string FileName = "trusted-clients.json";

    private readonly IProtectedStorage _storage;
    private readonly TimeProvider _time;
    private readonly Lock _lock = new();
    private List<TrustedClient> _clients;

    public ProtectedTrustStore(IProtectedStorage storage, TimeProvider time)
    {
        _storage = storage;
        _time = time;
        _clients = Load(storage);
    }

    /// <inheritdoc />
    public event Action? Changed;

    /// <inheritdoc />
    public bool IsTrusted(string fingerprint)
    {
        lock (_lock) return _clients.Exists(c => c.Fingerprint == fingerprint);
    }

    /// <inheritdoc />
    public void Trust(string fingerprint, string name)
    {
        lock (_lock)
        {
            if (_clients.Exists(c => c.Fingerprint == fingerprint)) return;
            _clients = [.. _clients, new TrustedClient(fingerprint, name, _time.GetUtcNow())];
            Save();
        }
        Changed?.Invoke();
    }

    /// <inheritdoc />
    public bool Revoke(string fingerprint)
    {
        lock (_lock)
        {
            var remaining = _clients.FindAll(c => c.Fingerprint != fingerprint);
            if (remaining.Count == _clients.Count) return false;
            _clients = remaining;
            Save();
        }
        Changed?.Invoke();
        return true;
    }

    /// <inheritdoc />
    public IReadOnlyList<TrustedClient> List()
    {
        lock (_lock) return [.. _clients];
    }

    private void Save() => _storage.Write(FileName, JsonSerializer.SerializeToUtf8Bytes(_clients, TrustJsonContext.Default.ListTrustedClient));

    private static List<TrustedClient> Load(IProtectedStorage storage)
    {
        var data = storage.Read(FileName);
        if (data is null) return [];
        try
        {
            return JsonSerializer.Deserialize(data, TrustJsonContext.Default.ListTrustedClient) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(List<TrustedClient>))]
internal sealed partial class TrustJsonContext : JsonSerializerContext;
