using System.IO.Pipes;
using System.Security.Cryptography;
using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Auth;
using Vantage.Protocol.DesktopHelper;
using Vantage.Protocol.Input;
using Windows.Win32;

namespace Vantage.Host.Windows.DesktopHelper;

/// <summary>
/// The host's link to the SYSTEM desktop helper (<see cref="SecureDesktopHelper"/>), when Casement
/// Host Service is installed. It connects to this session's pipe, checks the helper's signature
/// against the public key in Program Files (so a program that took the pipe's name first gets
/// nothing, not even the keys typed at the lock screen), follows which desktop has the input, and
/// relays input and the secure desktop's frames. It tries again every few seconds while it isn't
/// connected; everything works as before without it.
/// </summary>
public sealed class HelperClient : IDisposable
{
    private static readonly TimeSpan s_retry = TimeSpan.FromSeconds(3);

    private readonly ILogger _log;
    private readonly IEd25519 _ed25519;
    private readonly CancellationTokenSource _stop = new();
    private readonly Lock _lock = new();
    private Channel<HelperMessage>? _outgoing;
    private HelperDesktopKind _desktop = HelperDesktopKind.Default;
    private bool _connected;
    private Action<HelperFrame>? _onFrame;
    private Action<string>? _onCaptureStopped;
    private bool _loggedWaiting;

    /// <param name="logging">Loggers (category <c>Vantage.Helper</c>).</param>
    /// <param name="ed25519">Checks the helper's signature.</param>
    public HelperClient(ILoggerFactory logging, IEd25519 ed25519)
    {
        _log = logging.CreateLogger("Vantage.Helper");
        _ed25519 = ed25519;
        _ = Task.Run(() => RunAsync(_stop.Token));
    }

    /// <summary>Raised (any thread) when the helper connects or goes, or the input desktop changes.</summary>
    public event Action? Changed;

    /// <summary>A verified helper is connected.</summary>
    public bool IsConnected
    {
        get { lock (_lock) return _connected; }
    }

    /// <summary>The helper is connected and the secure desktop (lock screen, administrator prompt, Ctrl+Alt+Del) has the input.</summary>
    public bool IsSecureDesktopUp
    {
        get { lock (_lock) return _connected && _desktop != HelperDesktopKind.Default; }
    }

    /// <summary>Has the helper inject <paramref name="actions"/> (queued in order; dropped if it isn't connected).</summary>
    public bool SendInput(ReadOnlySpan<InputAction> actions)
    {
        Channel<HelperMessage>? outgoing;
        lock (_lock) outgoing = _connected ? _outgoing : null;
        return outgoing is not null && outgoing.Writer.TryWrite(new HelperInput(actions.ToArray()));
    }

    /// <summary>
    /// Asks the helper to capture <paramref name="monitorDevice"/>; frames (and a stop it reports)
    /// arrive on the pipe's thread, one at a time. Dispose the result to stop. One capture at a
    /// time: a new one replaces the last.
    /// </summary>
    public IDisposable StartCapture(string monitorDevice, int maxFps, Action<HelperFrame> onFrame, Action<string> onStopped)
    {
        Channel<HelperMessage>? outgoing;
        lock (_lock)
        {
            _onFrame = onFrame;
            _onCaptureStopped = onStopped;
            outgoing = _outgoing;
        }
        outgoing?.Writer.TryWrite(new HelperStartCapture(monitorDevice, (uint)Math.Clamp(maxFps, 1, 60)));
        return new CaptureLease(this, onFrame);
    }

    private void StopCapture(Action<HelperFrame> owner)
    {
        Channel<HelperMessage>? outgoing;
        lock (_lock)
        {
            if (_onFrame != owner) return;
            _onFrame = null;
            _onCaptureStopped = null;
            outgoing = _outgoing;
        }
        outgoing?.Writer.TryWrite(new HelperStopCapture());
    }

    private async Task RunAsync(CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            if (HelperInstall.IsInstalled && HelperInstall.ReadPublicKey() is { } publicKey)
            {
                try
                {
                    await ConnectAndServeAsync(publicKey, stop).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or InvalidDataException or TimeoutException or UnauthorizedAccessException
                                               or OperationCanceledException or ChannelClosedException)
                {
                    if (!stop.IsCancellationRequested && !_loggedWaiting) _log.LogInformation("desktop helper not reachable: {Message}", ex.Message);
                    _loggedWaiting = true;
                }
                finally
                {
                    SetDisconnected();
                }
            }
            try { await Task.Delay(s_retry, stop).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task ConnectAndServeAsync(byte[] publicKey, CancellationToken stop)
    {
        if (!PInvoke.ProcessIdToSessionId(PInvoke.GetCurrentProcessId(), out var session)) return;
        using var pipe = new NamedPipeClientStream(".", HelperPipe.PipeName(session), PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(1000, stop).ConfigureAwait(false);
        using var channel = new HelperChannel(pipe);

        var nonce = RandomNumberGenerator.GetBytes(32);
        await channel.SendAsync(new HelperHello(HelperPipe.Version, nonce), stop).ConfigureAwait(false);
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop))
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            if (await channel.ReadAsync(timeout.Token).ConfigureAwait(false) is not HelperWelcome welcome)
                throw new InvalidDataException("the helper didn't answer hello");
            if (!_ed25519.Verify(publicKey, HelperProof.Transcript(session, nonce), welcome.Signature))
            {
                _log.LogWarning("something without the helper's key answered on its pipe; not using it");
                throw new InvalidDataException("the helper's signature didn't check out");
            }
            if (welcome.Version != HelperPipe.Version)
            {
                _log.LogWarning("the desktop helper ({Build}) speaks version {Theirs}, this host {Ours}: turn Control administrator prompts and apps off and on to update it",
                                welcome.Build, welcome.Version, HelperPipe.Version);
                await Task.Delay(Timeout.InfiniteTimeSpan, stop).ConfigureAwait(false);
                return;
            }
            _log.LogInformation("desktop helper {Build} connected", welcome.Build);
        }
        _loggedWaiting = false;

        var outgoing = Channel.CreateBounded<HelperMessage>(new BoundedChannelOptions(512) { SingleReader = true, FullMode = BoundedChannelFullMode.DropWrite });
        Action<HelperFrame>? capturing;
        lock (_lock)
        {
            _outgoing = outgoing;
            capturing = _onFrame;
        }
        var writer = Task.Run(async () =>
        {
            await foreach (var message in outgoing.Reader.ReadAllAsync(stop).ConfigureAwait(false))
                await channel.SendAsync(message, stop).ConfigureAwait(false);
        }, stop);

        try
        {
            while (await channel.ReadAsync(stop).ConfigureAwait(false) is { } message)
            {
                switch (message)
                {
                    case HelperDesktop desktop:
                        bool changed;
                        lock (_lock)
                        {
                            changed = !_connected || _desktop != desktop.Desktop;
                            _connected = true;
                            _desktop = desktop.Desktop;
                        }
                        if (changed)
                        {
                            _log.LogInformation("input desktop: {Desktop}", desktop.Desktop);
                            Changed?.Invoke();
                        }
                        break;
                    case HelperFrame frame:
                        Action<HelperFrame>? onFrame;
                        lock (_lock) onFrame = _onFrame;
                        onFrame?.Invoke(frame);
                        break;
                    case HelperCaptureStopped stopped:
                        Action<string>? onStopped;
                        lock (_lock) onStopped = _onCaptureStopped;
                        onStopped?.Invoke(stopped.Reason);
                        break;
                    default:
                        throw new InvalidDataException($"unexpected {message.Kind} from the helper");
                }
            }
        }
        finally
        {
            outgoing.Writer.TryComplete();
            try { await writer.ConfigureAwait(false); }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { }
        }
    }

    private void SetDisconnected()
    {
        bool was;
        Action<string>? onStopped;
        lock (_lock)
        {
            was = _connected;
            _connected = false;
            _outgoing = null;
            _desktop = HelperDesktopKind.Default;
            onStopped = _onCaptureStopped;
        }
        if (!was) return;
        _log.LogInformation("desktop helper disconnected");
        onStopped?.Invoke("the desktop helper went away");
        Changed?.Invoke();
    }

    public void Dispose()
    {
        _stop.Cancel();
        _stop.Dispose();
    }

    private sealed class CaptureLease(HelperClient owner, Action<HelperFrame> onFrame) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0) owner.StopCapture(onFrame);
        }
    }
}
