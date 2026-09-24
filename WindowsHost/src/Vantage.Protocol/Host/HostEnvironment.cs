using Microsoft.Extensions.Logging;
using Vantage.Protocol.Auth;

namespace Vantage.Protocol.Host;

/// <summary>
/// Everything platform-specific a <see cref="HostListener"/> needs: the composition root (the
/// Windows app, the Windows CLI, or the synthetic host) fills this in once.
/// </summary>
public sealed class HostEnvironment
{
    /// <summary><c>Challenge.hostName</c>. Windows: the DNS host name, case preserved.</summary>
    public required string HostName { get; init; }

    /// <summary><c>Challenge.hostPlatform</c> and <c>HostCapabilities.platform</c> (<see cref="HostPlatforms"/>).</summary>
    public string Platform { get; init; } = HostPlatforms.Windows;

    /// <summary>Displays and capture.</summary>
    public required IScreenSource Screen { get; init; }

    /// <summary>Encoders for captured frames.</summary>
    public required IVideoEncoderFactory Encoders { get; init; }

    /// <summary>
    /// Makes the input sink for one screen session (not called for probes or files-only sessions).
    /// Windows: <c>() =&gt; new WindowsInputTranslator(sendInputInjector, logger)</c>. The session
    /// calls <see cref="IInputSink.ReleaseAll"/> and disposes it when it ends.
    /// </summary>
    public required Func<IInputSink> CreateInputSink { get; init; }

    /// <summary>The clipboard.</summary>
    public required IClipboard Clipboard { get; init; }

    /// <summary>Lock, secure desktop, display power.</summary>
    public required IHostStatusSource Status { get; init; }

    /// <summary>Keep-awake, display sleep/wake, lock.</summary>
    public required IPowerControl Power { get; init; }

    /// <summary>Tailscale whois; null when unavailable (no <c>peerTailnetName</c>, the client's own name is used).</summary>
    public IPeerDirectory? Peers { get; init; }

    /// <summary>Receive folder and file marking.</summary>
    public required IFileStore Files { get; init; }

    /// <summary>The host key.</summary>
    public required IIdentityStore Identity { get; init; }

    /// <summary>Paired clients.</summary>
    public required ITrustStore Trust { get; init; }

    /// <summary>Ed25519 implementation.</summary>
    public IEd25519 Ed25519 { get; init; } = new NSecEd25519();

    /// <summary>Clock for timeouts, expiry, and backoff (tests substitute a fake).</summary>
    public TimeProvider Time { get; init; } = TimeProvider.System;

    /// <summary>Loggers. Categories: <c>Vantage.Listener</c>, <c>Vantage.Session</c>, <c>Vantage.Files</c>, <c>Vantage.Input</c>.</summary>
    public required ILoggerFactory Logging { get; init; }
}

/// <summary>Listener settings, mostly from the command line (the same flags as the Mac DEBUG host).</summary>
public sealed record HostListenerOptions
{
    /// <summary>TCP port (<c>--port</c>). The listener binds <c>[::]</c> dual-mode on it.</summary>
    public int Port { get; init; } = VantageProtocol.DefaultPort;

    /// <summary>
    /// Accept 127.0.0.1 / ::1 as well as tailnet peers. DEBUG builds only (loopback reaching
    /// pairing would let any local process pair); the simulator and the interop tests need it.
    /// </summary>
    public bool AllowLoopback { get; init; }

    /// <summary><c>--pairing-code N</c>: a fixed code that never expires (DEBUG). Shown at start.</summary>
    public string? FixedPairingCode { get; init; }

    /// <summary>
    /// With a <see cref="FixedPairingCode"/>: show it again this long after it was used or burned
    /// (DEBUG <c>--pairing-code-rearm S</c>, so a test run can burn the code and still pair). Null
    /// (the default) keeps the Mac's rule: a fixed code works until one pairing uses it up.
    /// </summary>
    public TimeSpan? RearmFixedPairingCodeAfter { get; init; }

    /// <summary>How long a send cut off by a lost connection waits for the same device to reattach and resume it.</summary>
    public TimeSpan InterruptedSendResumeWindow { get; init; } = TimeSpan.FromHours(1);

    /// <summary>Limit for the whole handshake (first message through <c>authenticate</c>).</summary>
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(15);

    /// <summary><c>--send-file-on-connect PATH</c>: send this file to every client whose file channel attaches (DEBUG).</summary>
    public string? SendFileOnConnect { get; init; }

    /// <summary><c>--capture-fails-for S</c>: each session's capture fails this long from its first stream request (DEBUG).</summary>
    public TimeSpan? CaptureFailsFor { get; init; }

    /// <summary>A file channel whose session ended closes after this long with nothing moving.</summary>
    public TimeSpan DetachedFileChannelIdleLimit { get; init; } = TimeSpan.FromSeconds(120);

    /// <summary>How often detached file channels are checked for idleness.</summary>
    public TimeSpan DetachedFileChannelCheckInterval { get; init; } = TimeSpan.FromSeconds(15);
}
