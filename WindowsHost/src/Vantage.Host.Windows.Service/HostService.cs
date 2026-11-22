using System.Diagnostics;
using System.ServiceProcess;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace Vantage.Host.Windows.Service;

/// <summary>
/// The Windows service (LocalSystem). It keeps one desktop helper running, as SYSTEM, in the
/// console session while someone is signed in to it, and none otherwise: nothing runs at the
/// sign-in screen after a restart, so the PC still has to be signed in to once at the PC. A
/// helper that exits is started again, with a growing wait if it keeps failing.
/// </summary>
internal sealed class HostService : ServiceBase
{
    private readonly ILogger _log;
    private readonly ManualResetEvent _stop = new(false);
    private readonly AutoResetEvent _wake = new(false);
    private Thread? _supervisor;

    public HostService(ILoggerFactory logging)
    {
        _log = logging.CreateLogger("Vantage.Service");
        ServiceName = DesktopHelper.HelperInstall.ServiceName;
        CanHandleSessionChangeEvent = true;
        CanShutdown = true;
        CanStop = true;
    }

    protected override void OnStart(string[] args)
    {
        _log.LogInformation("service starting");
        _supervisor = new Thread(Supervise) { IsBackground = true, Name = "Helper supervisor" };
        _supervisor.Start();
    }

    protected override void OnSessionChange(SessionChangeDescription changeDescription)
    {
        _log.LogInformation("session {Session}: {Reason}", changeDescription.SessionId, changeDescription.Reason);
        _wake.Set();
    }

    protected override void OnStop() => Shutdown();

    protected override void OnShutdown() => Shutdown();

    private void Shutdown()
    {
        _stop.Set();
        _supervisor?.Join(TimeSpan.FromSeconds(5));
        _log.LogInformation("service stopped");
    }

    private void Supervise()
    {
        Process? helper = null;
        uint helperSession = 0;
        DateTime startedAt = default, nextStart = default;
        var backoff = TimeSpan.FromSeconds(1);
        var executable = Environment.ProcessPath!;
        try
        {
            while (!_stop.WaitOne(0))
            {
                var wanted = SignedInConsoleSession();
                if (helper is not null && (helper.HasExited || helperSession != wanted))
                {
                    if (!helper.HasExited)
                    {
                        _log.LogInformation("stopping the helper in session {Session}", helperSession);
                        try { helper.Kill(); } catch (InvalidOperationException) { }
                    }
                    else
                    {
                        _log.LogWarning("the helper in session {Session} exited ({Code})", helperSession, helper.ExitCode);
                        // Quick exits back off (a broken key, a session going away); a long run starts over.
                        backoff = DateTime.UtcNow - startedAt < TimeSpan.FromSeconds(10)
                            ? TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromMinutes(1).Ticks))
                            : TimeSpan.FromSeconds(1);
                        nextStart = DateTime.UtcNow + backoff;
                    }
                    helper.Dispose();
                    helper = null;
                }

                if (helper is null && wanted is { } session && DateTime.UtcNow >= nextStart)
                {
                    try
                    {
                        helper = HelperLauncher.Start(session, executable);
                        helperSession = session;
                        startedAt = DateTime.UtcNow;
                        _log.LogInformation("helper started in session {Session} (process {Pid})", session, helper.Id);
                    }
                    catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException)
                    {
                        _log.LogWarning("couldn't start the helper in session {Session}: {Message}", session, ex.Message);
                        backoff = TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromMinutes(1).Ticks));
                        nextStart = DateTime.UtcNow + backoff;
                    }
                }

                WaitHandle.WaitAny([_stop, _wake], TimeSpan.FromSeconds(2));
            }
        }
        finally
        {
            if (helper is { HasExited: false })
            {
                try { helper.Kill(); } catch (InvalidOperationException) { }
            }
            helper?.Dispose();
        }
    }

    /// <summary>The console session if someone is signed in to it, else null.</summary>
    private static uint? SignedInConsoleSession()
    {
        var session = PInvoke.WTSGetActiveConsoleSessionId();
        if (session is 0 or 0xFFFFFFFF) return null;
        HANDLE token = default;
        if (!PInvoke.WTSQueryUserToken(session, ref token)) return null;
        PInvoke.CloseHandle(token);
        return session;
    }
}
