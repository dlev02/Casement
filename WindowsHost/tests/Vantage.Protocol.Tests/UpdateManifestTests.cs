using System.Text;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Updates;
using Xunit;

namespace Vantage.Protocol.Tests;

public sealed class UpdateManifestTests
{
    private static readonly NSecEd25519 s_ed25519 = new();

    private static UpdateManifest Sample() => new("1.5", "https://example.test/notes", new Dictionary<string, UpdateAsset>
    {
        ["x64"] = new("https://example.test/a.zip", "ab", 10),
    });

    [Fact]
    public void ManifestSurvivesTheRoundTrip()
    {
        var parsed = UpdateManifest.Parse(Sample().ToBytes());
        Assert.NotNull(parsed);
        Assert.Equal("1.5", parsed.Version);
        Assert.Equal("https://example.test/a.zip", parsed.Assets["x64"].Url);
        Assert.Equal(10, parsed.Assets["x64"].Size);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{}")]
    [InlineData("""{"version":"banana","assets":{}}""")]
    [InlineData("""{"version":"1.5"}""")]
    public void JunkIsNoManifest(string text) => Assert.Null(UpdateManifest.Parse(Encoding.UTF8.GetBytes(text)));

    [Fact]
    public void OnlyTheKeyHoldersExactBytesVerify()
    {
        var seed = s_ed25519.GenerateSeed();
        var key = s_ed25519.PublicKeyFromSeed(seed);
        var bytes = Sample().ToBytes();
        var signature = UpdateSignature.Sign(s_ed25519, seed, bytes);

        Assert.True(UpdateSignature.Verify(s_ed25519, key, bytes, signature));
        Assert.True(UpdateSignature.Verify(s_ed25519, key, bytes, signature + "\n")); // a trailing newline from an editor

        var changed = (byte[])bytes.Clone();
        changed[^3] ^= 1;
        Assert.False(UpdateSignature.Verify(s_ed25519, key, changed, signature));

        var other = s_ed25519.PublicKeyFromSeed(s_ed25519.GenerateSeed());
        Assert.False(UpdateSignature.Verify(s_ed25519, other, bytes, signature));
        Assert.False(UpdateSignature.Verify(s_ed25519, key, bytes, "not base64!"));
        Assert.False(UpdateSignature.Verify(s_ed25519, key, bytes, Convert.ToBase64String(new byte[10])));
    }

    [Fact]
    public void ASignatureMadeForAnythingElseDoesntCount()
    {
        var seed = s_ed25519.GenerateSeed();
        var key = s_ed25519.PublicKeyFromSeed(seed);
        var bytes = Sample().ToBytes();
        var bare = Convert.ToBase64String(s_ed25519.Sign(seed, bytes)); // the same key, without the domain
        Assert.False(UpdateSignature.Verify(s_ed25519, key, bytes, bare));
    }

    [Theory]
    [InlineData("1.5", "1.4", true)]
    [InlineData("1.10", "1.9", true)]
    [InlineData("1.4.1", "1.4", true)]
    [InlineData("1.4", "1.4", false)]
    [InlineData("1.4", "1.4.0", false)]
    [InlineData("1.4", "1.4 (abc1234)", false)]
    [InlineData("1.4", "1.4+abcdef0", false)]
    [InlineData("1.3", "1.4", false)] // an old signed manifest never downgrades anyone
    [InlineData("banana", "1.4", false)]
    [InlineData("1.5", "?", false)]
    public void OnlyAStrictlyNewerVersionCounts(string offered, string current, bool newer) =>
        Assert.Equal(newer, UpdateVersion.IsNewer(offered, current));

    [Theory]
    [InlineData("1.4", "1.4")]
    [InlineData("1.4.0", "1.4")]
    [InlineData("1.4.2", "1.4.2")]
    [InlineData("1.4 (abc1234)", "1.4")]
    public void VersionsReadPlainly(string text, string shown) => Assert.Equal(shown, UpdateVersion.Display(text));
}
