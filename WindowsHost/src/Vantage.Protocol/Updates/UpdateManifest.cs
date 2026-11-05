using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Vantage.Protocol.Auth;

namespace Vantage.Protocol.Updates;

/// <summary>One download in an <see cref="UpdateManifest"/>.</summary>
/// <param name="Url">Where the zip is.</param>
/// <param name="Sha256">Its SHA-256, lowercase hex. The signature covers this, so the download itself needs no signature.</param>
/// <param name="Size">Its size in bytes.</param>
public sealed record UpdateAsset(
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("sha256")] string Sha256,
    [property: JsonPropertyName("size")] long Size);

/// <summary>
/// What a Windows release offers: <c>windows-update.json</c> on the GitHub release, signed by
/// <c>windows-update.json.sig</c> (<see cref="UpdateSignature"/>). Only the holder of the signing key
/// can publish one, whoever controls the download.
/// </summary>
/// <param name="Version">The release's version, "1.4".</param>
/// <param name="NotesUrl">The release's page.</param>
/// <param name="Assets">Per processor architecture ("x64", "arm64").</param>
public sealed record UpdateManifest(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("notesUrl")] string? NotesUrl,
    [property: JsonPropertyName("assets")] IReadOnlyDictionary<string, UpdateAsset> Assets)
{
    /// <summary>Far more than a manifest ever needs; a bigger download is refused before it's parsed.</summary>
    public const int MaxBytes = 64 * 1024;

    /// <summary>The manifest as signed, or null when the bytes aren't a usable one.</summary>
    public static UpdateManifest? Parse(ReadOnlySpan<byte> bytes)
    {
        try
        {
            var manifest = JsonSerializer.Deserialize(bytes, UpdateManifestJson.Default.UpdateManifest);
            return manifest is { Version: not null, Assets: not null } && UpdateVersion.TryParse(manifest.Version, out _) ? manifest : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The bytes to publish.</summary>
    public byte[] ToBytes() => JsonSerializer.SerializeToUtf8Bytes(this, UpdateManifestJson.Default.UpdateManifest);
}

/// <summary>
/// The Ed25519 signature over a manifest's exact bytes, domain-separated so no signature made for
/// anything else can pass for one. Published as base64.
/// </summary>
public static class UpdateSignature
{
    private static readonly byte[] s_domain = Encoding.UTF8.GetBytes("casement-host-update-v1\n");

    /// <summary>Signs <paramref name="manifest"/>; the base64 text of <c>windows-update.json.sig</c>.</summary>
    public static string Sign(IEd25519 ed25519, ReadOnlySpan<byte> seed, ReadOnlySpan<byte> manifest) =>
        Convert.ToBase64String(ed25519.Sign(seed, Message(manifest)));

    /// <summary>Whether <paramref name="signature"/> (base64) is the key holder's over exactly these bytes.</summary>
    public static bool Verify(IEd25519 ed25519, ReadOnlySpan<byte> publicKey, ReadOnlySpan<byte> manifest, string signature)
    {
        byte[] raw;
        try
        {
            raw = Convert.FromBase64String(signature.Trim());
        }
        catch (FormatException)
        {
            return false;
        }
        return raw.Length == 64 && ed25519.Verify(publicKey, Message(manifest), raw);
    }

    private static byte[] Message(ReadOnlySpan<byte> manifest)
    {
        var message = new byte[s_domain.Length + manifest.Length];
        s_domain.CopyTo(message, 0);
        manifest.CopyTo(message.AsSpan(s_domain.Length));
        return message;
    }
}

/// <summary>Versions as the csproj and release tags write them: "1.4", "1.4.2", or "1.4+abc1234".</summary>
public static class UpdateVersion
{
    /// <summary>Reads a version, ignoring any "-beta" or "+commit" suffix.</summary>
    public static bool TryParse(string? text, out Version version)
    {
        version = new Version();
        if (string.IsNullOrWhiteSpace(text)) return false;
        var number = text.Split('+', '-', ' ')[0];
        if (!Version.TryParse(number, out var parsed)) return false;
        // "1.4" and "1.4.0" are the same release; Version alone says they differ.
        version = new Version(parsed.Major, parsed.Minor, Math.Max(parsed.Build, 0), Math.Max(parsed.Revision, 0));
        return true;
    }

    /// <summary>Whether <paramref name="offered"/> is strictly newer: an old signed manifest can never downgrade anyone.</summary>
    public static bool IsNewer(string? offered, string? current) =>
        TryParse(offered, out var theirs) && TryParse(current, out var ours) && theirs > ours;

    /// <summary>A version for reading: "1.4", without a trailing ".0".</summary>
    public static string Display(string text)
    {
        if (!TryParse(text, out var version)) return text;
        return version.Build > 0 || version.Revision > 0
            ? string.Create(CultureInfo.InvariantCulture, $"{version.Major}.{version.Minor}.{version.Build}")
            : string.Create(CultureInfo.InvariantCulture, $"{version.Major}.{version.Minor}");
    }
}

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(UpdateManifest))]
internal sealed partial class UpdateManifestJson : JsonSerializerContext;
