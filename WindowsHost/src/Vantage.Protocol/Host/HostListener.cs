using System.Net;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Files;
using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// The host's front door (Mac <c>HostController</c>): listens on <c>[::]:port</c>, checks each
/// peer's address (tailnet CGNAT/ULA, loopback only when allowed), reads the first message (15 s),
/// and starts a <see cref="HostSessionCore"/> for <c>hello</c> or attaches a file channel for
/// <c>attachMedia</c>. Owns the pairing code, the attach tokens, the running sessions, and the file
/// channels (which outlive their sessions). This is the surface the Windows app and CLI use.
/// </summary>
/// <remarks>Events are raised on thread-pool threads; marshal to the UI thread yourself.</remarks>
#pragma warning disable CS0067 // events are raised once step 2 lands
public sealed class HostListener : IAsyncDisposable
{
    private readonly HostEnvironment _environment;
    private readonly HostListenerOptions _options;

    /// <summary>Creates a listener; nothing happens until <see cref="StartAsync"/>.</summary>
    public HostListener(HostEnvironment environment, HostListenerOptions options)
    {
        _environment = environment;
        _options = options;
        Pairing = new PairingCodes(environment.Time, options.FixedPairingCode);
    }

    /// <summary>The pairing code (Show Pairing Code → <see cref="PairingCodes.NewCode"/>; hide it on <see cref="PairingCodes.Cleared"/>).</summary>
    public PairingCodes Pairing { get; }

    /// <summary>Where the listener is bound once started (the port is useful when 0 was asked for).</summary>
    public IPEndPoint? LocalEndPoint => throw new NotImplementedException("W1 step 2");

    /// <summary>Screen and files-only sessions now connected (probes aren't listed).</summary>
    public IReadOnlyList<SessionSnapshot> Sessions => throw new NotImplementedException("W1 step 2");

    /// <summary>Attached file channels, including ones whose session has ended.</summary>
    public IReadOnlyList<FileChannelSnapshot> FileChannels => throw new NotImplementedException("W1 step 2");

    /// <summary>Raised when <see cref="Sessions"/> or <see cref="FileChannels"/> change (connect, disconnect, stream start, attach).</summary>
    public event Action? Changed;

    /// <summary>Every file engine's events, tagged with the channel they came from (UI progress, notifications).</summary>
    public event Action<Guid, FileTransferEvent>? FileTransfer;

    /// <summary>A client paired successfully (fingerprint, client name). The pairing code is gone by now.</summary>
    public event Action<string, string>? Paired;

    /// <summary>
    /// Binds and starts accepting. Throws <see cref="System.Net.Sockets.SocketException"/> if the
    /// port is taken. With a <see cref="HostListenerOptions.FixedPairingCode"/>, shows that code.
    /// </summary>
    public Task StartAsync(CancellationToken cancellationToken = default) =>
        throw new NotImplementedException($"W1 step 2 ({_environment.HostName}, {_options.Port})");

    /// <summary>
    /// Stops accepting and closes every session and file channel <em>without</em> a
    /// <c>disconnect</c> message, so clients reconnect (app quit or restart).
    /// </summary>
    public Task StopAsync() => throw new NotImplementedException("W1 step 2");

    /// <summary>
    /// Ends one session deliberately: sends <c>disconnect{reason}</c> (the client shows it and
    /// doesn't reconnect), then closes. Its file channel keeps running.
    /// </summary>
    public Task DisconnectAsync(Guid sessionId, string reason) => throw new NotImplementedException("W1 step 2");

    /// <summary>
    /// Queues a file to send on a file channel (FIFO, one at a time) and completes when it ends.
    /// "Send File to ⟨iPad⟩…" in the tray.
    /// </summary>
    public Task<FileTransferOutcome> SendFileAsync(Guid fileChannelId, string path, CancellationToken cancellationToken = default) =>
        throw new NotImplementedException("W1 step 2");

    /// <summary>Cancels one transfer on a file channel (sends <c>fileCancel</c>; an incoming partial is deleted).</summary>
    public void CancelTransfer(Guid fileChannelId, Guid transferId) => throw new NotImplementedException("W1 step 2");

    /// <summary>
    /// Removes a paired client from the trust store, sends <c>disconnect</c> to its sessions, and
    /// closes its file channels.
    /// </summary>
    public Task RevokeAsync(string fingerprint) => throw new NotImplementedException("W1 step 2");

    /// <inheritdoc />
    public ValueTask DisposeAsync() => new(StopAsync());
}
#pragma warning restore CS0067

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
