using Vantage.Protocol.Auth;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>What a device was admitted to.</summary>
internal enum SessionKind
{
    /// <summary>An availability check (<c>hello.isReadinessProbe</c>): answered and closed, never listed.</summary>
    AvailabilityCheck,
    /// <summary>A files-only session: keeps its attach token alive, moves no screen.</summary>
    FilesOnly,
    /// <summary>A screen session.</summary>
    Screen,
}

/// <summary>
/// The outcome of <see cref="SessionAdmission.Judge"/>: either a <see cref="Refusal"/> to send and
/// close on, or the <see cref="Kind"/> of session to run. <see cref="Delay"/> asks for the 1 s pause
/// before answering (a wrong or dead pairing code), <see cref="PairedNow"/> says this connection
/// just paired the device.
/// </summary>
internal sealed record AdmissionVerdict(SessionKind? Kind, AuthResult? Refusal, bool Delay, bool PairedNow);

/// <summary>
/// Admits one connection (the Mac's <c>HostSession.handshake</c>): from the device's <c>hello</c>,
/// the trust store, the pairing code and the host identity it makes the <c>challenge</c>, then
/// turns the <c>authenticate</c> into a verdict (version, signature over the right transcript,
/// pairing accepted, wrong or expired with the five-miss burn, what the connection is for) and
/// writes the <c>authResult</c> for what was admitted, with the capabilities to advertise. The
/// session only runs whatever it was admitted as. Every message is built exactly as before this
/// module existed: the golden vectors and the interop suite hold it to that.
/// </summary>
internal sealed class SessionAdmission
{
    private readonly HostEnvironment _env;
    private readonly PairingCodes _pairing;
    private readonly Hello _hello;
    private readonly byte[]? _clientNonce;
    private byte[]? _nonce;
    private HostIdentity? _identity;
    private bool _isPaired;

    public SessionAdmission(HostEnvironment env, PairingCodes pairing, Hello hello)
    {
        _env = env;
        _pairing = pairing;
        _hello = hello;
        Fingerprint = AuthTranscript.Fingerprint(hello.ClientPublicKey);
        // A client that sent a nonce wants proof this challenge comes from the holder of the host
        // key, and signs the transcript that binds both nonces and the connection's purpose. One
        // that didn't (an older Casement) signs the older transcript; the host still takes that.
        _clientNonce = hello.ClientNonce is { Length: AuthTranscript.NonceLength } sent ? sent : null;
        if (hello.ProtocolVersion != VantageProtocol.Version)
            VersionRefusal = new AuthResult { Status = AuthStatus.VersionMismatch, Message = $"Protocol {VantageProtocol.Version} required" };
    }

    /// <summary>The device key's fingerprint.</summary>
    public string Fingerprint { get; }

    /// <summary>Set when the device speaks another protocol version: send it and close, nothing else happens.</summary>
    public AuthResult? VersionRefusal { get; }

    /// <summary>An availability check or files-only session: not worth a whois.</summary>
    public bool IsLightweight => _hello.IsReadinessProbe == true || _hello.Features?.FilesOnly == true;

    /// <summary>The device said it takes files (<c>features.fileTransfer</c>).</summary>
    public bool ClientTakesFiles => _hello.Features?.FileTransfer == true;

    /// <summary>The device said it plays the computer's sound (<c>features.macAudio</c>).</summary>
    public bool ClientTakesAudio => _hello.Features?.MacAudio == true;

    /// <summary>The device knows the curtain (<c>features.curtain</c>).</summary>
    public bool ClientKnowsCurtain => _hello.Features?.Curtain == true;

    private string HostNoun => _env.Platform == HostPlatforms.Windows ? "PC" : "Mac";

    /// <summary>The <c>challenge</c>: host identity, a fresh nonce, whether the device is paired, and the host's signature when the device asked for one. Once per connection.</summary>
    public Challenge Challenge(string? peerTailnetName)
    {
        _identity = _env.Identity.LoadOrCreate();
        _nonce = AuthTranscript.RandomNonce();
        _isPaired = _env.Trust.IsTrusted(Fingerprint);
        return new Challenge
        {
            HostName = _env.HostName,
            HostVersion = VantageProtocol.HostVersion,
            HostPublicKey = _identity.PublicKey,
            Nonce = _nonce,
            IsPaired = _isPaired,
            PeerTailnetName = peerTailnetName,
            HostPlatform = _env.Platform,
            HostSignature = _clientNonce is null ? null
                : _env.Ed25519.Sign(_identity.Seed, AuthTranscript.HostBytes(_clientNonce, _nonce, _identity.PublicKey, _hello.ClientPublicKey)),
        };
    }

    /// <summary>
    /// The device's answer to the challenge: signature, then pairing (an accepted code trusts the
    /// device at once, with <paramref name="peerDeviceName"/> from whois), then what the connection
    /// is for and whether this computer can serve it.
    /// </summary>
    public AdmissionVerdict Judge(Authenticate auth, string? peerDeviceName)
    {
        if (_identity is not { } identity || _nonce is not { } nonce) throw new InvalidOperationException("Judge comes after Challenge.");
        var signatureValid = _clientNonce is null
            ? AuthTranscript.Verify(_env.Ed25519, auth.Signature, nonce, identity.PublicKey, _hello.ClientPublicKey)
            : AuthTranscript.VerifyClient(_env.Ed25519, auth.Signature, _clientNonce, nonce, identity.PublicKey, _hello.ClientPublicKey,
                                          AuthTranscript.Purpose(_hello));
        if (!signatureValid) return Refuse(new AuthResult { Status = AuthStatus.BadSignature });

        var pairedNow = false;
        if (!_isPaired)
        {
            if (auth.PairingCode is not { } code)
                return Refuse(new AuthResult { Status = AuthStatus.PairingRequired, Message = $"Enter the pairing code shown on the {HostNoun}" });
            switch (_pairing.Consume(code))
            {
                case PairingCheck.Accepted:
                    break;
                case PairingCheck.Incorrect:
                    // Slow down guessing; the code also burns after five misses.
                    return Refuse(new AuthResult { Status = AuthStatus.BadPairingCode, Message = $"Incorrect pairing code. Try the code shown on the {HostNoun}." }, delay: true);
                default:
                    return Refuse(new AuthResult
                    {
                        Status = AuthStatus.BadPairingCode,
                        Message = $"That pairing code has expired. On the {HostNoun}, choose Show Pairing Code and enter the new one.",
                    }, delay: true);
            }
            _env.Trust.Trust(Fingerprint, _hello.ClientName, peerDeviceName);
            pairedNow = true;
        }

        if (_hello.IsReadinessProbe == true) return Admit(SessionKind.AvailabilityCheck, pairedNow);
        if (_hello.Features?.FilesOnly == true)
        {
            return _hello.Features.FileTransfer == true
                ? Admit(SessionKind.FilesOnly, pairedNow)
                : new AdmissionVerdict(null, new AuthResult { Status = AuthStatus.Denied, Message = "Nothing to do on this connection." }, false, pairedNow);
        }
        return _env.Screen.IsCaptureSupported
            ? Admit(SessionKind.Screen, pairedNow)
            : new AdmissionVerdict(null, new AuthResult { Status = AuthStatus.Denied, Message = _env.Screen.CaptureUnsupportedMessage }, false, pairedNow);
    }

    /// <summary>
    /// The <c>authResult{ok}</c> for an admitted session: readiness for an availability check
    /// (Windows has no grants to report, but capture can still be unsupported, said here where the
    /// device list reads it), the attach token and file capabilities for files-only, and the
    /// displays plus everything this computer offers for a screen session.
    /// </summary>
    public AuthResult Accept(SessionKind kind, byte[]? sessionToken, IReadOnlyList<DisplayInfo>? displays) => kind switch
    {
        SessionKind.AvailabilityCheck => new AuthResult
        {
            Status = AuthStatus.Ok,
            Readiness = new HostReadiness { ScreenRecordingGranted = _env.Screen.IsCaptureSupported, AccessibilityGranted = true },
        },
        SessionKind.FilesOnly => new AuthResult
        {
            Status = AuthStatus.Ok,
            SessionToken = sessionToken,
            Capabilities = new HostCapabilities
            {
                Codecs = [],
                CanManageVirtualDisplay = false,
                Clipboard = false,
                MaxFPS = 0,
                FileTransfer = true,
                FilesOnlySessions = true,
                Platform = _env.Platform,
            },
        },
        _ => new AuthResult
        {
            Status = AuthStatus.Ok,
            SessionToken = sessionToken,
            Displays = displays,
            Capabilities = new HostCapabilities
            {
                Codecs = _env.Encoders.SupportedCodecs,
                // No virtual displays on Windows: a fitter switches the shared display's mode instead.
                CanManageVirtualDisplay = _env.DisplayFitter is { IsEnabled: true },
                Clipboard = true,
                MaxFPS = 60,
                FileTransfer = ClientTakesFiles ? true : null,
                FilesOnlySessions = ClientTakesFiles ? true : null,
                Platform = _env.Platform,
                CursorShapes = _env.Cursor is not null ? true : null,
                // Like the Mac, offered to every client; only one that said macAudio is answered.
                Audio = _env.Audio is { UnavailableReason: null } ? true : null,
                Curtain = _env.Curtain is not null ? true : null,
            },
        },
    };

    private static AdmissionVerdict Refuse(AuthResult result, bool delay = false) => new(null, result, delay, false);

    private static AdmissionVerdict Admit(SessionKind kind, bool pairedNow) => new(kind, null, false, pairedNow);
}
