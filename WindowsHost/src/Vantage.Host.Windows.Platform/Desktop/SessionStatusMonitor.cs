using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Power;
using Windows.Win32.System.RemoteDesktop;
using Windows.Win32.System.StationsAndDesktops;
using Windows.Win32.UI.WindowsAndMessaging;
using static Vantage.Host.Windows.Interop.Win32Constants;

namespace Vantage.Host.Windows.Desktop;

/// <summary>
/// <see cref="IHostStatusSource"/> for Windows (spec §8): session lock from
/// <c>WTSRegisterSessionNotification</c> (initial state from <c>WTSQuerySessionInformation(WTSSessionInfoEx)</c>),
/// the secure desktop from polling <c>OpenInputDesktop</c> once a second while watched (fails, or
/// isn't "Default"), and display power from <c>RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)</c>.
/// </summary>
public sealed class SessionStatusMonitor : IHostStatusSource, IDisposable
{
    /// <summary>Banner text while locked.</summary>
    public const string LockedMessage = "The PC is locked";

    /// <summary>Banner text while the secure desktop is up.</summary>
    public const string SecureDesktopMessage = "A Windows security prompt is open on the PC";

    private readonly MessageWindow _window;
    private readonly ILogger _log;
    private readonly Lock _lock = new();
    private readonly List<Action> _watchers = [];
    private readonly IDisposable _hook;
    private HPOWERNOTIFY _powerNotification;
    private Timer? _poll;
    private bool _locked;
    private bool _secureDesktop;
    private bool _displayOff;

    /// <param name="window">The host's message window (receives the notifications).</param>
    /// <param name="logging">Loggers (category <c>Vantage.Status</c>).</param>
    public SessionStatusMonitor(MessageWindow window, ILoggerFactory logging)
    {
        _window = window;
        _log = logging.CreateLogger("Vantage.Status");
        _locked = QueryLocked();
        _hook = window.AddHook(OnMessage);
        window.Invoke(Register);
    }

    /// <inheritdoc />
    public HostConditions Current
    {
        get
        {
            bool poll;
            lock (_lock) poll = _watchers.Count == 0;
            if (poll) UpdateSecureDesktop(notify: false);
            lock (_lock) return Conditions();
        }
    }

    /// <inheritdoc />
    public IDisposable Watch(Action onChanged)
    {
        lock (_lock)
        {
            _watchers.Add(onChanged);
            _poll ??= new Timer(_ => UpdateSecureDesktop(notify: true), null, TimeSpan.Zero, TimeSpan.FromSeconds(1));
        }
        return new Unwatch(this, onChanged);
    }

    /// <inheritdoc />
    public void Dispose()
    {
        lock (_lock)
        {
            _poll?.Dispose();
            _poll = null;
        }
        try
        {
            _window.Invoke(() =>
            {
                PInvoke.WTSUnRegisterSessionNotification(_window.Hwnd);
                if (!_powerNotification.IsNull) PInvoke.UnregisterPowerSettingNotification(_powerNotification);
            });
        }
        catch (InvalidOperationException)
        {
        }
        _hook.Dispose();
    }

    private HostConditions Conditions()
    {
        var secure = _secureDesktop && !_locked;
        var message = _locked ? LockedMessage : secure ? SecureDesktopMessage : null;
        return new HostConditions(_locked, secure, _displayOff, message);
    }

    private unsafe void Register()
    {
        if (!PInvoke.WTSRegisterSessionNotification(_window.Hwnd, NOTIFY_FOR_THIS_SESSION))
            _log.LogWarning("WTSRegisterSessionNotification failed ({Error})", Marshal.GetLastPInvokeError());
        var guid = PInvoke.GUID_CONSOLE_DISPLAY_STATE;
        _powerNotification = PInvoke.RegisterPowerSettingNotification((HANDLE)(nint)_window.Handle, &guid,
                                                                      REGISTER_NOTIFICATION_FLAGS.DEVICE_NOTIFY_WINDOW_HANDLE);
        if (_powerNotification.IsNull)
            _log.LogWarning("RegisterPowerSettingNotification failed ({Error})", Marshal.GetLastPInvokeError());
    }

    private unsafe bool OnMessage(uint message, nuint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (message == WM_WTSSESSION_CHANGE)
        {
            if (wParam == WTS_SESSION_LOCK) Set(ref _locked, true, "locked");
            else if (wParam == WTS_SESSION_UNLOCK) Set(ref _locked, false, "unlocked");
            return false;
        }
        if (message == WM_POWERBROADCAST && wParam == PBT_POWERSETTINGCHANGE && lParam != 0)
        {
            var setting = (POWERBROADCAST_SETTING*)lParam;
            if (setting->PowerSetting == PInvoke.GUID_CONSOLE_DISPLAY_STATE && setting->DataLength >= 4)
            {
                var state = *(uint*)&setting->Data; // 0 off, 1 on, 2 dimmed
                Set(ref _displayOff, state == 0, state == 0 ? "display off" : "display on");
            }
            result = 1;
            return true;
        }
        return false;
    }

    private void Set(ref bool field, bool value, string what)
    {
        Action[] watchers;
        lock (_lock)
        {
            if (field == value) return;
            field = value;
            watchers = [.. _watchers];
        }
        _log.LogInformation("{What}", what);
        foreach (var watcher in watchers) watcher();
    }

    private void UpdateSecureDesktop(bool notify)
    {
        var secure = IsInputDesktopSecure();
        if (!notify)
        {
            lock (_lock) _secureDesktop = secure;
            return;
        }
        Set(ref _secureDesktop, secure, secure ? "secure desktop up" : "secure desktop gone");
    }

    /// <summary>True when the input desktop can't be opened or isn't "Default" (UAC, Ctrl+Alt+Del, lock screen).</summary>
    private static unsafe bool IsInputDesktopSecure()
    {
        var desktop = PInvoke.OpenInputDesktop(0, false, DESKTOP_ACCESS_FLAGS.DESKTOP_READOBJECTS);
        if (desktop.IsNull) return true;
        try
        {
            Span<char> name = stackalloc char[64];
            uint needed = 0;
            fixed (char* buffer = name)
            {
                if (!PInvoke.GetUserObjectInformation((HANDLE)desktop.Value, USER_OBJECT_INFORMATION_INDEX.UOI_NAME, buffer,
                                                      (uint)(name.Length * sizeof(char)), &needed))
                    return false;
            }
            var end = name.IndexOf('\0');
            var text = (end >= 0 ? name[..end] : name).ToString();
            return !string.Equals(text, "Default", StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            PInvoke.CloseDesktop(desktop);
        }
    }

    private unsafe bool QueryLocked()
    {
        if (!PInvoke.ProcessIdToSessionId(PInvoke.GetCurrentProcessId(), out var sessionId)) return false;
        PWSTR buffer;
        uint bytes;
        if (!PInvoke.WTSQuerySessionInformation(HANDLE.Null, sessionId, WTS_INFO_CLASS.WTSSessionInfoEx, &buffer, &bytes)) return false;
        try
        {
            if (bytes < sizeof(WTSINFOEXW)) return false;
            var info = (WTSINFOEXW*)buffer.Value;
            if (info->Level != 1) return false;
            return info->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK;
        }
        catch (Exception ex)
        {
            _log.LogDebug("WTSSessionInfoEx: {Message}", ex.Message);
            return false;
        }
        finally
        {
            PInvoke.WTSFreeMemory(buffer.Value);
        }
    }

    private void StopWatching(Action watcher)
    {
        lock (_lock)
        {
            if (!_watchers.Remove(watcher) || _watchers.Count > 0) return;
            _poll?.Dispose();
            _poll = null;
        }
    }

    private sealed class Unwatch(SessionStatusMonitor owner, Action watcher) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0) owner.StopWatching(watcher);
        }
    }
}
