using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Input;
using Vantage.Protocol.Auth;
using Vantage.Protocol.DesktopHelper;
using Vantage.Protocol.Input;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.StationsAndDesktops;
using Windows.Win32.UI.HiDpi;

namespace Vantage.Host.Windows.DesktopHelper;

/// <summary>
/// The desktop helper: Casement Host Service starts it as SYSTEM in the signed-in console session.
/// It serves one pipe (<see cref="HelperPipe.PipeName"/>) that only that session's user (and SYSTEM)
/// may open, proves itself with the key the install made, reports the input desktop, injects the
/// host's input on whichever desktop has it (so it reaches the lock screen, administrator prompts
/// and administrator apps), and captures the secure desktop when asked.
/// </summary>
public sealed class SecureDesktopHelper
{
    private static readonly TimeSpan s_desktopPoll = TimeSpan.FromMilliseconds(200);

    private readonly ILogger _log;
    private readonly uint _session;
    private readonly byte[] _seed;
    private readonly SecurityIdentifier _user;
    private readonly IEd25519 _ed25519 = new NSecEd25519();
    private readonly BlockingCollection<InputAction[]> _input = new(boundedCapacity: 256);
    private readonly Lock _lock = new();
    private HelperDesktopKind _desktop = HelperDesktopKind.Other;
    private Action<HelperDesktopKind>? _desktopChanged;
    private CaptureLoop? _capture;

    private SecureDesktopHelper(ILogger log, uint session, byte[] seed, SecurityIdentifier user)
    {
        _log = log;
        _session = session;
        _seed = seed;
        _user = user;
    }

    /// <summary>Runs until <paramref name="cancellationToken"/> fires; exits with an error code when it can't start.</summary>
    public static async Task<int> RunAsync(ILogger log, CancellationToken cancellationToken)
    {
        PInvoke.SetProcessDpiAwarenessContext(new DPI_AWARENESS_CONTEXT(-4)); // per-monitor v2: physical pixels, as the host
        if (!PInvoke.ProcessIdToSessionId(PInvoke.GetCurrentProcessId(), out var session) || session == 0)
        {
            log.LogError("the desktop helper must run in a user's session");
            return 2;
        }
        if (SessionUser(session) is not { } user)
        {
            log.LogError("nobody is signed in to session {Session}", session);
            return 3;
        }
        byte[] seed;
        try
        {
            seed = HelperInstall.ReadPrivateKey();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.LogError("the helper's key can't be read: {Message}", ex.Message);
            return 4;
        }

        var helper = new SecureDesktopHelper(log, session, seed, user);
        log.LogInformation("desktop helper for session {Session} ({User})", session, user.Value);
        var input = new Thread(helper.InputThread) { IsBackground = true, Name = "Helper input" };
        input.Start();
        var watcher = new Thread(() => helper.WatchDesktop(cancellationToken)) { IsBackground = true, Name = "Helper desktop" };
        watcher.Start();
        try
        {
            await helper.ServeAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        helper._input.CompleteAdding();
        return 0;
    }

    /// <summary>The user signed in to <paramref name="session"/>, or null (needs SYSTEM).</summary>
    public static unsafe SecurityIdentifier? SessionUser(uint session)
    {
        HANDLE token = default;
        if (!PInvoke.WTSQueryUserToken(session, ref token)) return null;
        try
        {
            using var identity = new WindowsIdentity((nint)token.Value);
            return identity.User;
        }
        finally
        {
            PInvoke.CloseHandle(token);
        }
    }

    private async Task ServeAsync(CancellationToken cancellationToken)
    {
        var name = HelperPipe.PipeName(_session);
        while (!cancellationToken.IsCancellationRequested)
        {
            NamedPipeServerStream server;
            try
            {
                server = NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                                                         PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance, 1 << 20, 1 << 20, PipeAcl());
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Someone else holds the name (the host won't trust them: they can't sign). Wait for it to go.
                _log.LogWarning("the pipe {Name} is taken: {Message}", name, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
                continue;
            }

            using (server)
            {
                await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                if (!PInvoke.GetNamedPipeClientSessionId(server.SafePipeHandle, out var clientSession)
                    || clientSession != _session)
                {
                    _log.LogWarning("refused a client from session {Session}", clientSession);
                    continue;
                }
                var program = ClientProgram(server);
                if (program is null || !HostPrograms.Contains(program))
                {
                    // Not a boundary (anything running as the user can start the host), but nothing else has a reason to talk here.
                    _log.LogWarning("refused {Program}: only Casement Host may use the helper", program ?? "an unknown program");
                    continue;
                }
                try
                {
                    await ServeClientAsync(server, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or InvalidDataException or ObjectDisposedException)
                {
                    _log.LogInformation("host connection ended: {Message}", ex.Message);
                }
                finally
                {
                    lock (_lock)
                    {
                        _desktopChanged = null;
                        _capture?.Stop();
                        _capture = null;
                    }
                }
            }
        }
    }

    /// <summary>The programs that are Casement Host (the app and the console host).</summary>
    private static readonly HashSet<string> HostPrograms = new(StringComparer.OrdinalIgnoreCase) { "VantageHost.exe", "VantageHostCli.exe" };

    private static string? ClientProgram(NamedPipeServerStream server)
    {
        if (!PInvoke.GetNamedPipeClientProcessId(server.SafePipeHandle, out var pid)) return null;
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById((int)pid);
            return Path.GetFileName(process.MainModule?.FileName);
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    private PipeSecurity PipeAcl()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl,
                                                  AccessControlType.Allow));
        // Read and write only: not CreateNewInstance, so the user can't add a rogue instance of the name.
        security.AddAccessRule(new PipeAccessRule(_user, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return security;
    }

    private async Task ServeClientAsync(NamedPipeServerStream server, CancellationToken cancellationToken)
    {
        var channel = new HelperChannel(server);
        if (await channel.ReadAsync(cancellationToken).ConfigureAwait(false) is not HelperHello hello)
            throw new InvalidDataException("the host didn't say hello");
        var signature = _ed25519.Sign(_seed, HelperProof.Transcript(_session, hello.Nonce));
        await channel.SendAsync(new HelperWelcome(HelperPipe.Version, BuildName(), signature), cancellationToken).ConfigureAwait(false);
        if (hello.Version != HelperPipe.Version)
        {
            _log.LogWarning("the host speaks version {Theirs}, this helper {Ours}", hello.Version, HelperPipe.Version);
            return;
        }
        _log.LogInformation("host connected");

        // Desktop changes go out in order on one writer, behind any frame being sent.
        var outgoing = new BlockingCollection<HelperMessage>(boundedCapacity: 64);
        var writer = Task.Run(async () =>
        {
            foreach (var message in outgoing.GetConsumingEnumerable(cancellationToken))
            {
                if (message is HelperFrame frame) await channel.SendFrameAsync(frame, cancellationToken).ConfigureAwait(false);
                else await channel.SendAsync(message, cancellationToken).ConfigureAwait(false);
            }
        }, cancellationToken);

        lock (_lock)
        {
            _desktopChanged = desktop => outgoing.TryAdd(new HelperDesktop(desktop));
            outgoing.Add(new HelperDesktop(_desktop), cancellationToken);
        }

        try
        {
            while (await channel.ReadAsync(cancellationToken).ConfigureAwait(false) is { } message)
            {
                switch (message)
                {
                    case HelperInput input:
                        if (!_input.TryAdd(input.Actions)) _log.LogWarning("input backed up; dropped {Count} events", input.Actions.Length);
                        break;
                    case HelperStartCapture start:
                        lock (_lock)
                        {
                            _capture?.Stop();
                            _capture = new CaptureLoop(start.MonitorDevice, start.MaxFps, outgoing, _log);
                        }
                        break;
                    case HelperStopCapture:
                        lock (_lock)
                        {
                            _capture?.Stop();
                            _capture = null;
                        }
                        break;
                    default:
                        throw new InvalidDataException($"unexpected {message.Kind} from the host");
                }
            }
        }
        finally
        {
            outgoing.CompleteAdding();
            try { await writer.ConfigureAwait(false); }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { }
        }
    }

    private static string BuildName() =>
        typeof(SecureDesktopHelper).Assembly.GetName().Version?.ToString(3) ?? "?";

    private void WatchDesktop(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var now = InputDesktop.Kind();
            Action<HelperDesktopKind>? notify = null;
            lock (_lock)
            {
                if (now != _desktop)
                {
                    _desktop = now;
                    notify = _desktopChanged;
                    _log.LogInformation("input desktop: {Desktop}", now);
                }
            }
            notify?.Invoke(now);
            Thread.Sleep(s_desktopPoll);
        }
    }

    private void InputThread()
    {
        using var desktop = new InputDesktop();
        foreach (var batch in _input.GetConsumingEnumerable())
        {
            desktop.Follow();
            var sent = InputBatch.Send(batch);
            if (sent != batch.Length)
                _log.LogWarning("SendInput delivered {Sent} of {Count} events on {Desktop} (error {Error})",
                                sent, batch.Length, desktop.Name, Marshal.GetLastPInvokeError());
        }
    }

    /// <summary>One capture of one monitor on its own thread, following the input desktop.</summary>
    private sealed class CaptureLoop
    {
        private readonly CancellationTokenSource _stop = new();

        public CaptureLoop(string monitorDevice, uint maxFps, BlockingCollection<HelperMessage> outgoing, ILogger log)
        {
            var interval = TimeSpan.FromSeconds(1.0 / Math.Clamp(maxFps, 1u, 60u));
            var thread = new Thread(() => Run(monitorDevice, interval, outgoing, log, _stop.Token)) { IsBackground = true, Name = "Helper capture" };
            thread.Start();
        }

        public void Stop() => _stop.Cancel();

        private static void Run(string monitorDevice, TimeSpan interval, BlockingCollection<HelperMessage> outgoing, ILogger log, CancellationToken stop)
        {
            using var desktop = new InputDesktop();
            DesktopDuplicator? duplicator = null;
            var failingSince = (DateTime?)null;
            var last = DateTime.MinValue;
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    try
                    {
                        if (duplicator is null)
                        {
                            desktop.Follow();
                            duplicator = DesktopDuplicator.Open(monitorDevice, log);
                            log.LogInformation("capturing {Monitor} on {Desktop} at {Width}×{Height}", monitorDevice, desktop.Name, duplicator.Width, duplicator.Height);
                            failingSince = null;
                        }
                        var wait = interval - (DateTime.UtcNow - last);
                        if (wait > TimeSpan.Zero) Thread.Sleep(wait);
                        if (duplicator.Next(100) is { } frame)
                        {
                            last = DateTime.UtcNow;
                            if (!stop.IsCancellationRequested) outgoing.Add(frame, stop);
                        }
                    }
                    catch (DuplicationLostException ex)
                    {
                        duplicator?.Dispose();
                        duplicator = null;
                        failingSince ??= DateTime.UtcNow;
                        log.LogDebug("duplication: {Message}", ex.Message);
                        if (DateTime.UtcNow - failingSince > TimeSpan.FromSeconds(5))
                        {
                            outgoing.TryAdd(new HelperCaptureStopped(ex.Message));
                            return;
                        }
                        Thread.Sleep(100);
                    }
                }
            }
            catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException)
            {
                // Stopped, or the host went away while a frame was queued.
            }
            finally
            {
                duplicator?.Dispose();
            }
        }
    }
}

/// <summary>
/// Keeps the calling thread on whichever desktop has the input (<c>SetThreadDesktop</c>), as SYSTEM
/// may on the secure desktop. The thread must own no windows or hooks.
/// </summary>
internal sealed class InputDesktop : IDisposable
{
    private const uint GenericAll = 0x10000000;
    private HDESK _attached;

    /// <summary>The desktop this thread is on ("Default", "Winlogon").</summary>
    public string Name { get; private set; } = "";

    /// <summary>Which kind of desktop has the input right now.</summary>
    public static HelperDesktopKind Kind()
    {
        var desktop = PInvoke.OpenInputDesktop(0, false, (DESKTOP_ACCESS_FLAGS)GenericAll);
        if (desktop.IsNull) return HelperDesktopKind.Other;
        try
        {
            return KindOf(NameOf(desktop));
        }
        finally
        {
            PInvoke.CloseDesktop(desktop);
        }
    }

    /// <summary>Which kind a desktop name is.</summary>
    public static HelperDesktopKind KindOf(string name) => name.ToLowerInvariant() switch
    {
        "default" => HelperDesktopKind.Default,
        "winlogon" => HelperDesktopKind.Secure,
        _ => HelperDesktopKind.Other,
    };

    /// <summary>Moves this thread to the input desktop if it changed.</summary>
    public void Follow()
    {
        var desktop = PInvoke.OpenInputDesktop(0, false, (DESKTOP_ACCESS_FLAGS)GenericAll);
        if (desktop.IsNull) return;
        var name = NameOf(desktop);
        if ((name == Name && !_attached.IsNull) || !PInvoke.SetThreadDesktop(desktop))
        {
            PInvoke.CloseDesktop(desktop);
            return;
        }
        if (!_attached.IsNull) PInvoke.CloseDesktop(_attached);
        _attached = desktop;
        Name = name;
    }

    private static unsafe string NameOf(HDESK desktop)
    {
        Span<char> name = stackalloc char[64];
        uint needed = 0;
        fixed (char* buffer = name)
        {
            if (!PInvoke.GetUserObjectInformation((HANDLE)desktop.Value, USER_OBJECT_INFORMATION_INDEX.UOI_NAME, buffer,
                                                  (uint)(name.Length * sizeof(char)), &needed))
                return "";
        }
        var end = name.IndexOf('\0');
        return (end >= 0 ? name[..end] : name).ToString();
    }

    public void Dispose()
    {
        // A thread's own desktop can't be closed while it's on it; the thread ends with the handle.
    }
}
