using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Host.Windows.Desktop;

/// <summary>
/// Curtain on Windows: one opaque black topmost window over the whole virtual screen, marked
/// <c>WDA_EXCLUDEFROMCAPTURE</c> so Windows Graphics Capture sees the desktop underneath, and
/// click-through so the host's own input reaches what's under it. Low-level hooks drop input that
/// isn't injected. Unlike a Mac, a locked PC can't be unlocked from a device (the secure desktop is
/// out of reach), so the curtain stays up with nobody connected, ready for the next connection, and
/// comes down when the PC locks: Windows-L (or Ctrl+Alt+Del's Lock) is how someone at the PC gets
/// it back, and the lock screen is what they then see. If the host dies, <see cref="CurtainGuard"/>
/// locks the PC. The hooks get nothing while an elevated window is in front unless the host is
/// elevated too.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed unsafe class ScreenCurtain : IScreenCurtain, IDisposable
{
    private const string Message = "This PC is in use remotely. To use it here, press Windows-L and sign in.";
    private const uint WM_DESTROY = 0x0002, WM_PAINT = 0x000F, WM_CLOSE = 0x0010, WM_ERASEBKGND = 0x0014, WM_MOUSEACTIVATE = 0x0021,
        WM_NCHITTEST = 0x0084, WM_TIMER = 0x0113, WM_DISPLAYCHANGE = 0x007E, WM_WTSSESSION_CHANGE = 0x02B1;
    private const nuint WTS_SESSION_LOCK = 7;
    private const uint WS_POPUP = 0x80000000, WS_EX_TOPMOST = 0x8, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20;
    private const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    private const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1;
    private const int HTTRANSPARENT = -1, MA_NOACTIVATE = 3, WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    private const uint LLKHF_INJECTED = 0x10, LLMHF_INJECTED = 0x1, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    private const int VK_L = 0x4C, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    private static ScreenCurtain? s_current;
    private static readonly WndProc s_wndProc = WindowProc;
    private static readonly HookProc s_keyboardProc = KeyboardProc;
    private static readonly HookProc s_mouseProc = MouseProc;

    private readonly ILogger _log;
    private readonly IDisposable _lockHook;
    private readonly Lock _lock = new();
    private readonly Dictionary<Guid, Action<CurtainStatus>> _holders = [];
    private Thread? _thread;
    private nint _hwnd;
    private Process? _guard;
    private bool _winHeld;

    /// <param name="window">The host's message window, whose session notifications say when the PC locks.</param>
    /// <param name="logging">Loggers (category <c>Vantage.Curtain</c>).</param>
    public ScreenCurtain(MessageWindow window, ILoggerFactory logging)
    {
        _log = logging.CreateLogger("Vantage.Curtain");
        _lockHook = window.AddHook((uint message, nuint wParam, nint lParam, out nint result) =>
        {
            result = 0;
            if (message == WM_WTSSESSION_CHANGE && wParam == WTS_SESSION_LOCK) LowerBecauseLocked();
            return false;
        });
    }

    /// <summary>Whether the curtain is up now.</summary>
    public bool IsUp
    {
        get
        {
            lock (_lock) return _thread is not null;
        }
    }

    /// <inheritdoc />
    public string? Set(bool wanted, Guid owner, Action<CurtainStatus> notify)
    {
        lock (_lock)
        {
            if (!wanted)
            {
                _holders.Remove(owner);
                if (_holders.Count == 0) LowerLocked();
                return null;
            }
            if (_thread is null && RaiseLocked() is { } problem) return problem;
            _holders[owner] = notify;
            return null;
        }
    }

    /// <inheritdoc />
    public bool Adopt(Guid owner, Action<CurtainStatus> notify)
    {
        lock (_lock)
        {
            if (_thread is null) return false;
            _holders[owner] = notify;
            return true;
        }
    }

    /// <inheritdoc />
    public void SessionEnded(Guid owner)
    {
        lock (_lock) _holders.Remove(owner);
    }

    /// <summary>The host is quitting: the lock screen comes first, so nothing shows the desktop.</summary>
    public void Dispose()
    {
        lock (_lock)
        {
            if (_thread is not null)
            {
                LockWorkStation();
                Thread.Sleep(500);
                LowerLocked();
            }
        }
        _lockHook.Dispose();
    }

    private void LowerBecauseLocked()
    {
        Action<CurtainStatus>[] notify;
        lock (_lock)
        {
            if (_thread is null) return;
            _log.LogInformation("the PC locked; lifting the curtain");
            notify = [.. _holders.Values];
            _holders.Clear();
            LowerLocked();
        }
        foreach (var holder in notify) holder(new CurtainStatus { IsUp = false });
    }

    private string? RaiseLocked()
    {
        string? problem = null;
        using var ready = new ManualResetEventSlim();
        var thread = new Thread(() => Run(ref problem, ready)) { IsBackground = true, Name = "Vantage curtain" };
        s_current = this;
        thread.Start();
        ready.Wait();
        if (problem is not null)
        {
            _log.LogError("couldn't raise the curtain: {Problem}", problem);
            thread.Join(1000);
            return "Casement Host couldn't black out this PC's screen.";
        }
        _thread = thread;
        _guard = CurtainGuard.Start(_log);
        _log.LogInformation("curtain up");
        return null;
    }

    private void LowerLocked()
    {
        if (_thread is not { } thread) return;
        PostMessageW(_hwnd, WM_CLOSE, 0, 0);
        thread.Join(2000);
        _thread = null;
        _hwnd = 0;
        try
        {
            _guard?.Kill();
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _log.LogDebug("the guard had already gone: {Error}", error.Message);
        }
        _guard?.Dispose();
        _guard = null;
        _log.LogInformation("curtain down");
    }

    private void Run(ref string? problem, ManualResetEventSlim ready)
    {
        nint keyboard = 0, mouse = 0;
        try
        {
            var module = GetModuleHandleW(null);
            var className = "VantageHost.Curtain." + Guid.NewGuid().ToString("N");
            nint hwnd;
            fixed (char* name = className)
            {
                var wc = new WNDCLASSEXW
                {
                    cbSize = (uint)sizeof(WNDCLASSEXW),
                    lpfnWndProc = Marshal.GetFunctionPointerForDelegate(s_wndProc),
                    hInstance = module,
                    lpszClassName = name,
                };
                if (RegisterClassExW(&wc) == 0) throw new InvalidOperationException($"RegisterClassEx {Marshal.GetLastPInvokeError()}");
                hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT, name, name, WS_POPUP, 0, 0, 0, 0, 0, 0, module, 0);
            }
            if (hwnd == 0) throw new InvalidOperationException($"CreateWindowEx {Marshal.GetLastPInvokeError()}");
            _hwnd = hwnd;
            SetLayeredWindowAttributes(hwnd, 0, 255, 2); // LWA_ALPHA, opaque
            // Before it's shown: if the picture can't leave it out, it mustn't appear at all.
            if (!SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)) throw new InvalidOperationException($"SetWindowDisplayAffinity {Marshal.GetLastPInvokeError()}");
            CoverEverything(hwnd);
            SetTimer(hwnd, 1, 1000, 0); // other topmost windows come and go; stay above them
            keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, Marshal.GetFunctionPointerForDelegate(s_keyboardProc), module, 0);
            mouse = SetWindowsHookExW(WH_MOUSE_LL, Marshal.GetFunctionPointerForDelegate(s_mouseProc), module, 0);
            if (keyboard == 0 || mouse == 0) throw new InvalidOperationException($"SetWindowsHookEx {Marshal.GetLastPInvokeError()}");
        }
        catch (Exception error)
        {
            problem = error.Message;
            if (_hwnd != 0) DestroyWindow(_hwnd);
            ready.Set();
            return;
        }
        ready.Set();
        MSG msg;
        while (GetMessageW(&msg, 0, 0, 0) > 0)
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        UnhookWindowsHookEx(keyboard);
        UnhookWindowsHookEx(mouse);
    }

    private static void CoverEverything(nint hwnd)
    {
        SetWindowPos(hwnd, -1, GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79), SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    private static nint WindowProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case WM_NCHITTEST: return HTTRANSPARENT;
            case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
            case WM_ERASEBKGND: return 1;
            case WM_TIMER:
                SetWindowPos(hwnd, -1, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                return 0;
            case WM_DISPLAYCHANGE:
                CoverEverything(hwnd);
                return 0;
            case WM_PAINT:
                Paint(hwnd);
                return 0;
            case WM_CLOSE:
                DestroyWindow(hwnd);
                return 0;
            case WM_DESTROY:
                PostQuitMessage(0);
                return 0;
            default:
                return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }

    private static void Paint(nint hwnd)
    {
        PAINTSTRUCT paint;
        var dc = BeginPaint(hwnd, &paint);
        RECT client;
        GetClientRect(hwnd, &client);
        var black = GetStockObject(4); // BLACK_BRUSH
        FillRect(dc, &client, black);
        // The primary monitor sits at (0, 0) in virtual-screen coordinates.
        var primary = new RECT { left = -GetSystemMetrics(76), top = -GetSystemMetrics(77) };
        primary.right = primary.left + GetSystemMetrics(0);
        primary.bottom = primary.top + GetSystemMetrics(1);
        SetBkMode(dc, 1); // TRANSPARENT
        SetTextColor(dc, 0x737373);
        var font = CreateFontW(-(int)(GetDpiForWindow(hwnd) * 18 / 96), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        var old = SelectObject(dc, font);
        fixed (char* text = Message) DrawTextW(dc, text, -1, &primary, 0x25); // DT_CENTER | DT_VCENTER | DT_SINGLELINE
        SelectObject(dc, old);
        DeleteObject(font);
        EndPaint(hwnd, &paint);
    }

    private static nint KeyboardProc(int code, nuint wParam, nint lParam)
    {
        if (code >= 0)
        {
            var key = (KBDLLHOOKSTRUCT*)lParam;
            if ((key->flags & LLKHF_INJECTED) == 0)
            {
                // Windows-L is the way back, whether or not Windows would act on it with these
                // keys dropped. Everything else from the physical keyboard goes nowhere.
                var down = wParam is WM_KEYDOWN or WM_SYSKEYDOWN;
                var up = wParam is WM_KEYUP or WM_SYSKEYUP;
                if (s_current is { } curtain)
                {
                    if (key->vkCode is VK_LWIN or VK_RWIN && (down || up)) curtain._winHeld = down;
                    else if (key->vkCode == VK_L && down && curtain._winHeld) LockWorkStation();
                }
                return 1;
            }
        }
        return CallNextHookEx(0, code, wParam, lParam);
    }

    private static nint MouseProc(int code, nuint wParam, nint lParam)
    {
        if (code >= 0 && (((MSLLHOOKSTRUCT*)lParam)->flags & LLMHF_INJECTED) == 0) return 1;
        return CallNextHookEx(0, code, wParam, lParam);
    }

    private delegate nint WndProc(nint hwnd, uint message, nuint wParam, nint lParam);
    private delegate nint HookProc(int code, nuint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASSEXW
    {
        public uint cbSize, style;
        public nint lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public nint hInstance, hIcon, hCursor, hbrBackground;
        public char* lpszMenuName, lpszClassName;
        public nint hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MSG { public nint hwnd; public uint message; public nuint wParam; public nint lParam; public uint time; public POINT pt; public uint lPrivate; }
    [StructLayout(LayoutKind.Sequential)] private struct PAINTSTRUCT { public nint hdc; public int fErase; public RECT rcPaint; public int fRestore, fIncUpdate; public fixed byte rgbReserved[32]; }
    [StructLayout(LayoutKind.Sequential)] private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public nuint dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public nuint dwExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)] private static extern ushort RegisterClassExW(WNDCLASSEXW* wc);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint CreateWindowExW(uint exStyle, char* className, char* title, uint style, int x, int y, int w, int h, nint parent, nint menu, nint instance, nint param);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern nint DefWindowProcW(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(nint hwnd, uint key, byte alpha, uint flags);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] private static extern nuint SetTimer(nint hwnd, nuint id, uint ms, nint proc);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint SetWindowsHookExW(int id, nint proc, nint module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] private static extern nint CallNextHookEx(nint hook, int code, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern int GetMessageW(MSG* msg, nint hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(MSG* msg);
    [DllImport("user32.dll")] private static extern nint DispatchMessageW(MSG* msg);
    [DllImport("user32.dll")] private static extern bool PostMessageW(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern nint BeginPaint(nint hwnd, PAINTSTRUCT* paint);
    [DllImport("user32.dll")] private static extern bool EndPaint(nint hwnd, PAINTSTRUCT* paint);
    [DllImport("user32.dll")] private static extern bool GetClientRect(nint hwnd, RECT* rect);
    [DllImport("user32.dll")] private static extern int FillRect(nint dc, RECT* rect, nint brush);
    [DllImport("user32.dll")] private static extern int DrawTextW(nint dc, char* text, int length, RECT* rect, uint format);
    [DllImport("user32.dll")] internal static extern bool LockWorkStation();
    [DllImport("gdi32.dll")] private static extern nint GetStockObject(int id);
    [DllImport("gdi32.dll")] private static extern int SetBkMode(nint dc, int mode);
    [DllImport("gdi32.dll")] private static extern uint SetTextColor(nint dc, uint color);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern nint CreateFontW(int height, int width, int escapement, int orientation, int weight, uint italic, uint underline, uint strikeOut, uint charSet, uint outPrecision, uint clipPrecision, uint quality, uint pitch, string face);
    [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint obj);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandleW(string? name);
}

/// <summary>
/// A second copy of the host that does one thing: if the host dies with the curtain up, its window
/// and hooks die with it and the desktop would show, so this locks the PC instead. The host kills
/// it when the curtain comes down normally.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public static class CurtainGuard
{
    /// <summary>The command line that makes a process the guard.</summary>
    public const string Flag = "--curtain-guard";

    /// <summary>Waits for the host to exit, then locks the PC.</summary>
    public static int Run(string hostProcessId)
    {
        if (!int.TryParse(hostProcessId, out var id)) return 1;
        try
        {
            using var host = Process.GetProcessById(id);
            host.WaitForExit();
        }
        catch (ArgumentException)
        {
            // It's already gone.
        }
        ScreenCurtain.LockWorkStation();
        return 0;
    }

    internal static Process? Start(ILogger log)
    {
        try
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add(Flag);
            start.ArgumentList.Add(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
            return Process.Start(start);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            log.LogError("couldn't start the guard: {Error}", error.Message);
            return null;
        }
    }
}
