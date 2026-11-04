using System.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Files;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;
using Vantage.SyntheticHost;

namespace Vantage.Protocol.Tests;

/// <summary>A listener on a random loopback port with the synthetic host's parts.</summary>
internal sealed class TestHost : IAsyncDisposable
{
    public readonly string Root = Directory.CreateTempSubdirectory("vantage-host-").FullName;
    public readonly RecordingInput Input = new();
    public readonly FakeDisplay Display;
    public readonly HostListener Listener;
    public readonly MemoryClipboard Clipboard;

    public readonly RecordingFileStore Files;

    public TestHost(string? pairingCode = "246810", bool displayAsleep = false, string? clipboardText = null, TimeSpan? captureFailsFor = null,
                    IPeerDirectory? peers = null, TimeSpan? pasteRestoreDelay = null)
    {
        Files = new RecordingFileStore(Directory.CreateDirectory(Path.Combine(Root, "received")).FullName);
        Display = new FakeDisplay(displayAsleep, displayAsleep, NullLogger.Instance);
        Clipboard = new MemoryClipboard(clipboardText, new EventLog(null, false, NullLogger.Instance));
        var storage = new FileProtectedStorage(Path.Combine(Root, "state"));
        var environment = new HostEnvironment
        {
            HostName = "Test PC",
            Screen = new ClipScreenSource(Display, NullLogger.Instance),
            Encoders = new ClipEncoderFactory(new Clip(VideoTests.ClipPath())),
            CreateInputSink = () => Input,
            Clipboard = Clipboard,
            Status = Display,
            Power = Display,
            Files = Files,
            Peers = peers,
            Identity = new ProtectedIdentityStore(storage, new NSecEd25519()),
            Trust = new ProtectedTrustStore(storage, TimeProvider.System),
            Logging = NullLoggerFactory.Instance,
        };
        Listener = new HostListener(environment, new HostListenerOptions
        {
            Port = 0,
            AllowLoopback = true,
            FixedPairingCode = pairingCode,
            CaptureFailsFor = captureFailsFor,
            PasteRestoreDelay = pasteRestoreDelay ?? ClipboardPaster.DefaultRestoreDelay,
        });
        Listener.StartAsync().GetAwaiter().GetResult();
    }

    public int Port => Listener.LocalEndPoint!.Port;

    public async ValueTask DisposeAsync()
    {
        await Listener.StopAsync();
        Directory.Delete(Root, recursive: true);
    }
}

/// <summary>The synthetic store, remembering who each saved file came from.</summary>
internal sealed class RecordingFileStore(string directory) : IFileStore
{
    private readonly SyntheticFileStore _inner = new(directory, NullLogger.Instance);
    public readonly List<(string Path, FileSender? Sender)> Saved = [];
    public string ReceiveDirectory => _inner.ReceiveDirectory;
    public bool IsCaseInsensitive => _inner.IsCaseInsensitive;
    public long? GetAvailableFreeSpace(string directory) => _inner.GetAvailableFreeSpace(directory);
    public void OnPartialCreated(string partialPath) => _inner.OnPartialCreated(partialPath);
    public void OnBeforeFinalize(string partialPath) => _inner.OnBeforeFinalize(partialPath);
    public void OnSaved(string path, FileOffer offer)
    {
        lock (Saved) Saved.Add((path, null));
    }

    public void OnSaved(string path, FileOffer offer, FileSender sender)
    {
        lock (Saved) Saved.Add((path, sender));
    }
}

internal sealed class FixedPeers(PeerIdentity identity) : IPeerDirectory
{
    public Task<PeerIdentity?> WhoisAsync(System.Net.IPAddress peer, CancellationToken cancellationToken) => Task.FromResult<PeerIdentity?>(identity);
}

internal sealed class RecordingInput : IInputSink
{
    public readonly List<IMessage> Events = [];
    public readonly List<string> Texts = [];
    public int Releases;

    public void SetDisplay(DisplayInfo display)
    {
    }

    public void Pointer(PointerEvent pointerEvent)
    {
        lock (Events) Events.Add(pointerEvent);
    }

    public void Scroll(ScrollEvent scrollEvent)
    {
        lock (Events) Events.Add(scrollEvent);
    }

    public void Key(KeyEvent keyEvent)
    {
        lock (Events) Events.Add(keyEvent);
    }

    public void Text(string text)
    {
        lock (Events) Texts.Add(text);
    }

    public void ReleaseAll() => Interlocked.Increment(ref Releases);

    public void Dispose()
    {
    }
}

/// <summary>A client that speaks the handshake the way <c>ClientSession</c> does.</summary>
internal sealed class TestClient
{
    private static readonly NSecEd25519 s_ed25519 = new();
    public readonly byte[] Seed = s_ed25519.GenerateSeed();
    public byte[] PublicKey => s_ed25519.PublicKeyFromSeed(Seed);

    public async Task<(FramedConnection Connection, Challenge Challenge, AuthResult Result)> ConnectAsync(
        int port, string? code = null, bool probe = false, bool filesOnly = false, bool files = true, ushort version = 2, string host = "127.0.0.1")
    {
        var connection = await FramedConnection.ConnectAsync(host, port);
        await connection.SendAsync(new Hello
        {
            ProtocolVersion = version,
            ClientName = "Test iPad",
            DeviceModel = "iPad16,1",
            AppVersion = "1.0",
            ClientPublicKey = PublicKey,
            SupportedCodecs = probe || filesOnly ? [] : [VideoCodec.Hevc, VideoCodec.H264],
            MaxDecodeWidth = probe || filesOnly ? 0 : 4096,
            MaxDecodeHeight = probe || filesOnly ? 0 : 2304,
            Viewport = probe || filesOnly ? null : new Viewport { WidthPoints = 1210, HeightPoints = 834, Scale = 2 },
            IsReadinessProbe = probe ? true : null,
            Features = new ClientFeatures { FileTransfer = files, FilesOnly = filesOnly ? true : null },
        });
        var first = await connection.ReceiveAsync();
        if (first is AuthResult early) return (connection, null!, early);
        var challenge = Assert.IsType<Challenge>(first);
        var signature = s_ed25519.Sign(Seed, AuthTranscript.Bytes(challenge.Nonce, challenge.HostPublicKey, PublicKey));
        await connection.SendAsync(new Authenticate { Signature = signature, PairingCode = challenge.IsPaired ? null : code });
        var result = await Loopback.Next<AuthResult>(connection);
        return (connection, challenge, result);
    }
}

public class HostListenerTests
{
    [Fact]
    public async Task PairingRequiredThenPairedThenRemembered()
    {
        await using var host = new TestHost();
        var client = new TestClient();

        var (_, challenge, result) = await client.ConnectAsync(host.Port);
        Assert.False(challenge.IsPaired);
        Assert.Equal(HostPlatforms.Windows, challenge.HostPlatform);
        Assert.Equal("Test PC", challenge.HostName);
        Assert.Equal(32, challenge.Nonce.Length);
        Assert.Equal(AuthStatus.PairingRequired, result.Status);
        Assert.Equal("Enter the pairing code shown on the PC", result.Message);

        var watch = Stopwatch.StartNew();
        (_, _, result) = await client.ConnectAsync(host.Port, "000000");
        Assert.Equal(AuthStatus.BadPairingCode, result.Status);
        Assert.True(watch.Elapsed >= TimeSpan.FromSeconds(0.95), "a miss costs a second");

        (var connection, _, result) = await client.ConnectAsync(host.Port, "246810");
        Assert.Equal(AuthStatus.Ok, result.Status);
        Assert.Equal(32, result.SessionToken?.Length);
        Assert.Equal([VideoCodec.H264], result.Capabilities!.Codecs);
        Assert.Equal(HostPlatforms.Windows, result.Capabilities.Platform);
        Assert.True(result.Capabilities.FileTransfer);
        Assert.True(result.Capabilities.FilesOnlySessions);
        Assert.Null(result.Capabilities.Audio);
        Assert.Null(result.Capabilities.DictationEngines);
        Assert.Equal("Vantage Synthetic Display", Assert.Single(result.Displays!).Name);
        connection.Close();

        (connection, challenge, result) = await client.ConnectAsync(host.Port);
        Assert.True(challenge.IsPaired);
        Assert.Equal(AuthStatus.Ok, result.Status);
        connection.Close();
    }

    [Fact]
    public async Task FiveMissesBurnTheCode()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        var misses = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => client.ConnectAsync(host.Port, "111111")));
        Assert.All(misses, miss => Assert.Equal(AuthStatus.BadPairingCode, miss.Result.Status));
        var (_, _, result) = await client.ConnectAsync(host.Port, "246810");
        Assert.Equal(AuthStatus.BadPairingCode, result.Status);
        Assert.Contains("expired", result.Message);
    }

    [Fact]
    public async Task ProbesVersionMismatchesAndFilesOnlySessions()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        (await client.ConnectAsync(host.Port, "246810")).Connection.Close();

        var (connection, _, probe) = await client.ConnectAsync(host.Port, probe: true);
        Assert.Equal(AuthStatus.Ok, probe.Status);
        Assert.True(probe.Readiness!.ScreenRecordingGranted);
        Assert.Null(probe.Displays);
        Assert.Null(await connection.ReceiveAsync()); // closed

        var (_, _, mismatch) = await client.ConnectAsync(host.Port, version: 1);
        Assert.Equal(AuthStatus.VersionMismatch, mismatch.Status);
        Assert.Equal("Protocol 2 required", mismatch.Message);

        var (files, challenge, filesOnly) = await client.ConnectAsync(host.Port, filesOnly: true);
        Assert.Null(challenge.PeerTailnetName);
        Assert.Equal(AuthStatus.Ok, filesOnly.Status);
        Assert.Null(filesOnly.Displays);
        Assert.Equal([], filesOnly.Capabilities!.Codecs);
        Assert.Equal(0, filesOnly.Capabilities.MaxFPS);
        Assert.False(filesOnly.Capabilities.Clipboard);
        Assert.True(filesOnly.Capabilities.FilesOnlySessions);
        await files.SendAsync(new SelectDisplay { Selection = new DisplaySelection.Display(1), TargetFPS = 60, Quality = QualityPreset.Auto });
        await files.SendAsync(new Ping { SentAtNanos = 42 });
        Assert.Equal(42ul, Assert.IsType<Pong>(await files.ReceiveAsync()).EchoNanos); // and nothing before it

        var (_, _, denied) = await client.ConnectAsync(host.Port, filesOnly: true, files: false);
        Assert.Equal(AuthStatus.Denied, denied.Status);
    }

    [Fact]
    public async Task StreamStartsWithStatusConfigThenAnIdrAndAnswersKeyframeRequestsAtOnce()
    {
        await using var host = new TestHost(clipboardText: "from the PC");
        var client = new TestClient();
        var (connection, _, _) = await client.ConnectAsync(host.Port, "246810");
        await connection.SendAsync(new SelectDisplay
        {
            Selection = new DisplaySelection.FitViewport(new Viewport { WidthPoints = 1210, HeightPoints = 834, Scale = 2 }),
            TargetFPS = 60, Quality = QualityPreset.Auto, PreferredCodec = VideoCodec.Hevc, UseVirtualDisplay = false,
        });
        var order = new List<MessageKind>();
        VideoFrame? first = null;
        ClipboardPayload? clipboard = null;
        StreamConfig? config = null;
        while (first is null && await connection.ReceiveAsync() is { } message)
        {
            order.Add(message.Kind);
            switch (message)
            {
                case VideoFrame frame: first = frame; break;
                case ClipboardPayload payload: clipboard = payload; break;
                case StreamConfig stream: config = stream; break;
            }
        }
        var status = order.IndexOf(MessageKind.HostStatus);
        Assert.True(status >= 0 && status < order.IndexOf(MessageKind.StreamConfig));
        Assert.True(order.IndexOf(MessageKind.StreamConfig) < order.IndexOf(MessageKind.VideoConfig));
        Assert.Equal(MessageKind.VideoConfig, order[^2]);
        Assert.Equal(VideoCodec.H264, config!.Codec); // whatever the client prefers
        Assert.Equal(800, config.Display.PointWidth);
        Assert.Equal("from the PC", clipboard?.Text);
        Assert.True(first!.IsKeyframe);
        Assert.Equal(0ul, first.Sequence);
        Assert.Equal(1600u, first.Width);
        Assert.True(Video.AnnexB.AvccHasIdr(first.Data));

        // A few P-frames, then a keyframe request: the next frame is an IDR, fast.
        for (var i = 0; i < 3; i++) Assert.False((await Loopback.Next<VideoFrame>(connection)).IsKeyframe);
        var watch = Stopwatch.StartNew();
        await connection.SendAsync(RequestKeyframe.Instance);
        var next = await Loopback.Next<VideoFrame>(connection);
        while (!next.IsKeyframe && watch.ElapsedMilliseconds < 1000) next = await Loopback.Next<VideoFrame>(connection);
        Assert.True(next.IsKeyframe);
        Assert.True(watch.ElapsedMilliseconds < 100, $"IDR after {watch.ElapsedMilliseconds} ms");

        const ulong nanos = 9_007_199_254_740_993;
        await connection.SendAsync(new Ping { SentAtNanos = nanos });
        Assert.Equal(nanos, (await Loopback.Next<Pong>(connection)).EchoNanos);

        // Input and the clipboard reach the host.
        await connection.SendAsync(new KeyEvent { KeyCode = 0x31, IsDown = true, Modifiers = KeyModifiers.Command });
        await connection.SendAsync(new PointerEvent { Action = PointerAction.Down, X = 400, Y = 250 });
        await connection.SendAsync(new TextInput { Text = "héllo" });
        await connection.SendAsync(new ClipboardPayload { Text = "from the iPad" });
        await connection.SendAsync(new HostCommandMessage { Command = HostCommand.RefreshDisplays });
        Assert.Single((await Loopback.Next<DisplayList>(connection)).Displays);
        lock (host.Input.Events)
        {
            Assert.Equal(0x31, Assert.IsType<KeyEvent>(host.Input.Events[0]).KeyCode);
            Assert.Equal(400f, Assert.IsType<PointerEvent>(host.Input.Events[1]).X);
            Assert.Equal(["héllo"], host.Input.Texts);
        }
        Assert.Equal("from the iPad", host.Clipboard.Read()?.Text);

        connection.Close();
        for (var i = 0; i < 50 && host.Input.Releases == 0; i++) await Task.Delay(20);
        Assert.True(host.Input.Releases > 0, "everything is released when the session ends");
    }

    /// <summary>
    /// A dictation-length <c>textInput</c> is pasted (clipboard, Ctrl+V, the old clipboard back) on the
    /// real session; short text is still typed; the client hears neither clipboard write, and still
    /// hears the PC's next real copy.
    /// </summary>
    [Fact]
    public async Task LongTextIsPastedAndTheClipboardComesBackUnheard()
    {
        await using var host = new TestHost(clipboardText: "from the PC", pasteRestoreDelay: TimeSpan.FromSeconds(1));
        var client = new TestClient();
        var (connection, _, _) = await client.ConnectAsync(host.Port, "246810");
        var heard = new List<string?>();
        async Task<T> Next<T>() where T : class, IMessage
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (await connection.ReceiveAsync(limit.Token) is { } message)
            {
                if (message is ClipboardPayload payload) heard.Add(payload.Text);
                if (message is T wanted) return wanted;
            }
            throw new IOException($"closed before a {typeof(T).Name}");
        }
        await connection.SendAsync(new SelectDisplay { Selection = new DisplaySelection.Display(1), TargetFPS = 30, Quality = QualityPreset.Auto });
        await Next<VideoFrame>();

        const string dictation = "A dictation of more than sixteen units, pasted whole.";
        await connection.SendAsync(new TextInput { Text = "short typed text" }); // exactly 16
        await connection.SendAsync(new TextInput { Text = dictation });
        await connection.SendAsync(new Ping { SentAtNanos = 7 });
        while ((await Next<Pong>()).EchoNanos != 7)
        {
        }

        Assert.Equal(["short typed text"], host.Input.Texts);
        lock (host.Input.Events)
        {
            Assert.Equal(
                [(ClipboardPaster.VKeyCode, true, KeyModifiers.Control), (ClipboardPaster.VKeyCode, false, KeyModifiers.Control)],
                host.Input.Events.OfType<KeyEvent>().Select(k => (k.KeyCode, k.IsDown, k.Modifiers)));
        }
        Assert.Equal(dictation, host.Clipboard.Read()?.Text);
        for (var i = 0; i < 150 && host.Clipboard.Read()?.Text != "from the PC"; i++) await Task.Delay(20);
        Assert.Equal("from the PC", host.Clipboard.Read()?.Text);

        host.Clipboard.Copy(new ClipboardPayload { Text = "copied on the PC" });
        while ((await Next<ClipboardPayload>()).Text != "copied on the PC")
        {
        }
        Assert.Equal(["from the PC", "copied on the PC"], heard); // the stream's start, then the real copy only
        connection.Close();
    }

    [Fact]
    public async Task SleepingDisplayIsReportedAndWakeBringsThePictureBack()
    {
        await using var host = new TestHost(displayAsleep: true);
        var client = new TestClient();
        var (connection, _, result) = await client.ConnectAsync(host.Port, "246810");
        Assert.Equal(AuthStatus.Ok, result.Status); // connecting woke it
        await connection.SendAsync(new SelectDisplay { Selection = new DisplaySelection.Display(1), TargetFPS = 30, Quality = QualityPreset.Auto });
        Assert.True((await Loopback.Next<VideoFrame>(connection)).IsKeyframe);

        await connection.SendAsync(new HostCommandMessage { Command = HostCommand.SleepDisplay });
        HostStatus status;
        do status = await Loopback.Next<HostStatus>(connection); while (status.IsDisplayAsleep != true);
        Assert.False(status.IsScreenUnavailable);

        await connection.SendAsync(new HostCommandMessage { Command = HostCommand.WakeDisplay });
        do status = await Loopback.Next<HostStatus>(connection); while (status.IsDisplayAsleep != false);
        Assert.True((await Loopback.Next<VideoFrame>(connection)).IsKeyframe);
        connection.Close();
    }

    /// <summary>An iPad flick glides on the real session (its queue and the system clock), and the glide ends with the session.</summary>
    [Fact]
    public async Task FlickGlidesUntilTheSessionEnds()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        var (connection, _, _) = await client.ConnectAsync(host.Port, "246810");
        await connection.SendAsync(new SelectDisplay { Selection = new DisplaySelection.Display(1), TargetFPS = 30, Quality = QualityPreset.Auto });
        Assert.True((await Loopback.Next<VideoFrame>(connection)).IsKeyframe);

        await connection.SendAsync(new ScrollEvent
        {
            Phase = ScrollPhase.Ended, Momentum = MomentumPhase.Began, IsContinuous = true,
            DeltaX = 0, DeltaY = 4, X = 400, Y = 250, VelocityX = 0, VelocityY = 3000,
        });
        List<ScrollEvent> Scrolls()
        {
            lock (host.Input.Events) return host.Input.Events.OfType<ScrollEvent>().ToList();
        }
        for (var i = 0; i < 100 && Scrolls().Count < 6; i++) await Task.Delay(20);
        var scrolls = Scrolls();
        Assert.Equal((ScrollPhase.Ended, MomentumPhase.None), (scrolls[0].Phase, scrolls[0].Momentum));
        Assert.Equal((ScrollPhase.None, MomentumPhase.Began), (scrolls[1].Phase, scrolls[1].Momentum));
        Assert.All(scrolls.Skip(2), s => Assert.True(s.Momentum == MomentumPhase.Changed && s.DeltaY > 0));

        connection.Close();
        for (var i = 0; i < 50 && host.Input.Releases == 0; i++) await Task.Delay(20);
        Assert.True(host.Input.Releases > 0);
        var ended = Scrolls();
        Assert.Equal(MomentumPhase.Ended, ended[^1].Momentum); // cut short: 3000 pt/s glides for about 2.7 s
        await Task.Delay(200);
        Assert.Equal(ended.Count, Scrolls().Count);
    }

    [Fact]
    public async Task MissingPictureIsExplainedUntilFramesReturn()
    {
        await using var host = new TestHost(captureFailsFor: TimeSpan.FromSeconds(4));
        var client = new TestClient();
        var (connection, _, _) = await client.ConnectAsync(host.Port, "246810");
        await connection.SendAsync(new SelectDisplay { Selection = new DisplaySelection.Display(1), TargetFPS = 30, Quality = QualityPreset.Auto });
        HostStatus status;
        do status = await Loopback.Next<HostStatus>(connection); while (status.IsScreenUnavailable != true);
        // The picture comes back (starting with an IDR) and the note is cleared, in either order.
        VideoFrame? frame = null;
        var cleared = false;
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        while ((frame is null || !cleared) && await connection.ReceiveAsync(limit.Token) is { } message)
        {
            if (message is VideoFrame video) frame ??= video;
            if (message is HostStatus { IsScreenUnavailable: false }) cleared = true;
        }
        Assert.True(frame!.IsKeyframe);
        Assert.True(cleared);
        connection.Close();
    }

    [Fact]
    public async Task AttachTokensWorkOnceFromTheSameAddressOnly()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        var (primary, _, result) = await client.ConnectAsync(host.Port, "246810");

        // From ::1 when it was issued to 127.0.0.1: refused, and the token is gone.
        var foreign = await FramedConnection.ConnectAsync("::1", host.Port);
        await foreign.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        Assert.Null(await foreign.ReceiveAsync());
        var retry = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await retry.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        Assert.Null(await retry.ReceiveAsync());
        primary.Close();

        (primary, _, result) = await client.ConnectAsync(host.Port);
        var channel = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await channel.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        var engine = new FileTransferEngine(channel, FileTransferRole.Client, new FileTransferConfiguration { ReceiveDirectory = Path.Combine(host.Root, "client") });
        _ = engine.RunAsync();
        var file = Path.Combine(host.Root, "Hello.txt");
        await File.WriteAllTextAsync(file, "hello");
        Assert.Equal(new FileTransferOutcome.Sent("Hello.txt"), await engine.SendAsync(file));
        Assert.Equal("hello", await File.ReadAllTextAsync(Path.Combine(host.Root, "received", "Hello.txt")));
        Assert.Single(host.Listener.FileChannels);

        var reuse = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await reuse.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        Assert.Null(await reuse.ReceiveAsync());

        // The channel outlives its session.
        await primary.SendAsync(new DisconnectMessage { Reason = "done" });
        await Task.Delay(200);
        Assert.True(Assert.Single(host.Listener.FileChannels).SessionEnded);
        Assert.Equal(new FileTransferOutcome.Sent("Hello 2.txt"), await engine.SendAsync(file));
        engine.Close();
    }

    [Fact]
    public async Task WhoisNamesTheDeviceInTheTrustListSessionsAndSavedFiles()
    {
        await using var host = new TestHost(peers: new FixedPeers(new PeerIdentity("drew@example.com", "Drew", "Drew's iPad Pro")));
        var client = new TestClient();
        var (connection, challenge, result) = await client.ConnectAsync(host.Port, "246810").WaitAsync(TimeSpan.FromSeconds(30));
        Assert.Equal(AuthStatus.Ok, result.Status);
        Assert.Equal("drew@example.com", challenge.PeerTailnetName);
        var trusted = Assert.Single(host.Listener.Environment.Trust.List());
        Assert.Equal("Test iPad", trusted.Name);
        Assert.Equal("Drew's iPad Pro", trusted.DeviceName);
        Assert.Equal("Drew's iPad Pro", trusted.DisplayName);
        Assert.Equal("Drew's iPad Pro", Assert.Single(host.Listener.Sessions).ClientName);

        var channel = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await channel.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        var engine = new FileTransferEngine(channel, FileTransferRole.Client, new FileTransferConfiguration { ReceiveDirectory = Path.Combine(host.Root, "client") });
        _ = engine.RunAsync();
        var file = Path.Combine(host.Root, "From iPad.txt");
        await File.WriteAllTextAsync(file, "hi");
        var outcome = await engine.SendAsync(file).WaitAsync(TimeSpan.FromSeconds(30));
        Assert.True(outcome.IsSuccess, outcome.ToString());
        lock (host.Files.Saved) Assert.Equal(new FileSender("Drew's iPad Pro", trusted.Fingerprint), Assert.Single(host.Files.Saved).Sender);
        engine.Close();
        connection.Close();
    }

    [Fact]
    public async Task ListenerReportsItsState()
    {
        await using var host = new TestHost();
        Assert.Equal(HostListenerState.Listening, host.Listener.State);
        var clash = new HostListener(host.Listener.Environment, new HostListenerOptions { Port = host.Port, AllowLoopback = true });
        var changes = new List<HostListenerState>();
        clash.StateChanged += changes.Add;
        await Assert.ThrowsAsync<System.Net.Sockets.SocketException>(() => clash.StartAsync());
        Assert.Equal(HostListenerState.Failed, clash.State);
        Assert.Equal([HostListenerState.Failed], changes);
        Assert.Contains("in use", clash.FailureReason);
        await host.Listener.StopAsync();
        Assert.Equal(HostListenerState.Stopped, host.Listener.State);
    }

    [Fact]
    public async Task ACutOffSendIsPausedNotFailedAndResumesUnderItsIdWhenTheDeviceReturns()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        var events = new System.Collections.Concurrent.ConcurrentQueue<(Guid Channel, FileTransferEvent Event)>();
        var queued = new System.Collections.Concurrent.ConcurrentQueue<FileTransferItem>();
        var paused = new TaskCompletionSource<FileTransferPause>(TaskCreationOptions.RunContinuationsAsynchronously);
        var finished = new TaskCompletionSource<FileTransferOutcome>(TaskCreationOptions.RunContinuationsAsynchronously);
        host.Listener.FileTransfer += (channel, transferEvent) =>
        {
            events.Enqueue((channel, transferEvent));
            if (transferEvent is FileTransferEvent.Finished done) finished.TrySetResult(done.Outcome);
        };
        host.Listener.FileSendQueued += (_, item) => queued.Enqueue(item);
        host.Listener.FileTransferPaused += pause => paused.TrySetResult(pause);

        // A file channel that takes the offer and then drops, without answering.
        var (primary, _, result) = await client.ConnectAsync(host.Port, "246810");
        var raw = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await raw.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        var channel = await WaitForAsync(() => host.Listener.FileChannels.FirstOrDefault());
        var file = Path.Combine(host.Root, "Report.pdf");
        await File.WriteAllBytesAsync(file, new byte[300_000]);
        var send = host.Listener.SendFileAsync(channel.Id, file);
        var offer = await Loopback.Next<FileOffer>(raw);
        var item = Assert.Single(queued);
        Assert.Equal((offer.Id, "Report.pdf", 300_000UL, FileDirection.Sending), (item.Id, item.Name, item.ByteCount, item.Direction));
        raw.Close();

        var pause = await paused.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal((offer.Id, FileDirection.Sending, "Test iPad"), (pause.TransferId, pause.Direction, pause.ClientName));
        Assert.IsType<FileTransferOutcome.Failed>(await send.WaitAsync(TimeSpan.FromSeconds(10)));
        await Task.Delay(200);
        Assert.DoesNotContain(events, e => e.Event is FileTransferEvent.Finished);

        // The same device again: the listener re-offers it under the same id and it arrives.
        primary.Close();
        (primary, _, result) = await client.ConnectAsync(host.Port);
        var again = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await again.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        var received = Directory.CreateDirectory(Path.Combine(host.Root, "client")).FullName;
        var engine = new FileTransferEngine(again, FileTransferRole.Client, new FileTransferConfiguration { ReceiveDirectory = received });
        _ = engine.RunAsync();
        Assert.IsType<FileTransferOutcome.Sent>(await finished.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Contains(events, e => e.Event is FileTransferEvent.Started started && started.Item.Id == offer.Id);
        Assert.Single(events, e => e.Event is FileTransferEvent.Finished);
        engine.Close();
        primary.Close();
    }

    [Fact]
    public async Task CancellingAPausedSendForgetsIt()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        var paused = new TaskCompletionSource<FileTransferPause>(TaskCreationOptions.RunContinuationsAsynchronously);
        var finished = new TaskCompletionSource<(Guid, FileTransferEvent.Finished)>(TaskCreationOptions.RunContinuationsAsynchronously);
        host.Listener.FileTransferPaused += pause => paused.TrySetResult(pause);
        host.Listener.FileTransfer += (channel, transferEvent) =>
        {
            if (transferEvent is FileTransferEvent.Finished done) finished.TrySetResult((channel, done));
        };
        var (primary, _, result) = await client.ConnectAsync(host.Port, "246810");
        var raw = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await raw.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        var channel = await WaitForAsync(() => host.Listener.FileChannels.FirstOrDefault());
        var file = Path.Combine(host.Root, "Report.pdf");
        await File.WriteAllBytesAsync(file, new byte[1000]);
        _ = host.Listener.SendFileAsync(channel.Id, file);
        await Loopback.Next<FileOffer>(raw);
        raw.Close();
        var pause = await paused.Task.WaitAsync(TimeSpan.FromSeconds(10));

        host.Listener.CancelTransfer(pause.FileChannelId, pause.TransferId);
        var (from, done) = await finished.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal((channel.Id, pause.TransferId, (FileTransferOutcome)new FileTransferOutcome.Cancelled(false)), (from, done.Id, done.Outcome));

        // Reattaching re-offers nothing.
        primary.Close();
        (primary, _, result) = await client.ConnectAsync(host.Port);
        var again = await FramedConnection.ConnectAsync("127.0.0.1", host.Port);
        await again.SendAsync(new AttachMedia { SessionToken = result.SessionToken! });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Loopback.Next<FileOffer>(again, TimeSpan.FromMilliseconds(700)));
        again.Close();
        primary.Close();
    }

    private static async Task<T> WaitForAsync<T>(Func<T?> read) where T : class
    {
        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < TimeSpan.FromSeconds(10))
        {
            if (read() is { } value) return value;
            await Task.Delay(20);
        }
        throw new TimeoutException();
    }

    [Fact]
    public async Task RevokingSendsDisconnect()
    {
        await using var host = new TestHost();
        var client = new TestClient();
        var (connection, _, _) = await client.ConnectAsync(host.Port, "246810");
        await Task.Delay(100);
        var session = Assert.Single(host.Listener.Sessions);
        await host.Listener.RevokeAsync(session.Fingerprint);
        Assert.NotNull(await Loopback.Next<DisconnectMessage>(connection));
        var (_, challenge, _) = await client.ConnectAsync(host.Port);
        Assert.False(challenge.IsPaired);
    }
}
