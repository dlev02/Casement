using Microsoft.Extensions.Time.Testing;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Tests;

/// <summary>
/// Admission cases the listener tests don't reach: a pairing code that ran out. (Burning a code,
/// the version check and purpose binding are covered over loopback in <see cref="HostListenerTests"/>.)
/// </summary>
public class SessionAdmissionTests
{
    private static readonly NSecEd25519 s_ed25519 = new();

    private static Hello HelloFrom(byte[] publicKey, byte[] clientNonce) => new()
    {
        ProtocolVersion = VantageProtocol.Version,
        ClientName = "Test iPad",
        DeviceModel = "iPad16,1",
        AppVersion = "1.0",
        ClientPublicKey = publicKey,
        SupportedCodecs = [VideoCodec.H264],
        MaxDecodeWidth = 4096,
        MaxDecodeHeight = 2304,
        Viewport = new Viewport { WidthPoints = 1210, HeightPoints = 834, Scale = 2 },
        Features = new ClientFeatures { FileTransfer = true },
        ClientNonce = clientNonce,
    };

    [Fact]
    public async Task APairingCodeThatRanOutIsRefusedAsExpiredWithTheDelayAndTrustsNobody()
    {
        await using var host = new TestHost(pairingCode: null);
        var environment = host.Listener.Environment;
        var clock = new FakeTimeProvider();
        var pairing = new PairingCodes(clock);
        var code = pairing.NewCode();
        var seed = s_ed25519.GenerateSeed();
        var publicKey = s_ed25519.PublicKeyFromSeed(seed);
        var clientNonce = AuthTranscript.RandomNonce();

        var admission = new SessionAdmission(environment, pairing, HelloFrom(publicKey, clientNonce));
        Assert.Null(admission.VersionRefusal);
        var challenge = admission.Challenge(peerTailnetName: null);
        Assert.False(challenge.IsPaired);
        Assert.True(AuthTranscript.VerifyHost(s_ed25519, challenge.HostSignature!, clientNonce, challenge.Nonce, challenge.HostPublicKey, publicKey));
        var signature = s_ed25519.Sign(seed, AuthTranscript.ClientBytes(clientNonce, challenge.Nonce, challenge.HostPublicKey, publicKey, AuthPurpose.Screen));

        // The person took longer than ten minutes to type the code.
        clock.Advance(PairingCodes.Lifetime + TimeSpan.FromSeconds(1));
        var verdict = admission.Judge(new Authenticate { Signature = signature, PairingCode = code }, peerDeviceName: null);
        Assert.Null(verdict.Kind);
        Assert.True(verdict.Delay);
        Assert.False(verdict.PairedNow);
        Assert.Equal(AuthStatus.BadPairingCode, verdict.Refusal!.Status);
        Assert.Contains("expired", verdict.Refusal.Message);
        Assert.False(environment.Trust.IsTrusted(admission.Fingerprint));

        // The next code pairs the same device at once (the signature still stands: same nonces).
        var fresh = pairing.NewCode();
        var admitted = admission.Judge(new Authenticate { Signature = signature, PairingCode = fresh }, peerDeviceName: "Test iPad");
        Assert.Equal(SessionKind.Screen, admitted.Kind);
        Assert.True(admitted.PairedNow);
        Assert.False(admitted.Delay);
        Assert.True(environment.Trust.IsTrusted(admission.Fingerprint));
        var result = admission.Accept(SessionKind.Screen, sessionToken: null, displays: []);
        Assert.Equal(AuthStatus.Ok, result.Status);
        Assert.True(result.Capabilities!.FileTransfer);
    }
}
