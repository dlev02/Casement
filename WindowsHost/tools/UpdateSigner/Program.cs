using System.Security.Cryptography;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Updates;

// keygen --out FILE
//   Makes the release signing key. FILE holds the private seed (hex): keep it out of the repo and back
//   it up. Prints the public key, which goes in HostUpdater.ReleasePublicKeyHex.
// sign --key FILE --version 1.4 --tag host-1.4 --out DIR --x64 ZIP --arm64 ZIP [--base-url URL]
//   Writes windows-update.json and windows-update.json.sig for a release into DIR.
// public --key FILE
//   Prints the public key for a key file.

var ed25519 = new NSecEd25519();
var command = args.Length > 0 ? args[0] : "";
string? Option(string name)
{
    var at = Array.IndexOf(args, name);
    return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
}
string Required(string name) => Option(name) ?? throw new ArgumentException($"{name} is required.");

try
{
    switch (command)
    {
        case "keygen":
        {
            var path = Required("--out");
            if (File.Exists(path)) throw new ArgumentException($"{path} already exists. A new key would strand every copy already installed.");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            var seed = ed25519.GenerateSeed();
            File.WriteAllText(path, Convert.ToHexStringLower(seed));
            Console.WriteLine(Convert.ToHexStringLower(ed25519.PublicKeyFromSeed(seed)));
            return 0;
        }
        case "public":
        {
            var seed = Convert.FromHexString(File.ReadAllText(Required("--key")).Trim());
            Console.WriteLine(Convert.ToHexStringLower(ed25519.PublicKeyFromSeed(seed)));
            return 0;
        }
        case "sign":
        {
            var seed = Convert.FromHexString(File.ReadAllText(Required("--key")).Trim());
            var version = Required("--version");
            var tag = Required("--tag");
            var output = Required("--out");
            var baseUrl = Option("--base-url") ?? $"https://github.com/dlev02/Casement/releases/download/{tag}/";
            var assets = new Dictionary<string, UpdateAsset>();
            foreach (var architecture in new[] { "x64", "arm64" })
            {
                if (Option("--" + architecture) is not { } zip) continue;
                using var stream = File.OpenRead(zip);
                assets[architecture] = new UpdateAsset(baseUrl + Path.GetFileName(zip), Convert.ToHexStringLower(SHA256.HashData(stream)), stream.Length);
            }
            if (assets.Count == 0) throw new ArgumentException("Give --x64 or --arm64.");
            var notes = Option("--notes-url") ?? $"https://github.com/dlev02/Casement/releases/tag/{tag}";
            var manifest = new UpdateManifest(version, notes, assets).ToBytes();
            Directory.CreateDirectory(output);
            File.WriteAllBytes(Path.Combine(output, "windows-update.json"), manifest);
            File.WriteAllText(Path.Combine(output, "windows-update.json.sig"), UpdateSignature.Sign(ed25519, seed, manifest));
            Console.WriteLine($"signed {version}: {string.Join(", ", assets.Keys)}");
            return 0;
        }
        default:
            Console.Error.WriteLine("usage: UpdateSigner keygen --out FILE | public --key FILE | sign --key FILE --version V --tag T --out DIR --x64 ZIP --arm64 ZIP");
            return 2;
    }
}
catch (Exception ex) when (ex is ArgumentException or IOException or FormatException or UnauthorizedAccessException)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}
