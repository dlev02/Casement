using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Files;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Net;
using Vantage.Protocol.Transport;

namespace Vantage.Protocol.Host;

/// <summary>
/// The host's front door (Mac <c>HostController</c>): listens on <c>[::]:port</c>, checks each
/// peer's address (tailnet CGNAT/ULA, loopback only when allowed), reads the first message (15 s),
/// and starts a <see cref="HostSessionCore"/> for <c>hello</c> or attaches a file channel for
/// <c>attachMedia</c>. Owns the pairing code, the attach tokens, the running sessions, and the file
/// channels (which outlive their sessions). This is the surface the Windows app and CLI use.
/// </summary>
/// <remarks>Events are raised on thread-pool threads; marshal to the UI thread yourself.</remarks>
public sealed class HostListener : IAsyncDisposable
{
    private readonly ILogger _log;
    private readonly ConcurrentDictionary<Guid, HostSessionCore> _sessions = new();
    private readonly ConcurrentDictionary<Guid, FileChannel> _fileChannels = new();
    private readonly ConcurrentDictionary<Guid, string> _resumeFolders = new();
    private readonly Lock _interruptedLock = new();
    private readonly List<InterruptedSend> _interrupted = [];
    private readonly CancellationTokenSource _stopping = new();
    private Socket? _socket;
    private Task? _acceptLoop;

    /// <summary>Creates a listener; nothing happens until <see cref="StartAsync"/>.</summary>
    public HostListener(HostEnvironment environment, HostListenerOptions options)
    {
        Environment = environment;
        Options = options;
        _log = environment.Logging.CreateLogger("Vantage.Listener");
        Pairing = new PairingCodes(environment.Time, options.FixedPairingCode);
        AttachTokens = new AttachTokenRegistry<HostSessionCore>(environment.Time);
        if (options.FixedPairingCode is not null && options.RearmFixedPairingCodeAfter is { } rearm)
        {
            Pairing.Cleared += () => _ = Task.Delay(rearm, environment.Time, _stopping.Token).ContinueWith(
                delay => { if (delay.IsCompletedSuccessfully && Pairing.Current is null) Pairing.NewCode(); }, TaskScheduler.Default);
        }
    }

    internal HostEnvironment Environment { get; }
    internal HostListenerOptions Options { get; }
    internal AttachTokenRegistry<HostSessionCore> AttachTokens { get; }

    /// <summary>The pairing code (Show Pairing Code → <see cref="PairingCodes.NewCode"/>; hide it on <see cref="PairingCodes.Cleared"/>).</summary>
    public PairingCodes Pairing { get; }

    /// <summary>Where the listener is bound once started (the port is useful when 0 was asked for).</summary>
    public IPEndPoint? LocalEndPoint => _socket?.LocalEndPoint as IPEndPoint;

    /// <summary>Screen and files-only sessions now connected (probes aren't listed).</summary>
    public IReadOnlyList<SessionSnapshot> Sessions =>
        [.. _sessions.Values.Where(s => s.State is SessionState.Streaming or SessionState.FilesOnly).Select(s => s.Snapshot())];

    /// <summary>Attached file channels, including ones whose session has ended.</summary>
    public IReadOnlyList<FileChannelSnapshot> FileChannels =>
        [.. _fileChannels.Values.Select(c => new FileChannelSnapshot(c.Id, c.Session.Id, c.ClientName, c.Session.Fingerprint, c.ReceiveDirectory,
                                                                    c.Session.State == SessionState.Closed, c.Engine.IsBusy))];

    /// <summary>Raised when <see cref="Sessions"/> or <see cref="FileChannels"/> change (connect, disconnect, stream start, attach).</summary>
    public event Action? Changed;

    /// <summary>Every file engine's events, tagged with the channel they came from (UI progress, notifications).</summary>
    public event Action<Guid, FileTransferEvent>? FileTransfer;

    /// <summary>A client paired successfully (fingerprint, device name). The pairing code is gone by now.</summary>
    public event Action<string, string>? Paired;

    /// <summary>Whether the listener is accepting connections.</summary>
    public HostListenerState State { get; private set; } = HostListenerState.Stopped;

    /// <summary>Why it failed, when <see cref="State"/> is <see cref="HostListenerState.Failed"/> (e.g. "the port is in use").</summary>
    public string? FailureReason { get; private set; }

    /// <summary>Raised (any thread) when <see cref="State"/> changes.</summary>
    public event Action<HostListenerState>? StateChanged;

    private void SetState(HostListenerState state, string? reason = null)
    {
        FailureReason = reason;
        if (State == state) return;
        State = state;
        StateChanged?.Invoke(state);
    }

    /// <summary>
    /// Binds and starts accepting. Throws <see cref="SocketException"/> if the port is taken. With a
    /// <see cref="HostListenerOptions.FixedPairingCode"/>, shows that code.
    /// </summary>
    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        var socket = new Socket(AddressFamily.InterNetworkV6, SocketType.Stream, ProtocolType.Tcp) { DualMode = true };
        try
        {
            // Never share the port with another listener (a second host must fail, not split connections).
            if (OperatingSystem.IsWindows()) socket.ExclusiveAddressUse = true;
            socket.Bind(new IPEndPoint(IPAddress.IPv6Any, Options.Port));
            socket.Listen(64);
        }
        catch (SocketException error)
        {
            socket.Dispose();
            SetState(HostListenerState.Failed, error.SocketErrorCode == SocketError.AddressAlreadyInUse
                ? $"Port {Options.Port} is already in use." : error.Message);
            _log.LogError("can't listen on port {Port}: {Error}", Options.Port, error.Message);
            throw;
        }
        _socket = socket;
        SetState(HostListenerState.Listening);
        if (Options.FixedPairingCode is not null) Pairing.NewCode();
        _acceptLoop = Task.Run(AcceptLoopAsync, cancellationToken);
        _log.LogInformation("listening on {EndPoint}{Loopback}", socket.LocalEndPoint, Options.AllowLoopback ? " (loopback allowed)" : "");
        return Task.CompletedTask;
    }

    /// <summary>
    /// Stops accepting and closes every session and file channel <em>without</em> a
    /// <c>disconnect</c> message, so clients reconnect (app quit or restart).
    /// </summary>
    public async Task StopAsync()
    {
        if (_stopping.IsCancellationRequested) return;
        await _stopping.CancelAsync().ConfigureAwait(false);
        SetState(HostListenerState.Stopped);
        _socket?.Dispose();
        foreach (var session in _sessions.Values) session.Abort();
        foreach (var channel in _fileChannels.Values) channel.Engine.Close();
        if (_acceptLoop is not null)
        {
            try
            {
                await _acceptLoop.ConfigureAwait(false);
            }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                // Stopping.
            }
        }
    }

    /// <summary>
    /// Ends one session deliberately: sends <c>disconnect{reason}</c> (the client shows it and
    /// doesn't reconnect), then closes. Its file channel keeps running.
    /// </summary>
    public Task DisconnectAsync(Guid sessionId, string reason) =>
        _sessions.TryGetValue(sessionId, out var session) ? session.DisconnectAsync(reason) : Task.CompletedTask;

    /// <summary>
    /// Queues a file to send on a file channel (FIFO, one at a time) and completes when it ends.
    /// "Send File to ⟨iPad⟩…" in the tray.
    /// </summary>
    public Task<FileTransferOutcome> SendFileAsync(Guid fileChannelId, string path, CancellationToken cancellationToken = default)
    {
        if (!_fileChannels.TryGetValue(fileChannelId, out var channel))
            return Task.FromResult<FileTransferOutcome>(new FileTransferOutcome.Failed("That device isn't connected any more."));
        return SendTrackedAsync(channel, path, Guid.NewGuid()).WaitAsync(cancellationToken);
    }

    /// <summary>
    /// Sends on a channel; a send the connection cut off is remembered, and re-offered under the
    /// same id (so the device resumes from its partial) when the same device attaches again
    /// within <see cref="HostListenerOptions.InterruptedSendResumeWindow"/>.
    /// </summary>
    private async Task<FileTransferOutcome> SendTrackedAsync(FileChannel channel, string path, Guid id)
    {
        var outcome = await channel.Engine.SendAsync(path, id: id).ConfigureAwait(false);
        if (outcome is FileTransferOutcome.Failed && channel.Engine.HasClosed)
        {
            lock (_interruptedLock) _interrupted.Add(new InterruptedSend(channel.Session.Fingerprint, id, path, Environment.Time.GetUtcNow()));
            _log.LogInformation("a send to {Client} was cut off; it resumes when the device reconnects", channel.ClientName);
        }
        return outcome;
    }

    private List<InterruptedSend> TakeInterrupted(string fingerprint)
    {
        var cutoff = Environment.Time.GetUtcNow() - Options.InterruptedSendResumeWindow;
        lock (_interruptedLock)
        {
            _interrupted.RemoveAll(send => send.At < cutoff);
            var mine = _interrupted.FindAll(send => send.Fingerprint == fingerprint);
            _interrupted.RemoveAll(send => send.Fingerprint == fingerprint);
            return mine;
        }
    }

    /// <summary>Cancels one transfer on a file channel (sends <c>fileCancel</c>; an incoming partial is deleted).</summary>
    public void CancelTransfer(Guid fileChannelId, Guid transferId)
    {
        if (_fileChannels.TryGetValue(fileChannelId, out var channel)) channel.Engine.Cancel(transferId);
    }

    /// <summary>
    /// Removes a paired client from the trust store, sends <c>disconnect</c> to its sessions, and
    /// closes its file channels.
    /// </summary>
    public async Task RevokeAsync(string fingerprint)
    {
        Environment.Trust.Revoke(fingerprint);
        var sessions = _sessions.Values.Where(s => s.Fingerprint == fingerprint).ToList();
        foreach (var channel in _fileChannels.Values.Where(c => c.Session.Fingerprint == fingerprint)) channel.Engine.Close();
        await Task.WhenAll(sessions.Select(s => s.DisconnectAsync("This device was removed from the host."))).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    // MARK: Accepting

    private async Task AcceptLoopAsync()
    {
        var token = _stopping.Token;
        while (!token.IsCancellationRequested)
        {
            Socket client;
            try
            {
                client = await _socket!.AcceptAsync(token).ConfigureAwait(false);
            }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException)
            {
                return;
            }
            catch (SocketException error) when (error.SocketErrorCode is SocketError.ConnectionReset or SocketError.ConnectionAborted
                                                    or SocketError.TooManyOpenSockets or SocketError.NoBufferSpaceAvailable)
            {
                _log.LogError("accept failed: {Error}", error.Message);
                await Task.Delay(TimeSpan.FromMilliseconds(100), Environment.Time, CancellationToken.None).ConfigureAwait(false);
                continue;
            }
            catch (SocketException error)
            {
                _log.LogError("the listener stopped: {Error}", error.Message);
                SetState(HostListenerState.Failed, error.Message);
                return;
            }
            var remote = client.RemoteEndPoint as IPEndPoint;
            if (remote is null || !PeerPolicy.IsAllowed(remote.Address, Options.AllowLoopback))
            {
                _log.LogInformation("refusing a connection from {Peer}: not a tailnet address", remote?.Address);
                client.Dispose();
                continue;
            }
            _ = Task.Run(() => AcceptAsync(client));
        }
    }

    /// <summary>Every connection says what it is first: <c>hello</c> opens a session, <c>attachMedia</c> a file channel.</summary>
    private async Task AcceptAsync(Socket socket)
    {
        FramedConnection connection;
        try
        {
            connection = new FramedConnection(socket, new FramedConnectionOptions(), Environment.Logging.CreateLogger("Vantage.Connection"));
        }
        catch (Exception error) when (error is SocketException or ObjectDisposedException)
        {
            socket.Dispose();
            return;
        }
        connection.Start();
        var peer = connection.RemoteEndPoint;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_stopping.Token);
        deadline.CancelAfter(Options.HandshakeTimeout);
        IMessage? first;
        try
        {
            first = await connection.ReceiveAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            _log.LogInformation("connection from {Peer} said nothing in time", peer);
            connection.Close();
            return;
        }
        switch (first)
        {
            case Hello hello:
                var session = new HostSessionCore(this, connection);
                if (hello.IsReadinessProbe != true) _sessions[session.Id] = session;
                _log.LogInformation("session from {Peer} ({Kind})", peer,
                                    hello.IsReadinessProbe == true ? "probe" : hello.Features?.FilesOnly == true ? "files only" : "screen");
                await session.RunAsync(hello, deadline.Token).ConfigureAwait(false);
                break;
            case AttachMedia attach:
                if (AttachTokens.Claim(attach.SessionToken, connection.PeerAddress) is not { } owner)
                {
                    _log.LogError("refusing a file channel from {Peer}: unknown, used, or foreign token", peer);
                    connection.Close();
                    return;
                }
                await AttachAsync(owner, connection).ConfigureAwait(false);
                break;
            default:
                _log.LogError("refusing a connection from {Peer} that opened with {Kind}", peer, first?.Kind);
                connection.Close();
                break;
        }
    }

    private async Task AttachAsync(HostSessionCore session, FramedConnection connection)
    {
        var engine = await session.AttachFileChannelAsync(connection).ConfigureAwait(false);
        if (engine is null) return;
        var channel = new FileChannel(Guid.NewGuid(), session, engine, session.ClientName, Environment.Files.ReceiveDirectory);
        _fileChannels[channel.Id] = channel;
        engine.Events += transferEvent =>
        {
            switch (transferEvent)
            {
                case FileTransferEvent.Started { Item.Direction: FileDirection.Receiving } started:
                    _resumeFolders.TryAdd(started.Item.Id, channel.ReceiveDirectory);
                    break;
                case FileTransferEvent.Finished { Outcome: not FileTransferOutcome.Failed } finished:
                    _resumeFolders.TryRemove(finished.Id, out _);
                    break;
            }
            FileTransfer?.Invoke(channel.Id, transferEvent);
        };
        _log.LogInformation("file channel from {Client} is up{FilesOnly}", channel.ClientName, session.State == SessionState.FilesOnly ? " (files only)" : "");
        Changed?.Invoke();
        var run = engine.RunAsync();
        var interrupted = TakeInterrupted(session.Fingerprint);
        if (interrupted.Count > 0)
        {
            _log.LogInformation("resuming {Count} interrupted file(s) to {Client}", interrupted.Count, channel.ClientName);
            _ = Task.Run(async () =>
            {
                foreach (var send in interrupted) await SendTrackedAsync(channel, send.Path, send.Id).ConfigureAwait(false);
            });
        }
        else if (Options.SendFileOnConnect is { } path)
        {
            _ = SendTrackedAsync(channel, path, Guid.NewGuid());
        }
        if (session.State == SessionState.Closed) _ = WatchDetachedAsync(channel);
        await run.ConfigureAwait(false);
        _fileChannels.TryRemove(channel.Id, out _);
        Changed?.Invoke();
    }

    /// <summary>A file channel whose session has ended closes after the idle limit with nothing moving.</summary>
    private async Task WatchDetachedAsync(FileChannel channel)
    {
        if (channel.Watching) return;
        channel.Watching = true;
        var idleSince = Environment.Time.GetUtcNow();
        try
        {
            while (_fileChannels.ContainsKey(channel.Id) && !channel.Engine.HasClosed)
            {
                await Task.Delay(Options.DetachedFileChannelCheckInterval, Environment.Time, _stopping.Token).ConfigureAwait(false);
                if (channel.Engine.IsBusy)
                {
                    idleSince = Environment.Time.GetUtcNow();
                    continue;
                }
                if (Environment.Time.GetUtcNow() - idleSince >= Options.DetachedFileChannelIdleLimit)
                {
                    _log.LogInformation("closing an idle file channel whose session ended");
                    channel.Engine.Close();
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Stopping.
        }
    }

    // MARK: Called by sessions

    internal string? ResumeFolderFor(Guid transferId) => _resumeFolders.TryGetValue(transferId, out var folder) ? folder : null;

    internal void SessionChanged() => Changed?.Invoke();

    internal void RaisePaired(string fingerprint, string name) => Paired?.Invoke(fingerprint, name);

    internal void SessionEnded(HostSessionCore session)
    {
        _sessions.TryRemove(session.Id, out _);
        // Its file channel carries on until the client closes it.
        foreach (var channel in _fileChannels.Values.Where(c => ReferenceEquals(c.Session, session))) _ = WatchDetachedAsync(channel);
        Changed?.Invoke();
    }

    private sealed record InterruptedSend(string Fingerprint, Guid Id, string Path, DateTimeOffset At);

    private sealed class FileChannel(Guid id, HostSessionCore session, FileTransferEngine engine, string clientName, string receiveDirectory)
    {
        public Guid Id { get; } = id;
        public HostSessionCore Session { get; } = session;
        public FileTransferEngine Engine { get; } = engine;
        public string ClientName { get; } = clientName;
        public string ReceiveDirectory { get; } = receiveDirectory;
        public bool Watching { get; set; }
    }
}

/// <summary>Whether a <see cref="HostListener"/> is accepting connections.</summary>
public enum HostListenerState
{
    /// <summary>Not started, or stopped.</summary>
    Stopped,
    /// <summary>Accepting connections.</summary>
    Listening,
    /// <summary>Couldn't bind or stopped accepting on its own; see <see cref="HostListener.FailureReason"/>.</summary>
    Failed,
}

/// <summary>A connected session, for the UI.</summary>
/// <param name="Id">Stable for the connection.</param>
/// <param name="ClientName"><c>Hello.clientName</c>, or the whois device name when known.</param>
/// <param name="Fingerprint">The client key's fingerprint (which device, across connections).</param>
/// <param name="Peer">Remote address (IPv4-mapped addresses already mapped).</param>
/// <param name="IsFilesOnly">A files-only session (no screen).</param>
/// <param name="ConnectedAt">When it authenticated.</param>
/// <param name="Display">The display being streamed, once a stream started.</param>
public sealed record SessionSnapshot(Guid Id, string ClientName, string Fingerprint, IPAddress Peer, bool IsFilesOnly,
                                     DateTimeOffset ConnectedAt, DisplayInfo? Display);

/// <summary>An attached file channel, for the UI.</summary>
/// <param name="Id">Stable for the channel; pass to <see cref="HostListener.SendFileAsync"/>.</param>
/// <param name="SessionId">The session that issued its token.</param>
/// <param name="ClientName">Who is on the other end.</param>
/// <param name="Fingerprint">The client key's fingerprint.</param>
/// <param name="ReceiveDirectory">Where its received files go.</param>
/// <param name="SessionEnded">Its session is gone; the channel stays until the client closes it or it idles out.</param>
/// <param name="IsBusy">Something is queued, moving, or re-hashing.</param>
public sealed record FileChannelSnapshot(Guid Id, Guid SessionId, string ClientName, string Fingerprint, string ReceiveDirectory,
                                         bool SessionEnded, bool IsBusy);
