using System.Net;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Adaptive;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Files;
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
/// display-sleep rule), clipboard, host commands, adaptive bitrate, and pings. Teardown revokes its
/// attach token and releases all input; an attached file channel carries on.
/// </summary>
/// <remarks>
/// State changes run one at a time on the session's own queue (like the Mac's actor). The platform
/// never talks to a session directly; it sees <see cref="SessionSnapshot"/>s through the listener.
/// </remarks>
public sealed class HostSessionCore
{
    private static readonly TimeSpan s_captureNoFrameLimit = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan s_unavailableNotice = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan s_maxRecoveryDelay = TimeSpan.FromSeconds(5);

    private readonly HostListener _listener;
    private readonly HostEnvironment _env;
    private readonly FramedConnection _connection;
    private readonly ILogger _log;
    private readonly SerialQueue _queue;
    private readonly CancellationTokenSource _ended = new();
    private Hello? _hello;
    private bool _clientTakesFiles;
    private FileTransferEngine? _fileEngine;

    // Streaming state (queue only).
    private SelectDisplay? _wanted;
    private bool _streamStarting;
    private SelectDisplay? _pendingStart;
    private ICaptureStream? _capture;
    private IVideoEncoder? _encoder;
    private EncoderSink? _encoderSink;
    private ICapturedFrame? _latest;
    private bool _pendingEncode;
    private int _encodesInFlight;
    private bool _needsKeyframe = true;
    private bool _configSentForEncoder;
    private byte[][]? _lastParameterSets;
    private ulong _sequence;
    private ulong _framesSent;
    private AdaptiveController _adaptive = new(20_000);
    private int _currentFps = 60;
    private int _currentMaxQP = 44;
    private DateTimeOffset? _captureStartedAt;
    private bool _captureHasFramed;
    private DateTimeOffset? _captureLostAt;
    private string _captureLossReason = "";
    private DateTimeOffset _nextRecoveryAttempt;
    private TimeSpan _recoveryDelay = TimeSpan.FromMilliseconds(500);
    private CancellationTokenSource? _recovery;
    private bool _screenUnavailable;
    private DateTimeOffset? _captureFailsUntil;
    private bool _monitoring;
    private bool _displayAsleep;
    private DateTimeOffset? _sleptAt;
    private DateTimeOffset _lastWakeForInput = DateTimeOffset.MinValue;
    private IInputSink? _input;
    private IDisposable? _clipboardWatch;
    private IDisposable? _statusWatch;
    private IDisposable? _keepAwake;
    private HostStatus? _lastStatus;

    internal HostSessionCore(HostListener listener, FramedConnection connection)
    {
        _listener = listener;
        _env = listener.Environment;
        _connection = connection;
        Peer = connection.PeerAddress;
        _log = _env.Logging.CreateLogger("Vantage.Session");
        _queue = new SerialQueue(_log);
        _connection.VideoDrained += () => _queue.Post(OnVideoDrained);
    }

    /// <summary>Stable id for this connection.</summary>
    public Guid Id { get; } = Guid.NewGuid();

    /// <summary>The peer's address (IPv4-mapped addresses mapped to IPv4).</summary>
    public IPAddress Peer { get; }

    /// <summary>Where the session is.</summary>
    public SessionState State { get; private set; } = SessionState.Handshaking;

    /// <summary><c>Hello.clientName</c> once known.</summary>
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
        string? tailnetName = null;
        if (!lightweight && _env.Peers is { } peers)
        {
            try
            {
                using var whoisLimit = CancellationTokenSource.CreateLinkedTokenSource(deadline);
                whoisLimit.CancelAfter(TimeSpan.FromSeconds(2));
                tailnetName = (await peers.WhoisAsync(Peer, whoisLimit.Token).ConfigureAwait(false))?.TailnetName;
            }
            catch (Exception error) when (error is not OperationCanceledException || !deadline.IsCancellationRequested)
            {
                _log.LogDebug("whois failed: {Error}", error.Message);
            }
        }
        await _connection.SendAsync(new Challenge
        {
            HostName = _env.HostName,
            HostVersion = VantageProtocol.HostVersion,
            HostPublicKey = identity.PublicKey,
            Nonce = nonce,
            IsPaired = isPaired,
            PeerTailnetName = tailnetName,
            HostPlatform = _env.Platform,
        }).ConfigureAwait(false);

        if (await _connection.ReceiveAsync(deadline).ConfigureAwait(false) is not Authenticate auth)
        {
            _log.LogInformation("handshake ended before authenticate");
            return false;
        }
        if (!AuthTranscript.Verify(_env.Ed25519, auth.Signature, nonce, identity.PublicKey, hello.ClientPublicKey))
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
            _env.Trust.Trust(Fingerprint, hello.ClientName);
            _listener.RaisePaired(Fingerprint, hello.ClientName);
        }

        if (hello.IsReadinessProbe == true)
        {
            // Never enumerate displays, start capture, or touch the clipboard for a probe.
            await _connection.SendAsync(new AuthResult
            {
                Status = AuthStatus.Ok,
                Readiness = new HostReadiness { ScreenRecordingGranted = true, AccessibilityGranted = true },
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
                CanManageVirtualDisplay = false,
                Clipboard = true,
                MaxFPS = 60,
                FileTransfer = _clientTakesFiles ? true : null,
                FilesOnlySessions = _clientTakesFiles ? true : null,
                Platform = _env.Platform,
            },
        }).ConfigureAwait(false);
        _log.LogInformation("client authenticated: {Client}", hello.ClientName);
        return true;
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
                if (AdmitsInput(pointer.Action == PointerAction.Up)) _input?.Pointer(pointer);
                break;
            case ScrollEvent scroll:
                if (AdmitsInput(false)) _input?.Scroll(scroll);
                break;
            case KeyEvent key:
                if (AdmitsInput(!key.IsDown)) _input?.Key(key);
                break;
            case TextInput text:
                if (AdmitsInput(false)) _input?.Text(text.Text);
                break;
            case ClipboardPayload clipboard:
                if (!clipboard.IsEmpty) _env.Clipboard.Apply(clipboard);
                break;
            case QualityFeedback feedback:
                if (_adaptive.Apply(feedback) is { } bitrate) _encoder?.SetBitrate(bitrate);
                break;
            case RequestKeyframe:
            case ViewportChanged:
                await RequestKeyframeAsync().ConfigureAwait(false);
                break;
            case HostCommandMessage command:
                await HandleCommandAsync(command.Command).ConfigureAwait(false);
                break;
            default:
                break; // audioRequest, dictation, modifierState, …: never advertised, ignored
        }
    }

    // MARK: Streaming

    private async Task SelectDisplayAsync(SelectDisplay select)
    {
        _wanted = select;
        if (_captureFailsUntil is null && _listener.Options.CaptureFailsFor is { } fails)
        {
            _captureFailsUntil = _env.Time.GetUtcNow() + fails;
            _log.LogInformation("--capture-fails-for: capture fails for {Seconds} s", fails.TotalSeconds);
        }
        StartMonitoring();
        if (_env.Status.Current.IsDisplayAsleep) await WakeDisplayForStreamingAsync().ConfigureAwait(false);
        if (await StartStreamAsync(select).ConfigureAwait(false) == false) CaptureUnavailable();
    }

    /// <summary>Starts or restarts the stream, one at a time. Null: another start was running and takes this request over.</summary>
    private async Task<bool?> StartStreamAsync(SelectDisplay select)
    {
        if (_streamStarting)
        {
            _pendingStart = select;
            return null;
        }
        _streamStarting = true;
        try
        {
            var next = select;
            var started = false;
            while (next is not null)
            {
                _pendingStart = null;
                try
                {
                    await StartStreamingAsync(next).ConfigureAwait(false);
                    started = true;
                }
                catch (Exception error) when (error is not IOException)
                {
                    started = false;
                    _captureLossReason = error.Message;
                    _log.LogError("capture didn't start: {Reason}{Asleep}", _captureLossReason, _env.Status.Current.IsDisplayAsleep ? " (display asleep)" : "");
                }
                next = _pendingStart;
            }
            return started;
        }
        finally
        {
            _streamStarting = false;
        }
    }

    /// <summary>Sets up capture and encoding. Throws when there's nothing to capture; callers keep the session.</summary>
    private async Task StartStreamingAsync(SelectDisplay select)
    {
        var began = _env.Time.GetTimestamp();
        await StopCaptureAsync().ConfigureAwait(false);
        if (_captureFailsUntil is { } until && _env.Time.GetUtcNow() < until) throw new CaptureUnavailableException("capture fails on purpose (--capture-fails-for)");
        var displays = await _env.Screen.GetDisplaysAsync(CancellationToken.None).ConfigureAwait(false);
        var chosen = select.Selection switch
        {
            DisplaySelection.Display byId => displays.FirstOrDefault(d => d.Id == byId.Id)
                                             ?? throw new CaptureUnavailableException($"display {byId.Id} isn't connected"),
            _ => displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault()
                 ?? throw new CaptureUnavailableException("no displays to capture"),
        };
        var fps = Math.Clamp(select.TargetFPS, 1, 60);
        var hello = _hello!;
        var capture = await _env.Screen.StartAsync(new CaptureRequest(chosen, fps), OnCapturedFrame, OnCaptureStopped, CancellationToken.None).ConfigureAwait(false);
        var (width, height) = VideoGeometry.EncodedSize(capture.FrameWidth, capture.FrameHeight, hello.MaxDecodeWidth, hello.MaxDecodeHeight);
        _adaptive = new AdaptiveController(AdaptiveController.StartBitrate(width * height, fps), _env.Time);
        _currentFps = fps;
        _currentMaxQP = _adaptive.MaxQP;
        IVideoEncoder encoder;
        try
        {
            encoder = _env.Encoders.Create(capture, new VideoEncoderSettings(VideoCodec.H264, width, height, fps, _adaptive.BitrateKbps, _adaptive.MaxQP));
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
        _configSentForEncoder = false;
        _lastParameterSets = null;
        _captureStartedAt = _env.Time.GetUtcNow();
        _captureHasFramed = false;
        Display = chosen;

        // The input sink (and whatever it holds) survives capture restarts.
        _input ??= _env.CreateInputSink();
        _input.SetDisplay(chosen);

        if (_clipboardWatch is null)
        {
            _clipboardWatch = _env.Clipboard.Watch(payload => _queue.Post(() =>
            {
                if (State == SessionState.Streaming && !payload.IsEmpty) _connection.PostBulk(payload);
            }));
        }
        if (_env.Clipboard.Read() is { IsEmpty: false } initial) _connection.PostBulk(initial);

        await _connection.SendAsync(new StreamConfig { Display = chosen, Codec = VideoCodec.H264, Fps = fps, BitrateKbps = _adaptive.BitrateKbps }).ConfigureAwait(false);
        _needsKeyframe = true;
        StartWatchdog(); // a capture that never sends a frame counts as failed after 5 s
        _listener.SessionChanged();
        _log.LogInformation("streaming display {Id} at {Width}x{Height} (encoded {EncodedWidth}x{EncodedHeight}); stream setup took {Ms} ms",
                            chosen.Id, chosen.PixelWidth, chosen.PixelHeight, width, height, (int)_env.Time.GetElapsedTime(began).TotalMilliseconds);
    }

    private void OnCapturedFrame(ICapturedFrame frame)
    {
        if (!_queue.Post(() => Ingest(frame))) frame.Dispose();
    }

    private void OnCaptureStopped(string reason)
    {
        _queue.Post(async () =>
        {
            // Only the capture that is current: a stop from a replaced one is old news.
            if (_capture is not null) await CaptureStoppedAsync(_capture, reason).ConfigureAwait(false);
        });
    }

    private async Task Ingest(ICapturedFrame frame)
    {
        if (_capture is null || _encoder is null || State != SessionState.Streaming)
        {
            frame.Dispose();
            return;
        }
        _captureHasFramed = true;
        if (_captureLostAt is not null) CaptureRecovered();
        var fps = Math.Min(_adaptive.Observe(frame.DirtyRatio), _wanted?.TargetFPS ?? 60);
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
        if (frame.DirtyRatio <= 0.0001 && !_needsKeyframe && _framesSent > 0) return;
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
            unit = output.Format == NalFormat.AnnexB ? AnnexB.ToAccessUnit(output.Data) : AnnexB.FromUnits(AnnexB.SplitAvcc(output.Data));
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
            var sps = unit.Sps ?? output.ParameterSets?.FirstOrDefault(p => NalType.Of(p) == NalType.Sps);
            var pps = unit.Pps ?? output.ParameterSets?.FirstOrDefault(p => NalType.Of(p) == NalType.Pps);
            if (sps is not null && pps is not null)
            {
                byte[][] sets = [sps, pps];
                if (!_configSentForEncoder || _lastParameterSets is null || !SameSets(sets, _lastParameterSets))
                {
                    _connection.PostVideo(new VideoConfig
                    {
                        Codec = VideoCodec.H264,
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

    private static bool SameSets(byte[][] a, byte[][] b) =>
        a.Length == b.Length && a.Zip(b).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second));

    // MARK: Commands, status, display sleep

    private async Task HandleCommandAsync(HostCommand command)
    {
        switch (command)
        {
            case HostCommand.SleepDisplay:
                _sleptAt = _env.Time.GetUtcNow();
                _env.Power.SleepDisplay();
                break;
            case HostCommand.WakeDisplay:
                _sleptAt = null;
                _env.Power.WakeDisplay();
                await RetryCaptureNowAsync().ConfigureAwait(false); // Wake doubles as Retry
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
                break; // no virtual displays on Windows
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
            IsScreenUnavailable = _screenUnavailable && !conditions.IsDisplayAsleep,
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
        _displayAsleep = _env.Status.Current.IsDisplayAsleep;
        SendStatus(force: true);
    }

    private async Task HostStatusChangedAsync()
    {
        if (State != SessionState.Streaming) return;
        SendStatus();
        var asleep = _env.Status.Current.IsDisplayAsleep;
        if (asleep == _displayAsleep)
        {
            // Capture waiting on something else (a lock screen): try again now that things changed.
            if (!asleep && _capture is null && _wanted is not null && !_streamStarting) await RestartStreamAsync("host state changed").ConfigureAwait(false);
            return;
        }
        _displayAsleep = asleep;
        if (asleep)
        {
            _log.LogInformation("display went to sleep; the session stays up");
            _captureLostAt = null; // the asleep state explains the missing picture
            _screenUnavailable = false;
            SendStatus();
        }
        else
        {
            _log.LogInformation("display woke");
            _sleptAt = null;
            _needsKeyframe = true;
            if (_capture is null) await RestartStreamAsync("display woke").ConfigureAwait(false);
            else await RequestKeyframeAsync().ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Input while the display is asleep wakes it (at most once a second) instead of reaching a
    /// screen nobody sees; releases still go through. Input in the 2 s after Sleep Display doesn't count.
    /// </summary>
    private bool AdmitsInput(bool isRelease)
    {
        if (!_displayAsleep || isRelease) return true;
        var now = _env.Time.GetUtcNow();
        if (_sleptAt is { } slept && now - slept < TimeSpan.FromSeconds(2)) return false;
        if (now - _lastWakeForInput >= TimeSpan.FromSeconds(1))
        {
            _lastWakeForInput = now;
            _env.Power.WakeDisplay();
        }
        return false;
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

    /// <summary>
    /// Capture is down while the client waits: retry with backoff (0.5 s doubling to 5 s) for as
    /// long as the session lasts, and tell the client after 3 s (<c>isScreenUnavailable</c>).
    /// </summary>
    private void CaptureUnavailable()
    {
        if (State != SessionState.Streaming || _wanted is null || _capture is not null) return;
        SendStatus();
        if (_env.Status.Current.IsDisplayAsleep) return;
        if (_captureLostAt is null)
        {
            _captureLostAt = _env.Time.GetUtcNow();
            _recoveryDelay = TimeSpan.FromMilliseconds(500);
            _nextRecoveryAttempt = _captureLostAt.Value + _recoveryDelay;
        }
        StartWatchdog();
    }

    private void StartWatchdog()
    {
        if (_recovery is not null) return;
        var stop = CancellationTokenSource.CreateLinkedTokenSource(_ended.Token);
        _recovery = stop;
        _ = Task.Run(async () =>
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(250), _env.Time, stop.Token).ConfigureAwait(false);
                    var keepGoing = true;
                    await _queue.RunAsync(async () => keepGoing = await RecoveryTickAsync(stop).ConfigureAwait(false)).ConfigureAwait(false);
                    if (!keepGoing) return;
                }
            }
            catch (OperationCanceledException)
            {
                // Session over or capture back.
            }
        });
    }

    /// <summary>One watchdog tick; false once there's nothing left to recover.</summary>
    private async Task<bool> RecoveryTickAsync(CancellationTokenSource owner)
    {
        if (!ReferenceEquals(_recovery, owner)) return false;
        if (State != SessionState.Streaming || _wanted is null || _env.Status.Current.IsDisplayAsleep)
        {
            _recovery = null;
            return false;
        }
        var now = _env.Time.GetUtcNow();
        // A capture that started but never sent a frame counts as failed after 5 s.
        if (_capture is { } capture && !_captureHasFramed && _captureStartedAt is { } startedAt && now - startedAt > s_captureNoFrameLimit)
        {
            _captureLossReason = "capture started but sent no frames";
            await CaptureStoppedAsync(capture, _captureLossReason).ConfigureAwait(false);
            _captureLostAt ??= startedAt;
        }
        if (_captureLostAt is not { } lostAt)
        {
            if (_capture is not null && _captureHasFramed)
            {
                _recovery = null;
                return false;
            }
            return true;
        }
        var seconds = (int)(now - lostAt).TotalSeconds;
        if (now - lostAt >= s_unavailableNotice && !_screenUnavailable)
        {
            _screenUnavailable = true;
            _log.LogError("capture unavailable for {Seconds} s: {Reason}; telling the client", seconds, _captureLossReason);
            SendStatus();
        }
        if (_capture is not null || _streamStarting || now < _nextRecoveryAttempt) return true;
        _log.LogError("capture unavailable for {Seconds} s: {Reason}; trying again", seconds, _captureLossReason);
        await RestartStreamAsync($"capture unavailable for {seconds} s").ConfigureAwait(false);
        _recoveryDelay = TimeSpan.FromTicks(Math.Min(_recoveryDelay.Ticks * 2, s_maxRecoveryDelay.Ticks));
        _nextRecoveryAttempt = _env.Time.GetUtcNow() + _recoveryDelay;
        return true;
    }

    private void CaptureRecovered()
    {
        if (_captureLostAt is not { } lostAt) return;
        _captureLostAt = null;
        _recovery?.Cancel();
        _recovery = null;
        _log.LogInformation("capture back after {Ms} ms", (int)(_env.Time.GetUtcNow() - lostAt).TotalMilliseconds);
        if (_screenUnavailable)
        {
            _screenUnavailable = false;
            SendStatus();
        }
    }

    private async Task RetryCaptureNowAsync()
    {
        if (_captureLostAt is null || _capture is not null) return;
        _recoveryDelay = TimeSpan.FromMilliseconds(500);
        _nextRecoveryAttempt = _env.Time.GetUtcNow() + _recoveryDelay;
        _log.LogInformation("capture retry asked for by the client");
        if (!_streamStarting) await RestartStreamAsync("client asked to retry").ConfigureAwait(false);
    }

    /// <summary>Capture stopped by itself: the session, input, and power carry on; only capture waits.</summary>
    private async Task CaptureStoppedAsync(ICaptureStream capture, string reason)
    {
        if (!ReferenceEquals(capture, _capture)) return;
        _log.LogInformation("capture stopped ({Reason}); display {State}", reason, _env.Status.Current.IsDisplayAsleep ? "asleep" : "awake");
        _captureLossReason = reason;
        await StopCaptureAsync().ConfigureAwait(false);
        _needsKeyframe = true;
        CaptureUnavailable();
    }

    /// <summary>Brings capture back on the display it was on, else the client's original choice; failing both, retries later.</summary>
    private async Task RestartStreamAsync(string reason)
    {
        if (State != SessionState.Streaming || _wanted is not { } wanted || _streamStarting) return;
        _log.LogInformation("restarting capture: {Reason}", reason);
        _needsKeyframe = true;
        var targets = new List<SelectDisplay>();
        if (Display is { } display)
            targets.Add(new SelectDisplay { Selection = new DisplaySelection.Display(display.Id), TargetFPS = wanted.TargetFPS, Quality = wanted.Quality });
        targets.Add(wanted);
        foreach (var target in targets)
        {
            switch (await StartStreamAsync(target).ConfigureAwait(false))
            {
                case true:
                case null:
                    return;
            }
        }
        if (_captureLostAt is null) CaptureUnavailable();
    }

    /// <summary>Stops capture and encoding only; input, power, and status stay.</summary>
    private async Task StopCaptureAsync()
    {
        var capture = _capture;
        var encoder = _encoder;
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
        FileTransferEngine? engine = null;
        await _queue.RunAsync(() =>
        {
            if (State is not (SessionState.Streaming or SessionState.FilesOnly) || !_clientTakesFiles || _fileEngine is not null) return Task.CompletedTask;
            engine = new FileTransferEngine(channel, FileTransferRole.Host, new FileTransferConfiguration
            {
                ReceiveDirectory = _env.Files.ReceiveDirectory,
                Store = _env.Files,
                PartialDirectory = _listener.ResumeFolderFor,
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

    // MARK: Teardown

    private async Task TeardownAsync()
    {
        await _queue.RunAsync(async () =>
        {
            if (State == SessionState.Closed) return;
            var wasStreaming = State == SessionState.Streaming;
            State = SessionState.Closed;
            _listener.AttachTokens.Revoke(this);
            _recovery?.Cancel();
            _recovery = null;
            if (wasStreaming)
            {
                await StopCaptureAsync().ConfigureAwait(false);
                if (_input is not null)
                {
                    try
                    {
                        _input.ReleaseAll();
                        _input.Dispose();
                    }
                    catch (Exception error)
                    {
                        _log.LogError("releasing input failed: {Error}", error.Message);
                    }
                    _input = null;
                }
                _clipboardWatch?.Dispose();
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
