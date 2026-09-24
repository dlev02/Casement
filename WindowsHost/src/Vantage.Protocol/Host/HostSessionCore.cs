using System.Net;
using Vantage.Protocol.Messages;

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
/// The platform never talks to a session directly; it sees <see cref="SessionSnapshot"/>s through
/// the listener. The members here are what the listener and tests use.
/// </remarks>
public sealed class HostSessionCore
{
    internal HostSessionCore(Guid id, IPAddress peer)
    {
        Id = id;
        Peer = peer;
    }

    /// <summary>Stable id for this connection.</summary>
    public Guid Id { get; }

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

    /// <summary>Runs the session on a connection whose first message (<paramref name="hello"/>) the listener already read. Completes when the session is over.</summary>
    internal Task RunAsync(Hello hello, CancellationToken cancellationToken) =>
        throw new NotImplementedException($"W1 step 2 ({hello.ClientName}, {State}, {ClientName}, {Fingerprint}, {Display})");
}
