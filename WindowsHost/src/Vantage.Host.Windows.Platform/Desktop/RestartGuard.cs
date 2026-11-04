using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using static Vantage.Host.Windows.Interop.Win32Constants;

namespace Vantage.Host.Windows.Desktop;

/// <summary>Why the Windows session is ending (from <c>WM_ENDSESSION</c>'s lParam).</summary>
public enum SessionEnding
{
    /// <summary>The PC is restarting or shutting down (Windows doesn't say which).</summary>
    Restart,
    /// <summary>The person is signing out (<c>ENDSESSION_LOGOFF</c>).</summary>
    SignOut,
    /// <summary>Only this app is being closed, by an installer or Restart Manager (<c>ENDSESSION_CLOSEAPP</c>).</summary>
    AppClosing,
}

/// <summary>What <see cref="RestartGuard"/> answers to <c>WM_QUERYENDSESSION</c>.</summary>
public enum QueryEndSessionAnswer
{
    /// <summary>Let it go (TRUE).</summary>
    Allow,
    /// <summary>Hold it (FALSE): Windows shows its "This app is preventing restart" screen with the block reason.</summary>
    Block,
}

/// <summary>The pure half of <see cref="RestartGuard"/>: the words and the decisions, so they can be tested.</summary>
public static class RestartGuardPolicy
{
    /// <summary>Windows cuts a block reason at <c>MAX_STR_BLOCKREASON</c> (256 characters, with the terminator).</summary>
    public const int MaxReasonLength = 255;

    private const string Consequence = " It can't reconnect until someone signs in to this PC again.";

    /// <summary>
    /// The text Windows shows under Casement Host on its restart screen, or null when nothing is
    /// connected: "Drew's iPad is connected through Casement Host. …", or "2 devices are connected …".
    /// A name long enough to overflow the limit falls back to the count.
    /// </summary>
    /// <param name="connectedDevices">The devices with a screen session, one entry each.</param>
    public static string? BlockReason(IReadOnlyCollection<string> connectedDevices)
    {
        if (connectedDevices.Count == 0) return null;
        if (connectedDevices.Count == 1)
        {
            var name = connectedDevices.First().Trim();
            var named = $"{(name.Length > 0 ? name : "A device")} is connected through Casement Host.{Consequence}";
            if (named.Length <= MaxReasonLength) return named;
            return $"A device is connected through Casement Host.{Consequence}";
        }
        return $"{connectedDevices.Count} devices are connected through Casement Host. They can't reconnect until someone signs in to this PC again.";
    }

    /// <summary>
    /// Holds a sign-out, restart or shutdown only while the guard is on and a reason is registered,
    /// and never one Windows forces (<c>ENDSESSION_CRITICAL</c>: it ends anyway) or one that only
    /// closes this app (<c>ENDSESSION_CLOSEAPP</c>: an installer waiting on us gains nothing).
    /// </summary>
    /// <param name="enabled">Settings › General's switch.</param>
    /// <param name="hasReason">A block reason is registered (a device is connected).</param>
    /// <param name="lParam"><c>WM_QUERYENDSESSION</c>'s lParam.</param>
    public static QueryEndSessionAnswer Decide(bool enabled, bool hasReason, nint lParam)
    {
        var flags = (uint)(nuint)lParam;
        if (!enabled || !hasReason) return QueryEndSessionAnswer.Allow;
        if ((flags & (ENDSESSION_CRITICAL | ENDSESSION_CLOSEAPP)) != 0) return QueryEndSessionAnswer.Allow;
        return QueryEndSessionAnswer.Block;
    }

    /// <summary>Which kind of ending <c>WM_ENDSESSION</c>'s lParam describes.</summary>
    public static SessionEnding Kind(nint lParam)
    {
        var flags = (uint)(nuint)lParam;
        if ((flags & ENDSESSION_LOGOFF) != 0) return SessionEnding.SignOut;
        if ((flags & ENDSESSION_CLOSEAPP) != 0) return SessionEnding.AppClosing;
        return SessionEnding.Restart;
    }

    /// <summary>How the log names <paramref name="kind"/>.</summary>
    public static string LogName(SessionEnding kind) => kind switch
    {
        SessionEnding.SignOut => "sign-out",
        SessionEnding.AppClosing => "close-app",
        _ => "restart",
    };
}

/// <summary>
/// The Windows counterpart of the Mac host's <c>RestartGuard</c>. Windows won't let an app veto a
/// sign-out, restart or shutdown the way a Mac app can, but while a device is connected the guard
/// registers a block reason (<c>ShutdownBlockReasonCreate</c>) on the host's hidden top-level
/// window and answers <c>WM_QUERYENDSESSION</c> with FALSE, so an interactive restart (Windows
/// Update's included) stops on Windows' "This app is preventing restart" screen, which names
/// Casement Host with that reason; the person at the PC cancels or restarts anyway. A forced
/// restart (<c>shutdown /f</c>, <c>ENDSESSION_CRITICAL</c>) isn't held. When the session does end
/// (<c>WM_ENDSESSION</c> TRUE), <see cref="EndingSession"/> runs so the listener can stop and the
/// app quit. Connections just drop, as on the Mac: a <c>disconnect</c> would stop the iPad
/// retrying, and it should reconnect by itself once the host is back after sign-in.
/// <c>SetProcessShutdownParameters</c> puts the host first in line, so it's asked before the apps
/// the remote person is working in have been told to close.
/// </summary>
public sealed class RestartGuard : IDisposable
{
    /// <summary>How long <c>WM_ENDSESSION</c> waits for <see cref="EndingSession"/>: Windows allows about 5 s.</summary>
    public static readonly TimeSpan EndingTimeout = TimeSpan.FromSeconds(4);

    private readonly MessageWindow _window;
    private readonly ILogger _log;
    private readonly IDisposable _hook;
    // Window thread only (the hook and posted actions).
    private string? _registered;
    private volatile bool _enabled;
    private string? _wanted;
    private bool _disposed;

    /// <param name="window">The host's hidden top-level window (message-only windows never get <c>WM_QUERYENDSESSION</c>).</param>
    /// <param name="enabled">Settings › General › Ask before restarting while a device is connected.</param>
    /// <param name="logging">Loggers (category <c>Vantage.Restart</c>).</param>
    public RestartGuard(MessageWindow window, bool enabled, ILoggerFactory logging)
    {
        _window = window;
        _enabled = enabled;
        _log = logging.CreateLogger("Vantage.Restart");
        if (!PInvoke.SetProcessShutdownParameters(SHUTDOWN_LEVEL_FIRST_APP, 0))
            _log.LogDebug("SetProcessShutdownParameters failed ({Error})", Marshal.GetLastPInvokeError());
        _hook = window.AddHook(OnMessage);
    }

    /// <summary>
    /// Runs on the window thread when the session really ends (after the restart screen, if any).
    /// <c>WM_ENDSESSION</c> waits up to <see cref="EndingTimeout"/> for the returned task, so it
    /// mustn't need the window thread (no <see cref="MessageWindow.Invoke{T}"/>).
    /// </summary>
    public event Func<SessionEnding, Task>? EndingSession;

    /// <summary>Whether a restart is held while a device is connected (the reason is registered only then).</summary>
    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            _log.LogInformation("asking before a restart turned {State}", value ? "on" : "off");
            Apply();
        }
    }

    /// <summary>Registers or clears the block reason for the devices connected now (any thread).</summary>
    /// <param name="connectedDevices">Names of the devices with a screen session.</param>
    public void Update(IReadOnlyCollection<string> connectedDevices)
    {
        var reason = RestartGuardPolicy.BlockReason(connectedDevices);
        Interlocked.Exchange(ref _wanted, reason);
        Apply();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _hook.Dispose();
        try
        {
            _window.Invoke(() =>
            {
                if (_registered is not null) PInvoke.ShutdownBlockReasonDestroy(_window.Hwnd);
                _registered = null;
            });
        }
        catch (InvalidOperationException)
        {
        }
    }

    /// <summary>The reason calls must come from the thread that created the window.</summary>
    private void Apply()
    {
        try
        {
            _window.Post(ApplyOnWindowThread);
        }
        catch (InvalidOperationException)
        {
            // The window is gone (quitting).
        }
    }

    private void ApplyOnWindowThread()
    {
        if (_disposed) return;
        var reason = _enabled ? Volatile.Read(ref _wanted) : null;
        if (reason == _registered) return;
        if (reason is null)
        {
            if (!PInvoke.ShutdownBlockReasonDestroy(_window.Hwnd))
                _log.LogDebug("ShutdownBlockReasonDestroy failed ({Error})", Marshal.GetLastPInvokeError());
            _registered = null;
            _log.LogInformation("restarts no longer held");
            return;
        }
        if (!PInvoke.ShutdownBlockReasonCreate(_window.Hwnd, reason))
        {
            _log.LogWarning("ShutdownBlockReasonCreate failed ({Error})", Marshal.GetLastPInvokeError());
            return;
        }
        _registered = reason;
        _log.LogInformation("holding restarts while a device is connected");
    }

    private bool OnMessage(uint message, nuint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (message == WM_QUERYENDSESSION)
        {
            var answer = RestartGuardPolicy.Decide(_enabled, _registered is not null, lParam);
            var kind = RestartGuardPolicy.Kind(lParam);
            if (answer == QueryEndSessionAnswer.Block)
            {
                _log.LogInformation("held a {Kind} while a device is connected (flags 0x{Flags:X}); Windows asks at the PC", RestartGuardPolicy.LogName(kind), (ulong)(nuint)lParam);
                result = 0; // FALSE
                return true;
            }
            _log.LogInformation("a {Kind} is coming (flags 0x{Flags:X}); not held{Why}", RestartGuardPolicy.LogName(kind), (ulong)(nuint)lParam,
                                _registered is not null ? " (forced, or only this app is closing)" : "");
            return false; // DefWindowProc: TRUE
        }
        if (message == WM_ENDSESSION)
        {
            var kind = RestartGuardPolicy.Kind(lParam);
            if (wParam == 0)
            {
                _log.LogInformation("the {Kind} was cancelled", RestartGuardPolicy.LogName(kind));
                return false;
            }
            _log.LogInformation("the Windows session is ending ({Kind}); stopping the listener", RestartGuardPolicy.LogName(kind));
            RunEndingSession(kind);
            return false;
        }
        return false;
    }

    private void RunEndingSession(SessionEnding kind)
    {
        if (EndingSession is not { } handlers) return;
        var tasks = new List<Task>();
        foreach (var handler in handlers.GetInvocationList().Cast<Func<SessionEnding, Task>>())
        {
            try { tasks.Add(handler(kind)); }
            catch (Exception ex) { _log.LogWarning(ex, "stopping for the session end failed"); }
        }
        try
        {
            // Windows may end the process as soon as this returns, so wait (but not past its patience).
            if (!Task.WhenAll(tasks).Wait(EndingTimeout)) _log.LogWarning("the listener didn't stop within {Timeout}", EndingTimeout);
        }
        catch (AggregateException ex)
        {
            _log.LogWarning(ex.GetBaseException(), "stopping for the session end failed");
        }
    }
}
