using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Microsoft.Win32;
using Vantage.Host.Windows.Desktop;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;
using static Vantage.Host.Windows.Interop.Win32Constants;
using static Vantage.Host.Windows.Tray.NotifyIconNative;

namespace Vantage.Host.Windows.Tray;

/// <summary>
/// The notification-area icon, native Windows 11 style (plan §1): <c>NOTIFYICON_VERSION_4</c>;
/// a display glyph (an arrow into it while an iPad is connected) in white on a dark taskbar and
/// near-black on a light one, swapped on <c>WM_SETTINGCHANGE("ImmersiveColorSet")</c>; the standard
/// tooltip (<c>NIF_SHOWTIP</c>); left click / Enter (<c>NIN_SELECT</c>/<c>NIN_KEYSELECT</c>) raises
/// <see cref="OpenRequested"/>; right click / Shift+F10 (<c>WM_CONTEXTMENU</c>) shows a Win32 popup
/// menu (<c>SetForegroundWindow</c> first and <c>WM_NULL</c> after, so it closes when you click away),
/// dark when apps are dark (uxtheme ordinals 135/136, guarded); re-added on <c>TaskbarCreated</c>
/// after Explorer restarts. Everything runs on the <see cref="MessageWindow"/> thread; events are
/// raised there too.
/// </summary>
public sealed unsafe class TrayIcon : IDisposable
{
    private const uint IconId = 1;
    private const uint CallbackMessage = WM_APP + 1;
    private const int SM_CXSMICON = 49;
    private const int SM_MENUDROPALIGNMENT = 40;

    private readonly MessageWindow _window;
    private readonly ILogger _log;
    private readonly uint _taskbarCreated;
    private readonly IDisposable _hook;
    private readonly Dictionary<string, HICON> _icons = [];
    private TrayState _state;
    private bool _added;
    private bool _disposed;

    /// <param name="window">The host's message window.</param>
    /// <param name="initial">What to show first.</param>
    /// <param name="logging">Loggers (category <c>Vantage.Tray</c>).</param>
    public TrayIcon(MessageWindow window, TrayState initial, ILoggerFactory logging)
    {
        _window = window;
        _log = logging.CreateLogger("Vantage.Tray");
        _state = initial;
        _taskbarCreated = PInvoke.RegisterWindowMessage("TaskbarCreated");
        _hook = window.AddHook(OnMessage);
        window.Invoke(() =>
        {
            DarkMenus.Enable(_log);
            Add();
        });
    }

    /// <summary>Left click on the icon (or Enter on it): open or focus the settings window.</summary>
    public event Action? OpenRequested;

    /// <summary>A menu command was chosen.</summary>
    public event Action<TrayCommand>? CommandInvoked;

    /// <summary>Shows a new state (any thread).</summary>
    public void Update(TrayState state)
    {
        _window.Post(() =>
        {
            _state = state;
            if (_added) Modify();
            else Add();
        });
    }

    /// <summary>Removes the icon.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            _window.Invoke(() =>
            {
                var data = Data(0);
                Shell_NotifyIcon(NIM_DELETE, &data);
                foreach (var icon in _icons.Values) PInvoke.DestroyIcon(icon);
                _icons.Clear();
            });
        }
        catch (InvalidOperationException)
        {
        }
        _hook.Dispose();
    }

    private bool OnMessage(uint message, nuint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (message == CallbackMessage)
        {
            var notification = (uint)(lParam & 0xFFFF);
            switch (notification)
            {
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    OpenRequested?.Invoke();
                    break;
                case WM_CONTEXTMENU:
                    // NOTIFYICON_VERSION_4: the anchor point is in wParam (x low word, y high word, signed).
                    ShowMenu((short)(wParam & 0xFFFF), (short)((wParam >> 16) & 0xFFFF));
                    break;
            }
            return true;
        }
        if (message == _taskbarCreated && _taskbarCreated != 0)
        {
            _log.LogInformation("Explorer restarted; adding the tray icon again");
            _added = false;
            Add();
            return false;
        }
        if (message == WM_SETTINGCHANGE && lParam != 0 && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            DarkMenus.Refresh();
            if (_added) Modify();
            return false;
        }
        if (message is WM_DPICHANGED or WM_DISPLAYCHANGE)
        {
            foreach (var icon in _icons.Values) PInvoke.DestroyIcon(icon);
            _icons.Clear();
            if (_added) Modify();
        }
        return false;
    }

    private void Add()
    {
        if (_disposed) return;
        var data = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        if (Shell_NotifyIcon(NIM_ADD, &data) == 0)
        {
            // Explorer isn't up yet (starting at login): TaskbarCreated will bring us back.
            _log.LogInformation("Shell_NotifyIcon(NIM_ADD) failed; waiting for the taskbar");
            return;
        }
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIcon(NIM_SETVERSION, &data);
        _added = true;
    }

    private void Modify()
    {
        var data = Data(NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        if (Shell_NotifyIcon(NIM_MODIFY, &data) == 0)
        {
            _added = false;
            Add();
        }
    }

    private NOTIFYICONDATAW Data(uint flags)
    {
        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = _window.Handle,
            uID = IconId,
            uFlags = flags,
            uCallbackMessage = CallbackMessage,
        };
        if ((flags & NIF_ICON) != 0) data.hIcon = (nint)CurrentIcon().Value;
        if ((flags & NIF_TIP) != 0) Copy(TrayMenuModel.Tooltip(_state), data.szTip);
        return data;
    }

    private HICON CurrentIcon()
    {
        var name = $"tray-{(_state.Clients.Count > 0 ? "connected" : "idle")}-{(TaskbarIsLight() ? "light" : "dark")}.ico";
        if (_icons.TryGetValue(name, out var cached)) return cached;
        var size = PInvoke.GetSystemMetricsForDpi((SYSTEM_METRICS_INDEX)SM_CXSMICON, PInvoke.GetDpiForSystem());
        var icon = LoadEmbeddedIcon(name, size > 0 ? size : 16);
        _icons[name] = icon;
        return icon;
    }

    private HICON LoadEmbeddedIcon(string name, int size)
    {
        using var stream = typeof(TrayIcon).Assembly.GetManifestResourceStream("Vantage.Host.Windows.Tray.Icons." + name);
        if (stream is null)
        {
            _log.LogWarning("missing embedded icon {Name}", name);
            return default;
        }
        var bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        var entry = IconDirectory.Pick(IconDirectory.Read(bytes), size);
        if (entry is null) return default;
        fixed (byte* pointer = bytes)
        {
            return PInvoke.CreateIconFromResourceEx(pointer + entry.Value.Offset, (uint)entry.Value.Length, true, 0x00030000,
                                                    size, size, IMAGE_FLAGS.LR_DEFAULTCOLOR);
        }
    }

    /// <summary>The taskbar follows the "Windows mode" (<c>SystemUsesLightTheme</c>), not the app mode.</summary>
    private static bool TaskbarIsLight()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void ShowMenu(int x, int y)
    {
        var items = TrayMenuModel.Build(_state);
        var menu = PInvoke.CreatePopupMenu();
        try
        {
            var commands = new Dictionary<uint, TrayCommand>();
            uint nextId = 1;
            foreach (var item in items)
            {
                if (item.IsSeparator)
                {
                    PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, (PCWSTR)null);
                    continue;
                }
                var flags = MENU_ITEM_FLAGS.MF_STRING | (item.IsEnabled ? 0 : MENU_ITEM_FLAGS.MF_GRAYED);
                var id = nextId++;
                commands[id] = item.Command;
                fixed (char* text = TrayMenuModel.MenuText(item.Text)) PInvoke.AppendMenu(menu, flags, id, text);
            }

            // Without this the menu stays open when you click elsewhere (KB135788).
            PInvoke.SetForegroundWindow(_window.Hwnd);
            var align = PInvoke.GetSystemMetrics((SYSTEM_METRICS_INDEX)SM_MENUDROPALIGNMENT) != 0 ? TPM_RIGHTALIGN : 0;
            var chosen = PInvoke.TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | align, x, y, _window.Hwnd, null);
            PInvoke.PostMessage(_window.Hwnd, WM_NULL, default, default);
            if (chosen != 0 && commands.TryGetValue((uint)chosen.Value, out var command) && command.Kind != TrayCommandKind.None)
                CommandInvoked?.Invoke(command);
        }
        finally
        {
            PInvoke.DestroyMenu(menu);
        }
    }

    /// <summary>
    /// Dark Win32 popup menus: uxtheme's undocumented <c>SetPreferredAppMode</c> (ordinal 135,
    /// Windows 10 1903+) with AllowDark, then <c>FlushMenuThemes</c> (136). Guarded by build number
    /// and a null check, so a future Windows without them just keeps light menus.
    /// </summary>
    private static class DarkMenus
    {
        private const int AllowDark = 1;
        private static delegate* unmanaged[Stdcall]<int, int> s_setPreferredAppMode;
        private static delegate* unmanaged[Stdcall]<void> s_flushMenuThemes;

        public static void Enable(ILogger log)
        {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 18362)) return;
            try
            {
                var uxtheme = LoadLibraryEx("uxtheme.dll", 0, 0x00000800 /* LOAD_LIBRARY_SEARCH_SYSTEM32 */);
                if (uxtheme == 0) return;
                s_setPreferredAppMode = (delegate* unmanaged[Stdcall]<int, int>)GetProcAddress(uxtheme, 135);
                s_flushMenuThemes = (delegate* unmanaged[Stdcall]<void>)GetProcAddress(uxtheme, 136);
                if (s_setPreferredAppMode != null) s_setPreferredAppMode(AllowDark);
                Refresh();
            }
            catch (Exception ex)
            {
                log.LogDebug("dark menus unavailable: {Message}", ex.Message);
            }
        }

        public static void Refresh()
        {
            if (s_flushMenuThemes != null) s_flushMenuThemes();
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, EntryPoint = "LoadLibraryExW")]
        private static extern nint LoadLibraryEx(string name, nint file, uint flags);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern nint GetProcAddress(nint module, nint ordinal);
    }
}
