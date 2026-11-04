using Vantage.Protocol.Audio;

namespace Vantage.Protocol.Host;

/// <summary>
/// The PC's sound output (Windows: WASAPI loopback; the synthetic host: a chime). The Mac's
/// <c>AudioSource</c>: it delivers fixed 10 ms <see cref="AudioBlock"/>s and nothing else; the
/// core owns the encoder, the <c>audioRequest</c>/<c>audioConfig</c> exchange and the packets.
/// </summary>
public interface IAudioSource
{
    /// <summary>
    /// Null when sound can be captured here (Windows: a loopback capture opened at least once),
    /// else a user-facing reason. <c>HostCapabilities.audio</c> is advertised only while this is
    /// null, so a client never offers what the PC can't do. Cheap to read; the platform probes
    /// once and caches.
    /// </summary>
    string? UnavailableReason { get; }

    /// <summary>
    /// Starts capturing. Throws <see cref="AudioUnavailableException"/> with a user-facing reason
    /// when it can't (no output device, Windows refused loopback); the client then shows it.
    /// </summary>
    /// <param name="onBlock">
    /// Called for each 10 ms block, one at a time, from the capture thread, with monotonic
    /// <see cref="AudioBlock.CaptureNanos"/>; a jump of more than 15 ms means a new timeline (a
    /// pause, a device change). Must not block: the core queues it for the encoder.
    /// </param>
    /// <param name="onStopped">
    /// Called at most once, with a user-facing reason, if capture stops on its own and can't be
    /// restarted (the source retries device changes itself). Not called after disposal.
    /// </param>
    /// <param name="cancellationToken">Cancels a start still in progress.</param>
    Task<IAudioCapture> StartAsync(Action<AudioBlock> onBlock, Action<string> onStopped, CancellationToken cancellationToken);
}

/// <summary>A running capture. Disposing stops it (no <c>onStopped</c> follows) and waits for the capture thread.</summary>
public interface IAudioCapture : IAsyncDisposable
{
    /// <summary>For the log: what is being captured ("process loopback, all apps but this host").</summary>
    string Description { get; }
}

/// <summary>Sound can't be captured right now; <see cref="Exception.Message"/> is shown to the user.</summary>
public sealed class AudioUnavailableException(string message, Exception? inner = null) : Exception(message, inner);
