using System.Net;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Host;
using Vantage.Protocol.Net;

namespace Vantage.Protocol.Tests;

public class AuthTests
{
    private readonly NSecEd25519 _ed25519 = new();

    [Fact]
    public void TranscriptIs111BytesAndSignaturesVerify()
    {
        var clientSeed = _ed25519.GenerateSeed();
        var clientKey = _ed25519.PublicKeyFromSeed(clientSeed);
        var hostKey = _ed25519.PublicKeyFromSeed(_ed25519.GenerateSeed());
        var nonce = AuthTranscript.RandomNonce();
        var transcript = AuthTranscript.Bytes(nonce, hostKey, clientKey);
        Assert.Equal(111, transcript.Length);

        var signature = _ed25519.Sign(clientSeed, transcript);
        Assert.True(AuthTranscript.Verify(_ed25519, signature, nonce, hostKey, clientKey));
        signature[0] ^= 1;
        Assert.False(AuthTranscript.Verify(_ed25519, signature, nonce, hostKey, clientKey));
        Assert.False(AuthTranscript.Verify(_ed25519, new byte[3], nonce, hostKey, clientKey));
    }

    [Fact]
    public void Rfc8032TestVectorOne()
    {
        var seed = Convert.FromHexString("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
        Assert.Equal("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", Convert.ToHexStringLower(_ed25519.PublicKeyFromSeed(seed)));
        Assert.Equal("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
                     Convert.ToHexStringLower(_ed25519.Sign(seed, [])));
    }

    [Fact]
    public void FingerprintIsFirstEightBytesOfSha256InLowercaseHex()
    {
        var key = new byte[32];
        // SHA-256 of 32 zero bytes starts 66687aadf862bd77.
        Assert.Equal("66687aadf862bd77", AuthTranscript.Fingerprint(key));
    }

    [Fact]
    public void PairingCodeBurnsAfterFiveMissesAndExpires()
    {
        var time = new ManualTime();
        var codes = new PairingCodes(time);
        var code = codes.NewCode();
        Assert.Matches("^[0-9]{6}$", code);
        var wrong = code == "000000" ? "000001" : "000000";
        for (var i = 0; i < 4; i++) Assert.Equal(PairingCheck.Incorrect, codes.Consume(wrong));
        Assert.Equal(PairingCheck.Incorrect, codes.Consume(wrong));
        Assert.Equal(PairingCheck.Unavailable, codes.Consume(code)); // burned

        code = codes.NewCode();
        time.Advance(TimeSpan.FromMinutes(10) + TimeSpan.FromSeconds(1));
        Assert.Equal(PairingCheck.Unavailable, codes.Consume(code));

        code = codes.NewCode();
        Assert.Equal(PairingCheck.Accepted, codes.Consume(code));
        Assert.Null(codes.Current);
    }

    [Fact]
    public void FixedCodeNeverExpires()
    {
        var time = new ManualTime();
        var codes = new PairingCodes(time, "246810");
        Assert.Equal("246810", codes.NewCode());
        time.Advance(TimeSpan.FromHours(3));
        Assert.Equal(PairingCheck.Accepted, codes.Consume("246810"));
    }

    [Fact]
    public void TrustAndIdentityPersist()
    {
        var folder = Path.Combine(Path.GetTempPath(), "vantage-tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            var storage = new FileProtectedStorage(folder);
            var identity = new ProtectedIdentityStore(storage, _ed25519).LoadOrCreate();
            Assert.Equal(identity.PublicKey, new ProtectedIdentityStore(new FileProtectedStorage(folder), _ed25519).LoadOrCreate().PublicKey);

            var trust = new ProtectedTrustStore(storage, TimeProvider.System);
            trust.Trust("0123456789abcdef", "iPad");
            Assert.True(new ProtectedTrustStore(storage, TimeProvider.System).IsTrusted("0123456789abcdef"));
            Assert.True(trust.Revoke("0123456789abcdef"));
            Assert.False(new ProtectedTrustStore(storage, TimeProvider.System).IsTrusted("0123456789abcdef"));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Theory]
    [InlineData("100.64.0.1", false, true)]
    [InlineData("100.127.255.254", false, true)]
    [InlineData("100.128.0.1", false, false)]
    [InlineData("::ffff:100.64.0.20", false, true)]
    [InlineData("fd7a:115c:a1e0::1", false, true)]
    [InlineData("fd7a:115c:a1e1::1", false, false)]
    [InlineData("192.168.1.5", true, false)]
    [InlineData("127.0.0.1", false, false)]
    [InlineData("127.0.0.1", true, true)]
    [InlineData("::1", true, true)]
    [InlineData("::ffff:127.0.0.1", true, true)]
    public void PeerPolicyAcceptsTailnetAndOptionalLoopback(string address, bool allowLoopback, bool allowed) =>
        Assert.Equal(allowed, PeerPolicy.IsAllowed(IPAddress.Parse(address), allowLoopback));

    [Theory]
    [InlineData(1600, 1000, 4096, 2304, 1600, 1000)]
    [InlineData(5120, 2880, 4096, 2304, 4096, 2304)]
    [InlineData(3841, 2161, 4096, 2304, 3840, 2160)]
    [InlineData(6016, 3384, 4096, 2304, 4096, 2304)]
    [InlineData(3000, 3000, 4096, 2304, 2304, 2304)]
    public void EncodedSizeFitsTheDecoderAndIsEven(int w, int h, int maxW, int maxH, int ew, int eh) =>
        Assert.Equal((ew, eh), VideoGeometry.EncodedSize(w, h, maxW, maxH));

    private sealed class ManualTime : TimeProvider
    {
        private DateTimeOffset _now = new(2026, 9, 24, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => _now;
        public void Advance(TimeSpan by) => _now += by;
    }
}
