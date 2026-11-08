using System.Net;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Adaptive;
using Vantage.Protocol.Audio;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Files;
using Vantage.Protocol.Input;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;
using Vantage.Protocol.Video;

namespace Vantage.Protocol.Host;

/// <summary>Where a session is in its life.</summary>
public enum SessionState
{
    /// <summary>Between <c>hello</c> and <c>authResult</c>.</summary>
    Handshaking,
    /// <summary>A screen session (authenticated; streaming once <c>selectDisplay</c> arrives).</summary>
    Streaming,
    /// <summary>A files-only session: answers pings and holds the file channel's token.</summary>
    FilesOnly,
    /// <summary>Over.</summary>
    Closed,
}

/// <summary>
/// One client connection (Mac <c>HostSession</c>), created by <see cref="HostListener"/> after a
/// <c>hello</c>. It runs the handshake (version check, challenge, signature, pairing, readiness
/// probe, files-only), then either the files-only loop or the screen session: display choice,
/// capture → encode → <c>videoConfig</c>/<c>videoFrame</c> with idle suppression, forced IDRs and
/// P-frame dropping under backpressure, the capture watchdog and <c>HostStatus</c>, input (with the
/// display-sleep rule), clipboard, host commands, adaptive bitrate, the PC's sound for clients that
/// ask (<c>audioRequest</c> → <c>audioConfig</c>/<c>audioPacket</c>), and pings. Teardown revokes its
/// attach token and releases all input; an attached file channel carries on.
/// </summary>
/// <remarks>
/// State changes run one at a time on the session's own queue (like the Mac's actor). The platform
/// never talks to a session directly; it sees <see cref="SessionSnapshot"/>s through the listener.
/// </remarks>
public sealed class HostSessionCore
{
    /// <summary>
    /// A captured frame whose <see cref="ICapturedFrame.DirtyRatio"/> is at or below this is treated as
    /// unchanged and not encoded (idle suppression), unless a keyframe is pending.
    /// </summary>
    public const double IdleDirtyRatio = 0.0001;

    private static readonly TimeSpan s_refitDelay = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan s_modeSettleLimit = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan s_captureCatchUp = TimeSpan.FromSeconds(2);

    private readonly HostListener _listener;
    private readonly HostEnvironment _env;
    private readonly FramedConnection _connection;
    private readonly ILogger _log;
    private readonly SerialQueue _queue;
    private readonly CancellationTokenSource _ended = new();
    private Hello? _hello;
    private PeerIdentity? _peer;
    private bool _peerLookedUp;
    private bool _clientTakesFiles;
    private FileTransferEngine? _fileEngine;

    // Streaming state (queue only).
    // The capture lifecycle (what is wanted, restarts, sleep, the watchdog) is the supervisor's; the
    // session runs its steps and owns the capture, encoder and connection they act on.
    private readonly CaptureSupervisor _supervisor;
    private CancellationTokenSource? _ticker;
    // The client asked for the display fitted to its screen (fitViewport + useVirtualDisplay) and
    // hasn't sent restoreDisplays since: capture (re)starts fit the mode through IDisplayFitter.
    private bool _fitting;
    private DateTimeOffset _refitDue;
    private bool _refitScheduled;
    private DateTimeOffset? _modeChangedAt; // the next capture start checks it got the new mode's size
    private int _captureGeneration; // which capture start a stop callback belongs to
    private ICaptureStream? _capture;
    private IVideoEncoder? _encoder;
    private EncoderSink? _encoderSink;
    private ICapturedFrame? _latest;
    private bool _pendingEncode;
    private int _encodesInFlight;
    private bool _needsKeyframe = true;
    private bool _configSentForEncoder;
    private byte[][]? _lastParameterSets;
    private VideoCodec _codec = VideoCodec.H264;
    private ulong _sequence;
    private ulong _framesSent;
    private ulong _idleSkipped;
    private EncodingMode _loggedMode = EncodingMode.Motion;
    private AdaptiveController _adaptive = new(20_000);
    private int _currentFps = 60;
    private int _currentMaxQP = 44;
    private DateTimeOffset? _captureFailsUntil;
    private bool _monitoring;
    private IInputSink? _input;
    private IDisposable? _clipboardWatch;
    private IDisposable? _cursorWatch;
    private IDisposable? _statusWatch;
    private IDisposable? _keepAwake;
    private HostStatus? _lastStatus;

    // Audio (queue only, except the encoder, which sends packets from its own loop).
    private bool _clientTakesAudio;
    private IAudioCapture? _audioCapture;
    private AudioStreamEncoder? _audioEncoder;
    private long _audioDropped;

    internal HostSessionCore(HostListener listener, FramedConnection connection)
    {
        _listener = listener;
        _env = listener.Environment;
        _connection = connection;
        Peer = connection.PeerAddress;
        _log = _env.Logging.CreateLogger("Vantage.Session");
        _queue = new SerialQueue(_log);
        _supervisor = new CaptureSupervisor(_env.Time, _log);
        _connection.VideoDrained += () => _queue.Post(OnVideoDrained);
    }

    /// <summary>Stable id for this connection.</summary>
    public Guid Id { get; } = Guid.NewGuid();

    /// <summary>The peer's address (IPv4-mapped addresses mapped to IPv4).</summary>
    public IPAddress Peer { get; }

    /// <summary>Where the session is.</summary>
    public SessionState State { get; private set; } = SessionState.Handshaking;

    /// <summary>The tailnet's name for the device (whois) when known, else <c>Hello.clientName</c>.</summary>
    public string ClientName { get; private set; } = "iPad";

    /// <summary>The client key's fingerprint once known.</summary>
    public string Fingerprint { get; private set; } = "";

    /// <summary>The display being streamed, if any.</summary>
    public DisplayInfo? Display { get; private set; }

    /// <summary>When the session authenticated.</summary>
    public DateTimeOffset ConnectedAt { get; private set; }

    /// <summary>A readiness probe (never listed).</summary>
    public bool IsProbe => _hello?.IsReadinessProbe == true;

    internal SessionSnapshot Snapshot() =>
        new(Id, ClientName, Fingerprint, Peer, State == SessionState.FilesOnly, ConnectedAt, Display);

    private string HostNoun => _env.Platform == HostPlatforms.Windows ? "PC" : "Mac";

    // MARK: Run

    /// <summary>
    /// Runs the session on a connection whose first message (<paramref name="hello"/>) the listener
    /// already read. <paramref name="handshakeDeadline"/> fires when the 15 s handshake limit is up.
    /// Completes when the session is over.
    /// </summary>
    internal async Task RunAsync(Hello hello, CancellationToken handshakeDeadline)
    {
        _hello = hello;
        try
        {
            if (await HandshakeAsync(hello, handshakeDeadline).ConfigureAwait(false))
            {
                _listener.SessionChanged();
                if (State == SessionState.FilesOnly) await FilesOnlyLoopAsync().ConfigureAwait(false);
                else await ReceiveLoopAsync().ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            _log.LogInformation("handshake timed out");
        }
        catch (Exception error)
        {
            _log.LogError("session error: {Error}", error.Message);
        }
        await TeardownAsync().ConfigureAwait(false);
    }

    /// <summary>Ends the session deliberately: <c>disconnect{reason}</c>, then close.</summary>
    internal async Task DisconnectAsync(string reason)
    {
        try
        {
            await _connection.SendAsync(new DisconnectMessage { Reason = reason }).WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or TimeoutException)
        {
            // Closing anyway.
        }
        _connection.Close();
    }

    /// <summary>Closes the connection without a <c>disconnect</c> (the host is quitting; clients reconnect).</summary>
    internal void Abort() => _connection.Close();

    // MARK: Handshake

    private async Task<bool> HandshakeAsync(Hello hello, CancellationToken deadline)
    {
        if (hello.ProtocolVersion != VantageProtocol.Version)
        {
            await _connection.SendAsync(new AuthResult { Status = AuthStatus.VersionMismatch, Message = $"Protocol {VantageProtocol.Version} required" }).ConfigureAwait(false);
            return false;
        }
        var identity = _env.Identity.LoadOrCreate();
        var nonce = AuthTranscript.RandomNonce();
        Fingerprint = AuthTranscript.Fingerprint(hello.ClientPublicKey);
        ClientName = hello.ClientName;
        var isPaired = _env.Trust.IsTrusted(Fingerprint);
        var lightweight = hello.IsReadinessProbe == true || hello.Features?.FilesOnly == true;
        if (!lightweight) await LookUpPeerAsync(deadline).ConfigureAwait(false);
        var tailnetName = _peer?.TailnetName;
        // A client that sent a nonce wants proof this challenge comes from the holder of the host
        // key, and signs the transcript that binds both nonces and the connection's purpose. One
        // that didn't (an older Casement) signs the older transcript; the host still takes that.
        var clientNonce = hello.ClientNonce is { Length: AuthTranscript.NonceLength } sent ? sent : null;
        await _connection.SendAsync(new Challenge
        {
            HostName = _env.HostName,
            HostVersion = VantageProtocol.HostVersion,
            HostPublicKey = identity.PublicKey,
            Nonce = nonce,
            IsPaired = isPaired,
            PeerTailnetName = tailnetName,
            HostPlatform = _env.Platform,
            HostSignature = clientNonce is null ? null
                : _env.Ed25519.Sign(identity.Seed, AuthTranscript.HostBytes(clientNonce, nonce, identity.PublicKey, hello.ClientPublicKey)),
        }).ConfigureAwait(false);

        if (await _connection.ReceiveAsync(deadline).ConfigureAwait(false) is not Authenticate auth)
        {
            _log.LogInformation("handshake ended before authenticate");
            return false;
        }
        var signatureValid = clientNonce is null
            ? AuthTranscript.Verify(_env.Ed25519, auth.Signature, nonce, identity.PublicKey, hello.ClientPublicKey)
            : AuthTranscript.VerifyClient(_env.Ed25519, auth.Signature, clientNonce, nonce, identity.PublicKey, hello.ClientPublicKey,
                                          AuthTranscript.Purpose(hello));
        if (!signatureValid)
        {
            await _connection.SendAsync(new AuthResult { Status = AuthStatus.BadSignature }).ConfigureAwait(false);
            return false;
        }
        if (!isPaired)
        {
            if (auth.PairingCode is not { } code)
            {
                await _connection.SendAsync(new AuthResult { Status = AuthStatus.PairingRequired, Message = $"Enter the pairing code shown on the {HostNoun}" }).ConfigureAwait(false);
                return false;
            }
            switch (_listener.Pairing.Consume(code))
            {
                case PairingCheck.Accepted:
                    break;
                case PairingCheck.Incorrect:
                    // Slow down guessing; the code also burns after five misses.
                    await Task.Delay(TimeSpan.FromSeconds(1), _env.Time, CancellationToken.None).ConfigureAwait(false);
                    await _connection.SendAsync(new AuthResult { Status = AuthStatus.BadPairingCode, Message = $"Incorrect pairing code. Try the code shown on the {HostNoun}." }).ConfigureAwait(false);
                    return false;
                default:
                    await Task.Delay(TimeSpan.FromSeconds(1), _env.Time, CancellationToken.None).ConfigureAwait(false);
                    await _connection.SendAsync(new AuthResult
                    {
                        Status = AuthStatus.BadPairingCode,
                        Message = $"That pairing code has expired. On the {HostNoun}, choose Show Pairing Code and enter the new one.",
                    }).ConfigureAwait(false);
                    return false;
            }
            _env.Trust.Trust(Fingerprint, hello.ClientName, _peer?.DeviceName);
            _listener.RaisePaired(Fingerprint, ClientName);
        }

        if (hello.IsReadinessProbe == true)
        {
            // Never enumerate displays, start capture, or touch the clipboard for a probe. Windows has no
            // grants to report, but capture can still be unsupported (no Windows.Graphics.Capture, a
            // service session): say so here, where the client's device list reads it, instead of
            // answering "ready" and denying the stream request a moment later.
            await _connection.SendAsync(new AuthResult
            {
                Status = AuthStatus.Ok,
                Readiness = new HostReadiness { ScreenRecordingGranted = _env.Screen.IsCaptureSupported, AccessibilityGranted = true },
            }).ConfigureAwait(false);
            return false;
        }

        if (hello.Features?.FilesOnly == true)
        {
            if (hello.Features.FileTransfer != true)
            {
                await _connection.SendAsync(new AuthResult { Status = AuthStatus.Denied, Message = "Nothing to do on this connection." }).ConfigureAwait(false);
                return false;
            }
            _clientTakesFiles = true;
            var token = _listener.AttachTokens.Issue(this, Peer);
            State = SessionState.FilesOnly;
            ConnectedAt = _env.Time.GetUtcNow();
            await _connection.SendAsync(new AuthResult
            {
                Status = AuthStatus.Ok,
                SessionToken = token,
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
            }).ConfigureAwait(false);
            _log.LogInformation("files-only session for {Client}", hello.ClientName);
            return true;
        }

        if (!_env.Screen.IsCaptureSupported)
        {
            await _connection.SendAsync(new AuthResult { Status = AuthStatus.Denied, Message = _env.Screen.CaptureUnsupportedMessage }).ConfigureAwait(false);
            return false;
        }
        // A sleeping display may list nothing, so wake it before looking.
        if (_env.Status.Current.IsDisplayAsleep) await WakeDisplayForStreamingAsync().ConfigureAwait(false);
        var displays = await _env.Screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
        _clientTakesFiles = hello.Features?.FileTransfer == true;
        _clientTakesAudio = hello.Features?.MacAudio == true;
        var sessionToken = _clientTakesFiles ? _listener.AttachTokens.Issue(this, Peer) : null;
        State = SessionState.Streaming;
        ConnectedAt = _env.Time.GetUtcNow();
        await _connection.SendAsync(new AuthResult
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
                FileTransfer = _clientTakesFiles ? true : null,
                FilesOnlySessions = _clientTakesFiles ? true : null,
                Platform = _env.Platform,
                CursorShapes = _env.Cursor is not null ? true : null,
                // Like the Mac, offered to every client; only one that said macAudio is answered.
                Audio = _env.Audio is { UnavailableReason: null } ? true : null,
                Curtain = _env.Curtain is not null ? true : null,
            },
        }).ConfigureAwait(false);
        _log.LogInformation("client authenticated: {Client}", hello.ClientName);
        // A curtain left up by a session that ended: this one takes it on and can lower it.
        if (hello.Features?.Curtain == true && _env.Curtain?.Adopt(Id, _connection.Post) == true)
            _connection.Post(new CurtainStatus { IsUp = true });
        return true;
    }

    /// <summary>Whois for the peer, once per session, within 2 s; the device name becomes <see cref="ClientName"/>.</summary>
    private async Task LookUpPeerAsync(CancellationToken cancellationToken)
    {
        if (_peerLookedUp || _env.Peers is not { } peers) return;
        _peerLookedUp = true;
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            limit.CancelAfter(TimeSpan.FromSeconds(2));
            _peer = await peers.WhoisAsync(Peer, limit.Token).ConfigureAwait(false);
            if (!string.IsNullOrEmpty(_peer?.DeviceName)) ClientName = _peer.DeviceName;
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            _log.LogDebug("whois failed: {Error}", error.Message);
        }
    }

    // MARK: Loops

    private async Task ReceiveLoopAsync()
    {
        var undecodable = 0;
        while (await _connection.ReceiveAsync().ConfigureAwait(false) is { } message)
        {
            switch (message)
            {
                case Ping ping:
                    _connection.Post(new Pong { EchoNanos = ping.SentAtNanos });
                    continue;
                case DisconnectMessage:
                    return;
                case UnknownMessage unknown:
                    _log.LogInformation("skipping unknown kind {Kind} ({Length} bytes)", unknown.RawKind, unknown.Length);
                    continue;
                case UndecodableMessage bad:
                    if (undecodable++ < 5) _log.LogError("dropping a {Kind} that didn't decode: {Error}", bad.MessageKind, bad.Error.Message);
                    continue;
            }
            try
            {
                await _queue.RunAsync(() => HandleAsync(message)).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                if (_connection.IsClosed) return; // the client went away mid-message
                _log.LogError("handling {Kind} failed: {Error}", message.Kind, error.Message);
            }
        }
    }

    /// <summary>A files-only session's primary connection only keeps the session (and its token) alive.</summary>
    private async Task FilesOnlyLoopAsync()
    {
        var ignored = 0;
        while (await _connection.ReceiveAsync().ConfigureAwait(false) is { } message)
        {
            switch (message)
            {
                case Ping ping:
                    _connection.Post(new Pong { EchoNanos = ping.SentAtNanos });
                    break;
                case DisconnectMessage:
                    return;
                default:
                    if (ignored++ == 0) _log.LogInformation("files-only session ignoring {Kind}", message.Kind);
                    break;
            }
        }
    }

    private async Task HandleAsync(IMessage message)
    {
        switch (message)
        {
            case SelectDisplay select:
                await SelectDisplayAsync(select).ConfigureAwait(false);
                break;
            case PointerEvent pointer:
                _adaptive.NoteInput();
                if (AdmitsInput(pointer.Action == PointerAction.Up)) _input?.Pointer(pointer);
                break;
            case ScrollEvent scroll:
                _adaptive.NoteInput();
                if (AdmitsInput(false)) _input?.Scroll(scroll);
                break;
            case KeyEvent key:
                _adaptive.NoteInput();
                if (AdmitsInput(!key.IsDown)) _input?.Key(key);
                break;
            case TextInput text:
                if (AdmitsInput(false) && _input is { } input)
                {
                    // More than one key event's worth (a dictation, a paste from the iPad) is pasted:
                    // Chromium and Electron apps drop keys from a fast burst of typed text. A
                    // clipboard another app is holding falls back to typing, so nothing is lost.
                    if (!ClipboardPaster.ShouldPaste(text.Text) || !_listener.Paster.Paste(text.Text, input)) input.Text(text.Text);
                }
                break;
            case ClipboardPayload clipboard:
                if (!clipboard.IsEmpty) _env.Clipboard.Apply(clipboard);
                break;
            case QualityFeedback feedback:
                if (_adaptive.Apply(feedback) is { } bitrate) _encoder?.SetBitrate(bitrate);
                break;
            case RequestKeyframe:
                await RequestKeyframeAsync().ConfigureAwait(false);
                break;
            case ViewportChanged changed:
                if (_fitting && _supervisor.Wanted is { Selection: DisplaySelection.FitViewport } fitted)
                {
                    _supervisor.Retarget(fitted with { Selection = new DisplaySelection.FitViewport(changed.Viewport) });
                    ScheduleRefit();
                }
                await RequestKeyframeAsync().ConfigureAwait(false);
                break;
            case HostCommandMessage command:
                await HandleCommandAsync(command.Command).ConfigureAwait(false);
                break;
            case AudioRequest request:
                if (!_clientTakesAudio) break; // never send audio kinds to a client that didn't ask for them
                if (request.Enabled) await StartAudioAsync().ConfigureAwait(false);
                else await StopAudioAsync().ConfigureAwait(false);
                break;
            case CurtainRequest request:
                HandleCurtain(request.Enabled);
                break;
            default:
                break; // dictation, modifierState, …: never advertised, ignored
        }
    }

    private void HandleCurtain(bool enabled)
    {
        if (_env.Curtain is not { } curtain) return;
        string? problem;
        try
        {
            problem = curtain.Set(enabled, Id, _connection.Post);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _log.LogError("the curtain failed: {Error}", error.Message);
            problem = $"Casement Host couldn't black out this {HostNoun}'s screen.";
        }
        _log.LogInformation("curtain request {Enabled}: {Result}", enabled, problem ?? "done");
        _connection.Post(new CurtainStatus { IsUp = enabled && problem is null, Unavailable = problem });
    }

    // MARK: Streaming

    private async Task SelectDisplayAsync(SelectDisplay select)
    {
        _fitting = select is { Selection: DisplaySelection.FitViewport, UseVirtualDisplay: true } && _env.DisplayFitter is { IsEnabled: true };
        if (_captureFailsUntil is null && _listener.Options.CaptureFailsFor is { } fails)
        {
            _captureFailsUntil = _env.Time.GetUtcNow() + fails;
            _log.LogInformation("--capture-fails-for: capture fails for {Seconds} s", fails.TotalSeconds);
        }
        StartMonitoring();
        await ApplyAsync(_supervisor.DeviceAsked(select, _env.Status.Current.IsDisplayAsleep)).ConfigureAwait(false);
    }

    /// <summary>Runs the supervisor's steps in order, feeding each start's and stop's outcome back to it.</summary>
    private async Task ApplyAsync(IReadOnlyList<CaptureStep> steps)
    {
        foreach (var step in steps)
        {
            switch (step)
            {
                case CaptureStep.WakeDisplayAndWait:
                    await WakeDisplayForStreamingAsync().ConfigureAwait(false);
                    break;
                case CaptureStep.Start start:
                    await ApplyAsync(await StartAsync(start.Target).ConfigureAwait(false)).ConfigureAwait(false);
                    break;
                case CaptureStep.Stop stop:
                    if (_capture is { } capture) await CaptureStoppedAsync(capture, stop.Reason).ConfigureAwait(false);
                    break;
                case CaptureStep.SendStatus status:
                    SendStatus(status.Force);
                    break;
                case CaptureStep.WakeDisplay:
                    _env.Power.WakeDisplay();
                    break;
                case CaptureStep.ForceKeyframe:
                    await RequestKeyframeAsync().ConfigureAwait(false);
                    break;
            }
        }
        if (_supervisor.WantsTicks) StartTicker();
        else StopTicker();
    }

    /// <summary>One start, reported to the supervisor. An <see cref="IOException"/> (the connection) still ends the session.</summary>
    private async Task<IReadOnlyList<CaptureStep>> StartAsync(SelectDisplay target)
    {
        try
        {
            var (display, codec) = await StartStreamingAsync(target).ConfigureAwait(false);
            return _supervisor.Started(display, codec);
        }
        catch (Exception error) when (error is not IOException)
        {
            return _supervisor.StartFailed(error.Message);
        }
    }

    /// <summary>Sets up capture and encoding. Throws when there's nothing to capture; callers keep the session.</summary>
    private async Task<(DisplayInfo Display, VideoCodec Codec)> StartStreamingAsync(SelectDisplay select)
    {
        var began = _env.Time.GetTimestamp();
        await StopCaptureAsync().ConfigureAwait(false);
        if (_captureFailsUntil is { } until && _env.Time.GetUtcNow() < until) throw new CaptureUnavailableException("capture fails on purpose (--capture-fails-for)");
        var displays = await _env.Screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
        displays = await FitDisplayModeAsync(select, displays).ConfigureAwait(false);
        var chosen = select.Selection switch
        {
            DisplaySelection.Display byId => displays.FirstOrDefault(d => d.Id == byId.Id)
                                             ?? throw new CaptureUnavailableException($"display {byId.Id} isn't connected"),
            _ => displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault()
                 ?? throw new CaptureUnavailableException("no displays to capture"),
        };
        var fps = Math.Clamp(select.TargetFPS, 1, 60);
        var hello = _hello!;
        // A client that draws the pointer itself gets it at its own frame rate, the way Remote
        // Desktop does; leaving it out of the video also stops a moving pointer from costing frames.
        var localCursor = hello.Features?.LocalCursor == true && _env.Cursor is not null;
        var request = new CaptureRequest(chosen, fps, IncludesCursor: !localCursor);
        var capture = await StartCaptureAsync(request).ConfigureAwait(false);
        if (_modeChangedAt is { } modeChangedAt)
        {
            // Just after a mode change, Windows.Graphics.Capture can still size a new capture for
            // the old mode, which then stops at its first frame: start again until it matches (≤ 2 s).
            _modeChangedAt = null;
            while ((capture.FrameWidth != chosen.PixelWidth || capture.FrameHeight != chosen.PixelHeight)
                   && _env.Time.GetUtcNow() - modeChangedAt < s_captureCatchUp)
            {
                _log.LogInformation("capture still sized {Width}x{Height} for the old mode; starting it again", capture.FrameWidth, capture.FrameHeight);
                await SafeDisposeAsync(capture).ConfigureAwait(false);
                await Task.Delay(TimeSpan.FromMilliseconds(100), _env.Time, CancellationToken.None).ConfigureAwait(false);
                capture = await StartCaptureAsync(request).ConfigureAwait(false);
            }
        }
        var (width, height) = VideoGeometry.EncodedSize(capture.FrameWidth, capture.FrameHeight, hello.MaxDecodeWidth, hello.MaxDecodeHeight);
        _adaptive = new AdaptiveController(AdaptiveController.StartBitrate(width * height, fps), _env.Time);
        _currentFps = fps;
        _currentMaxQP = _adaptive.MaxQP;
        var codec = ChooseCodec(select.PreferredCodec, _env.Encoders.SupportedCodecs, hello.SupportedCodecs);
        IVideoEncoder encoder;
        try
        {
            try
            {
                encoder = _env.Encoders.Create(capture, new VideoEncoderSettings(codec, width, height, fps, _adaptive.BitrateKbps, _adaptive.MaxQP));
            }
            catch (CaptureUnavailableException error) when (codec != VideoCodec.H264 && _env.Encoders.SupportedCodecs.Contains(VideoCodec.H264))
            {
                // Advertised but refused on this capture's GPU (another adapter has the HEVC
                // encoder, or the driver turned the settings down): H.264 still gets a picture.
                _log.LogWarning("{Codec} encoder unavailable ({Reason}); streaming H.264", codec, error.Message);
                codec = VideoCodec.H264;
                encoder = _env.Encoders.Create(capture, new VideoEncoderSettings(codec, width, height, fps, _adaptive.BitrateKbps, _adaptive.MaxQP));
            }
            var sink = new EncoderSink(this, encoder);
            encoder.Start(sink);
            _encoderSink = sink;
        }
        catch
        {
            await capture.DisposeAsync().ConfigureAwait(false);
            throw;
        }
        _capture = capture;
        _encoder = encoder;
        _codec = codec;
        _configSentForEncoder = false;
        _lastParameterSets = null;
        Display = chosen;

        // The input sink (and whatever it holds) survives capture restarts. It glides after an
        // iPad flick as the Mac host does, ticking on this session's queue; teardown's ReleaseAll
        // and Dispose end the glide and its timer.
        _input ??= new MomentumInputSink(_env.CreateInputSink(), _env.Time, work => _queue.Post(work));
        _input.SetDisplay(chosen);

        if (_clipboardWatch is null)
        {
            _clipboardWatch = _env.Clipboard.Watch(payload => _queue.Post(() =>
            {
                if (State == SessionState.Streaming && !payload.IsEmpty) _connection.PostBulk(payload);
            }));
        }
        if (_env.Clipboard.Read() is { IsEmpty: false } initial) _connection.PostBulk(initial);

        _cursorWatch?.Dispose();
        _cursorWatch = localCursor ? _env.Cursor!.Watch(chosen, state => _queue.Post(() => SendCursor(state))) : null;

        await _connection.SendAsync(new StreamConfig { Display = chosen, Codec = codec, Fps = fps, BitrateKbps = _adaptive.BitrateKbps }).ConfigureAwait(false);
        _needsKeyframe = true;
        _listener.SessionChanged();
        _log.LogInformation("streaming display {Id} at {Width}x{Height} (encoded {EncodedWidth}x{EncodedHeight}, {Codec}); stream setup took {Ms} ms",
                            chosen.Id, chosen.PixelWidth, chosen.PixelHeight, width, height, codec, (int)_env.Time.GetElapsedTime(began).TotalMilliseconds);
        return (chosen, codec);
    }

    /// <summary>
    /// With capture stopped: fits the main display's mode to the viewport while the client wants a
    /// fitted display (the Mac's virtual display, done the Windows way), or puts back a mode this
    /// session changed once it doesn't. Returns the displays as they are afterwards. A refused mode,
    /// or a display another session holds, streams what's there.
    /// </summary>
    private async Task<IReadOnlyList<DisplayInfo>> FitDisplayModeAsync(SelectDisplay select, IReadOnlyList<DisplayInfo> displays)
    {
        if (_env.DisplayFitter is not { } fitter) return displays;
        var main = displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault();
        bool changed;
        try
        {
            if (_fitting && select.Selection is DisplaySelection.FitViewport fit && main is not null)
            {
                var result = fitter.Fit(Id, main, fit.Viewport);
                if (result is DisplayFitResult.Busy) _log.LogInformation("another device has display {Id} fitted to its screen; streaming it as it is", main.Id);
                changed = result is DisplayFitResult.Changed;
            }
            else
            {
                // A display chosen by id while fitting, or fitting over: only the latter puts the mode back.
                changed = !_fitting && fitter.Restore(Id);
            }
        }
        catch (Exception error)
        {
            _log.LogError("fitting the display mode failed: {Error}", error.Message);
            return displays;
        }
        if (!changed) return displays;
        _modeChangedAt = _env.Time.GetUtcNow();

        // The monitor's rect follows the mode at once, but give it a moment (≤ 1 s) to report the
        // new size so streamConfig describes the mode being shown.
        var started = _env.Time.GetTimestamp();
        while (true)
        {
            var now = await _env.Screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
            var after = main is null ? null : now.FirstOrDefault(d => d.Id == main.Id);
            if (main is null || after is null || after.PixelWidth != main.PixelWidth || after.PixelHeight != main.PixelHeight
                || after.Scale != main.Scale
                || _env.Time.GetElapsedTime(started) >= s_modeSettleLimit)
            {
                if (after is not null)
                    _log.LogInformation("display {Id} now {Width}x{Height} at {Scale}x ({PointWidth}x{PointHeight} points)",
                                        after.Id, after.PixelWidth, after.PixelHeight, after.Scale, after.PointWidth, after.PointHeight);
                return now;
            }
            await Task.Delay(TimeSpan.FromMilliseconds(100), _env.Time, CancellationToken.None).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// A fitted session's viewport changed (rotation, Stage Manager, a window resize): fit again
    /// 500 ms after the last change, so a rotation animation switches the mode once, not per step.
    /// </summary>
    private void ScheduleRefit()
    {
        _refitDue = _env.Time.GetUtcNow() + s_refitDelay;
        if (_refitScheduled) return;
        _refitScheduled = true;
        var ended = _ended.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                var wait = s_refitDelay;
                while (true)
                {
                    await Task.Delay(wait, _env.Time, ended).ConfigureAwait(false);
                    TimeSpan? more = null;
                    await _queue.RunAsync(async () =>
                    {
                        var left = _refitDue - _env.Time.GetUtcNow();
                        if (left > TimeSpan.Zero)
                        {
                            more = left;
                            return;
                        }
                        _refitScheduled = false;
                        await RefitAsync().ConfigureAwait(false);
                    }).ConfigureAwait(false);
                    if (more is not { } next) return;
                    wait = next;
                }
            }
            catch (OperationCanceledException)
            {
                // Session over.
            }
        });
    }

    private async Task RefitAsync()
    {
        if (State != SessionState.Streaming || !_fitting || _env.DisplayFitter is not { } fitter
            || _supervisor.Wanted is not { Selection: DisplaySelection.FitViewport fit } wanted || Display is not { } display) return;
        if (!fitter.WouldChange(Id, display, fit.Viewport)) return;
        _log.LogInformation("viewport now {Width}x{Height} points at {Scale}x: fitting the display again",
                            fit.Viewport.WidthPoints, fit.Viewport.HeightPoints, fit.Viewport.Scale);
        _needsKeyframe = true;
        await ApplyAsync(_supervisor.DeviceAsked(wanted, _env.Status.Current.IsDisplayAsleep)).ConfigureAwait(false);
    }

    /// <summary><c>restoreDisplays</c>: put the mode back now and stream the display as it is.</summary>
    private async Task RestoreDisplaysAsync()
    {
        if (_env.DisplayFitter is not { } fitter) return;
        var wasFitting = _fitting;
        _fitting = false;
        if (!wasFitting || _supervisor.Wanted is null)
        {
            if (fitter.Restore(Id)) _log.LogInformation("display mode restored");
            return;
        }
        // Stop first: a running capture would stop itself on the size change, and its late stop
        // could land on the capture that replaces it.
        await StopCaptureAsync().ConfigureAwait(false);
        if (fitter.Restore(Id))
        {
            _log.LogInformation("display mode restored");
            _modeChangedAt = _env.Time.GetUtcNow();
        }
        _needsKeyframe = true;
        await ApplyAsync(_supervisor.RestartAsked("display mode restored")).ConfigureAwait(false);
    }

    /// <summary>
    /// The codec to stream: the client's <c>preferredCodec</c> when this host can encode it, else the
    /// host's best (the first of <paramref name="hostCodecs"/>, HEVC when there is an HEVC encoder),
    /// as the Mac does with <c>preferredCodec ?? .hevc</c>. A codec the client's <c>hello</c> left
    /// out of a non-empty <c>supportedCodecs</c> is never chosen; H.264 is the last resort.
    /// </summary>
    public static VideoCodec ChooseCodec(VideoCodec? preferred, IReadOnlyList<VideoCodec> hostCodecs, IReadOnlyList<VideoCodec>? clientCodecs)
    {
        bool Usable(VideoCodec codec) => hostCodecs.Contains(codec) && (clientCodecs is not { Count: > 0 } || clientCodecs.Contains(codec));
        if (preferred is { } wanted && Usable(wanted)) return wanted;
        foreach (var codec in hostCodecs)
            if (Usable(codec)) return codec;
        return VideoCodec.H264;
    }

    /// <summary>The pointer's look first, then where it is and whether it shows, on the control lane.</summary>
    private void SendCursor(CursorState state)
    {
        if (State != SessionState.Streaming || _cursorWatch is null) return;
        if (state.Shape is { } shape) _connection.Post(shape);
        _connection.Post(new CursorPosition { X = state.X, Y = state.Y, IsVisible = state.IsVisible });
    }

    private void OnCapturedFrame(ICapturedFrame frame)
    {
        if (!_queue.Post(() => Ingest(frame))) frame.Dispose();
    }

    /// <summary>Starts a capture whose stop callback is ignored once a newer start has replaced it.</summary>
    private Task<ICaptureStream> StartCaptureAsync(CaptureRequest request)
    {
        var generation = ++_captureGeneration;
        return _env.Screen.StartAsync(request, OnCapturedFrame, reason => OnCaptureStopped(generation, reason), CancellationToken.None);
    }

    private void OnCaptureStopped(int generation, string reason)
    {
        _queue.Post(async () =>
        {
            // Only the capture that is current: a stop from a replaced one (posted before it was
            // disposed, say a capture that came up sized for the old display mode) is old news.
            if (generation == _captureGeneration && _capture is not null) await CaptureStoppedAsync(_capture, reason).ConfigureAwait(false);
        });
    }

    private async Task Ingest(ICapturedFrame frame)
    {
        if (_capture is null || _encoder is null || State != SessionState.Streaming)
        {
            frame.Dispose();
            return;
        }
        await ApplyAsync(_supervisor.FrameArrived()).ConfigureAwait(false);
        var fps = Math.Min(_adaptive.Observe(frame.DirtyRatio), _supervisor.Wanted?.TargetFPS ?? 60);
        if (_adaptive.Mode != _loggedMode)
        {
            _loggedMode = _adaptive.Mode;
            _log.LogInformation("video mode {Mode} (max QP {QP}); {Skipped} unchanged frames skipped so far",
                                _loggedMode == EncodingMode.Text ? "text" : "motion", _adaptive.MaxQP, _idleSkipped);
        }
        if (fps != _currentFps)
        {
            _currentFps = fps;
            _capture.SetFrameRate(fps);
            _encoder.SetFrameRate(fps);
        }
        if (_adaptive.MaxQP != _currentMaxQP)
        {
            _currentMaxQP = _adaptive.MaxQP;
            _encoder.SetMaxQP(_currentMaxQP);
        }
        var previous = _latest;
        _latest = frame;
        previous?.Dispose();

        // Idle suppression: skip a static frame, but always honour a pending keyframe.
        if (frame.DirtyRatio <= IdleDirtyRatio && !_needsKeyframe && _framesSent > 0)
        {
            _idleSkipped++;
            return;
        }
        if (_encodesInFlight >= 1)
        {
            _pendingEncode = true;
            return;
        }
        await EncodeLatestAsync().ConfigureAwait(false);
    }

    /// <summary>Encodes the newest frame (forcing an IDR when one is due). A due IDR waits while the video lane is backed up.</summary>
    private async Task EncodeLatestAsync()
    {
        if (_encoder is not { } encoder || _latest is not { } frame || _encodesInFlight > 0) return;
        if (_needsKeyframe && _connection.IsVideoBacklogged)
        {
            _pendingEncode = true; // VideoDrained brings it back
            return;
        }
        _pendingEncode = false;
        var force = _needsKeyframe;
        _needsKeyframe = false;
        _encodesInFlight++;
        try
        {
            await encoder.EncodeAsync(frame, force, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            _encodesInFlight = Math.Max(0, _encodesInFlight - 1);
            if (force) _needsKeyframe = true;
            _log.LogError("encode failed: {Error}", error.Message);
        }
    }

    private async Task RequestKeyframeAsync()
    {
        _needsKeyframe = true;
        // A static screen sends no new frames: re-encode the last one now.
        if (_encodesInFlight == 0) await EncodeLatestAsync().ConfigureAwait(false);
    }

    private async Task OnVideoDrained()
    {
        if (_needsKeyframe && _encodesInFlight == 0) await EncodeLatestAsync().ConfigureAwait(false);
    }

    private async Task EmitAsync(IVideoEncoder source, EncodedFrame? output)
    {
        if (!ReferenceEquals(source, _encoder)) return; // a replaced encoder's late output
        _encodesInFlight = Math.Max(0, _encodesInFlight - 1);
        if (output is not null) SendEncoded(output);
        if (_pendingEncode || (_needsKeyframe && _latest is not null)) await EncodeLatestAsync().ConfigureAwait(false);
    }

    private void SendEncoded(EncodedFrame output)
    {
        AccessUnit unit;
        try
        {
            unit = output.Format == NalFormat.AnnexB ? AnnexB.ToAccessUnit(output.Data, _codec) : AnnexB.FromUnits(AnnexB.SplitAvcc(output.Data), _codec);
        }
        catch (FormatException error)
        {
            _log.LogError("encoder output didn't parse: {Error}", error.Message);
            _needsKeyframe = true;
            return;
        }
        if (unit.Avcc.Length == 0) return;
        if (unit.IsKeyframe)
        {
            if (WireParameterSets(unit, output.ParameterSets) is { } sets)
            {
                if (!_configSentForEncoder || _lastParameterSets is null || !SameSets(sets, _lastParameterSets))
                {
                    _connection.PostVideo(new VideoConfig
                    {
                        Codec = _codec,
                        Width = output.Width,
                        Height = output.Height,
                        ParameterSets = sets,
                        NalLengthSize = 4,
                        Fps = _currentFps,
                    }, droppable: false);
                    _lastParameterSets = sets;
                    _configSentForEncoder = true;
                }
            }
        }
        if (!_configSentForEncoder)
        {
            // The client can't decode anything before a videoConfig: wait for an IDR.
            _needsKeyframe = true;
            return;
        }
        var frame = new VideoFrame
        {
            Sequence = _sequence++,
            CaptureNanos = output.CaptureNanos,
            IsKeyframe = unit.IsKeyframe,
            Width = (uint)output.Width,
            Height = (uint)output.Height,
            Data = unit.Avcc,
        };
        if (_connection.PostVideo(frame, droppable: !unit.IsKeyframe))
        {
            _framesSent++;
            return;
        }
        // The link is behind: this P-frame is gone, so the picture needs an IDR once it catches up.
        _needsKeyframe = true;
        if (_adaptive.NoteBacklog() is { } bitrate) _encoder?.SetBitrate(bitrate);
    }

    /// <summary>
    /// The keyframe's parameter sets in wire order for the current codec (H.264 <c>[SPS, PPS]</c>,
    /// HEVC <c>[VPS, SPS, PPS]</c>), each from the AU or else from what the encoder handed over
    /// beside it; null while any is missing.
    /// </summary>
    private byte[][]? WireParameterSets(AccessUnit unit, IReadOnlyList<byte[]>? side)
    {
        byte[]? Side(int type) => side?.FirstOrDefault(p => NalType.Of(p, _codec) == type);
        if (_codec == VideoCodec.Hevc)
        {
            var vps = unit.Vps ?? Side(HevcNalType.Vps);
            var hevcSps = unit.Sps ?? Side(HevcNalType.Sps);
            var hevcPps = unit.Pps ?? Side(HevcNalType.Pps);
            return vps is not null && hevcSps is not null && hevcPps is not null ? [vps, hevcSps, hevcPps] : null;
        }
        var sps = unit.Sps ?? Side(NalType.Sps);
        var pps = unit.Pps ?? Side(NalType.Pps);
        return sps is not null && pps is not null ? [sps, pps] : null;
    }

    private static bool SameSets(byte[][] a, byte[][] b) =>
        a.Length == b.Length && a.Zip(b).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second));

    // MARK: Commands, status, display sleep

    private async Task HandleCommandAsync(HostCommand command)
    {
        switch (command)
        {
            case HostCommand.SleepDisplay:
                _supervisor.SleepAsked();
                _env.Power.SleepDisplay();
                break;
            case HostCommand.WakeDisplay:
                await ApplyAsync(_supervisor.WakeAsked()).ConfigureAwait(false); // Wake doubles as Retry
                break;
            case HostCommand.LockScreen:
                _env.Power.LockScreen();
                break;
            case HostCommand.ReleaseAllInput:
                _input?.ReleaseAll();
                break;
            case HostCommand.RefreshDisplays:
                var displays = await _env.Screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
                _connection.Post(new DisplayList { Displays = displays });
                break;
            case HostCommand.RestoreDisplays:
                await RestoreDisplaysAsync().ConfigureAwait(false);
                break;
        }
    }

    private HostStatus CurrentStatus()
    {
        var conditions = _env.Status.Current;
        return new HostStatus
        {
            IsScreenLocked = conditions.IsScreenLocked,
            IsSecureInputActive = conditions.IsSecureDesktop,
            InputPath = HostInputPath.Native,
            Message = conditions.Message,
            IsDisplayAsleep = conditions.IsDisplayAsleep,
            IsScreenUnavailable = _supervisor.ScreenUnavailable && !conditions.IsDisplayAsleep,
        };
    }

    private void SendStatus(bool force = false)
    {
        var status = CurrentStatus();
        if (!force && status == _lastStatus) return;
        _lastStatus = status;
        _connection.Post(status);
    }

    /// <summary>Session-long pieces, set up with the first stream and kept through capture restarts.</summary>
    private void StartMonitoring()
    {
        if (_monitoring) return;
        _monitoring = true;
        _keepAwake = _env.Power.KeepAwake();
        _statusWatch = _env.Status.Watch(() => _queue.Post(HostStatusChangedAsync));
    }

    private async Task HostStatusChangedAsync()
    {
        if (State != SessionState.Streaming) return;
        await ApplyAsync(_supervisor.StatusChanged(_env.Status.Current.IsDisplayAsleep)).ConfigureAwait(false);
    }

    /// <summary>The supervisor's input-while-asleep rule; a wake it asks for happens here.</summary>
    private bool AdmitsInput(bool isRelease)
    {
        var admits = _supervisor.AdmitsInput(isRelease, out var wakeDisplay);
        if (wakeDisplay) _env.Power.WakeDisplay();
        return admits;
    }

    /// <summary>Wakes the display and waits (up to ~3 s) for it to be awake with displays listed.</summary>
    private async Task WakeDisplayForStreamingAsync()
    {
        _env.Power.WakeDisplay();
        var started = _env.Time.GetTimestamp();
        while (_env.Time.GetElapsedTime(started) < TimeSpan.FromSeconds(3))
        {
            if (!_env.Status.Current.IsDisplayAsleep && (await _env.Screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false)).Count > 0) break;
            await Task.Delay(TimeSpan.FromMilliseconds(150), _env.Time, CancellationToken.None).ConfigureAwait(false);
        }
    }

    // MARK: Capture watchdog

    /// <summary>Ticks the supervisor every <see cref="CaptureSupervisor.TickInterval"/> while it wants the clock (capture lost, or up without a frame yet).</summary>
    private void StartTicker()
    {
        if (_ticker is not null) return;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(_ended.Token);
        _ticker = stop;
        _ = Task.Run(async () =>
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    await Task.Delay(CaptureSupervisor.TickInterval, _env.Time, stop.Token).ConfigureAwait(false);
                    var more = true;
                    await _queue.RunAsync(async () =>
                    {
                        if (!ReferenceEquals(_ticker, stop) || State != SessionState.Streaming)
                        {
                            more = false;
                            return;
                        }
                        await ApplyAsync(_supervisor.Tick()).ConfigureAwait(false); // ApplyAsync stops this ticker once the supervisor is done with the clock
                        more = ReferenceEquals(_ticker, stop);
                    }).ConfigureAwait(false);
                    if (!more) return;
                }
            }
            catch (OperationCanceledException)
            {
                // Session over or capture back.
            }
        });
    }

    private void StopTicker()
    {
        _ticker?.Cancel();
        _ticker = null;
    }

    /// <summary>Capture stopped by itself (or its encoder failed, or it never framed): the session, input, and power carry on; only capture waits.</summary>
    private async Task CaptureStoppedAsync(ICaptureStream capture, string reason)
    {
        if (!ReferenceEquals(capture, _capture)) return;
        await StopCaptureAsync().ConfigureAwait(false);
        _needsKeyframe = true;
        await ApplyAsync(_supervisor.CaptureStopped(reason)).ConfigureAwait(false);
    }

    /// <summary>Stops capture and encoding only; input, power, and status stay.</summary>
    private async Task StopCaptureAsync()
    {
        var capture = _capture;
        var encoder = _encoder;
        _cursorWatch?.Dispose();
        _cursorWatch = null;
        _capture = null;
        _encoder = null;
        _encoderSink = null;
        _encodesInFlight = 0;
        _pendingEncode = false;
        _latest?.Dispose();
        _latest = null;
        if (capture is not null) await SafeDisposeAsync(capture).ConfigureAwait(false);
        if (encoder is not null) await SafeDisposeAsync(encoder).ConfigureAwait(false);
    }

    private async Task SafeDisposeAsync(IAsyncDisposable disposable)
    {
        try
        {
            await disposable.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            _log.LogError("stopping {Type} failed: {Error}", disposable.GetType().Name, error.Message);
        }
    }

    // MARK: Files

    /// <summary>
    /// A second connection presented this session's token: run file transfers on it, if the
    /// session is live, the client said it takes files, and no channel is attached yet.
    /// </summary>
    internal async Task<FileTransferEngine?> AttachFileChannelAsync(FramedConnection channel)
    {
        // Files-only sessions skip whois at the handshake; the device's name is worth it here.
        await LookUpPeerAsync(CancellationToken.None).ConfigureAwait(false);
        FileTransferEngine? engine = null;
        await _queue.RunAsync(() =>
        {
            if (State is not (SessionState.Streaming or SessionState.FilesOnly) || !_clientTakesFiles || _fileEngine is not null) return Task.CompletedTask;
            engine = new FileTransferEngine(channel, FileTransferRole.Host, new FileTransferConfiguration
            {
                ReceiveDirectory = _env.Files.ReceiveDirectory,
                Store = _env.Files,
                PartialDirectory = _listener.ResumeFolderFor,
                Sender = new FileSender(ClientName, Fingerprint),
            }, _env.Logging.CreateLogger("Vantage.Files"));
            _fileEngine = engine;
            return Task.CompletedTask;
        }).ConfigureAwait(false);
        if (engine is null)
        {
            _log.LogError("refusing a file channel (session {State}, files {Files})", State, _clientTakesFiles);
            channel.Close();
        }
        return engine;
    }

    // MARK: Audio

    /// <summary>
    /// Starts the PC's sound (Mac <c>HostSession.startAudio</c>): <c>audioConfig</c> first, then
    /// capture feeding the encoder, whose packets go straight onto the control lane from its own
    /// loop (never through this queue, so input and video never wait on sound, nor sound on them).
    /// Any failure answers <c>audioConfig.unavailable</c> instead.
    /// </summary>
    private async Task StartAudioAsync()
    {
        if (_audioCapture is not null || State != SessionState.Streaming) return;
        if (_env.Audio is not { } source)
        {
            _connection.Post(AudioConfig.UnavailableBecause($"This {HostNoun} can't capture its sound."));
            return;
        }
        var began = _env.Time.GetTimestamp();
        var connection = _connection;
        var encoder = new AudioStreamEncoder(packet =>
        {
            if (!connection.PostAudio(packet)) Interlocked.Increment(ref _audioDropped);
        }, _env.Logging.CreateLogger("Vantage.Audio"));
        IAudioCapture capture;
        try
        {
            // Queued before capture starts: the control lane is in order, so it precedes every packet.
            _connection.Post(encoder.Config);
            capture = await source.StartAsync(block => encoder.Enqueue(block),
                                              reason => _queue.Post(() => AudioStoppedAsync(encoder, reason)),
                                              _ended.Token).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            await encoder.DisposeAsync().ConfigureAwait(false);
            if (error is OperationCanceledException) return; // the session ended meanwhile
            if (error is not AudioUnavailableException) throw;
            _log.LogError("audio didn't start: {Reason}", error.Message);
            _connection.Post(AudioConfig.UnavailableBecause(error.Message));
            return;
        }
        _audioCapture = capture;
        _audioEncoder = encoder;
        _audioDropped = 0;
        _log.LogInformation("audio started ({Source}) in {Ms:0} ms", capture.Description, _env.Time.GetElapsedTime(began).TotalMilliseconds);
    }

    private async Task StopAudioAsync()
    {
        if (_audioCapture is not { } capture || _audioEncoder is not { } encoder) return;
        _audioCapture = null;
        _audioEncoder = null;
        await capture.DisposeAsync().ConfigureAwait(false);
        await encoder.DisposeAsync().ConfigureAwait(false);
        var dropped = Interlocked.Read(ref _audioDropped);
        _log.LogInformation("audio stopped after {Packets} packets{Dropped}", encoder.PacketsSent,
                            dropped > 0 ? $" ({dropped} dropped behind a stalled connection)" : "");
    }

    /// <summary>Capture stopped on its own and couldn't restart: tell the client why.</summary>
    private async Task AudioStoppedAsync(AudioStreamEncoder encoder, string reason)
    {
        if (!ReferenceEquals(encoder, _audioEncoder)) return;
        _log.LogError("audio stopped: {Reason}", reason);
        await StopAudioAsync().ConfigureAwait(false);
        if (State == SessionState.Streaming) _connection.Post(AudioConfig.UnavailableBecause(reason));
    }

    // MARK: Teardown

    private async Task TeardownAsync()
    {
        await _queue.RunAsync(async () =>
        {
            if (State == SessionState.Closed) return;
            var wasStreaming = State == SessionState.Streaming;
            State = SessionState.Closed;
            _listener.AttachTokens.Revoke(this);
            StopTicker();
            if (wasStreaming)
            {
                _env.Curtain?.SessionEnded(Id);
                await StopAudioAsync().ConfigureAwait(false);
                await StopCaptureAsync().ConfigureAwait(false);
                try
                {
                    if (_env.DisplayFitter?.Restore(Id) == true) _log.LogInformation("display mode restored at session end");
                }
                catch (Exception error)
                {
                    _log.LogError("restoring the display mode failed: {Error}", error.Message);
                }
                if (_input is not null)
                {
                    try
                    {
                        // Dispose even if releasing failed: it stops a glide's timer for good.
                        try
                        {
                            _input.ReleaseAll();
                        }
                        finally
                        {
                            _input.Dispose();
                        }
                    }
                    catch (Exception error)
                    {
                        _log.LogError("releasing input failed: {Error}", error.Message);
                    }
                    _input = null;
                }
                _clipboardWatch?.Dispose();
                _cursorWatch?.Dispose();
                _statusWatch?.Dispose();
                _keepAwake?.Dispose();
            }
        }).ConfigureAwait(false);
        await _ended.CancelAsync().ConfigureAwait(false);
        State = SessionState.Closed;
        _connection.Close();
        _queue.Complete();
        _listener.SessionEnded(this);
    }

    /// <summary>Forwards encoder output onto the session queue, tagged with the encoder it came from.</summary>
    private sealed class EncoderSink(HostSessionCore session, IVideoEncoder encoder) : IEncodedFrameSink
    {
        public void OnFrame(EncodedFrame frame) => session._queue.Post(() => session.EmitAsync(encoder, frame));

        public void OnFrameSkipped() => session._queue.Post(() => session.EmitAsync(encoder, null));

        public void OnError(Exception error) => session._queue.Post(async () =>
        {
            if (!ReferenceEquals(encoder, session._encoder) || session._capture is not { } capture) return;
            session._log.LogError("encoder failed: {Error}", error.Message);
            await session.CaptureStoppedAsync(capture, "encoder failed: " + error.Message).ConfigureAwait(false);
        });
    }
}
