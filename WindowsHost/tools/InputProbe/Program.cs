using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

// InputProbe: prints the mouse and keyboard events Windows delivers, with the injected flags, so
// you can see exactly what Vantage Host sent (the Windows version of scripts/click-target.swift).
//
//   InputProbe            clicks, wheel and keys; pointer moves at most 10 per second
//   InputProbe --moves    every pointer move
//
// Columns: time, event, position or key, then flags:
//   injected       LLMHF_INJECTED / LLKHF_INJECTED (SendInput, any app)
//   low-IL         injected by a lower-integrity process
//   vantage        dwExtraInfo is Vantage Host's tag ("VANT")
//   extended       LLKHF_EXTENDED (E0 scan code)
// Stop with Ctrl+C. Low-level hooks see the desktop of the session they run in, so start it in the
// interactive session (not over SSH).

const nuint VantageTag = 0x56414E54;
var everyMove = args.Contains("--moves");
var lines = new BlockingCollection<string>(4096);
var clock = Stopwatch.StartNew();
long lastMove = -1000;

Console.WriteLine("InputProbe: logging mouse and keyboard (Ctrl+C to stop)");
Console.WriteLine($"virtual screen {Native.GetSystemMetrics(76)},{Native.GetSystemMetrics(77)} " +
                  $"{Native.GetSystemMetrics(78)}×{Native.GetSystemMetrics(79)} px");

var printer = new Thread(() =>
{
    foreach (var line in lines.GetConsumingEnumerable()) Console.WriteLine(line);
}) { IsBackground = true };
printer.Start();

Probe.Report = Report;
var hookThread = new Thread(Probe.Run) { IsBackground = true, Name = "hooks" };
hookThread.Start();

var done = new ManualResetEventSlim();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    done.Set();
};
done.Wait();
Probe.Stop();
lines.CompleteAdding();
printer.Join(500);
return 0;

void Report(string kind, int x, int y, uint data, uint flags, nuint extra, bool isKey, uint vk, uint scan)
{
    var ms = clock.ElapsedMilliseconds;
    if (kind == "move" && !everyMove)
    {
        if (ms - lastMove < 100) return;
        lastMove = ms;
    }
    var tags = new List<string>();
    if (isKey)
    {
        if ((flags & 0x10) != 0) tags.Add("injected");
        if ((flags & 0x02) != 0) tags.Add("low-IL");
        if ((flags & 0x01) != 0) tags.Add("extended");
        if ((flags & 0x20) != 0) tags.Add("alt");
    }
    else
    {
        if ((flags & 0x01) != 0) tags.Add("injected");
        if ((flags & 0x02) != 0) tags.Add("low-IL");
    }
    if (extra == VantageTag) tags.Add("vantage");
    var time = (ms / 1000.0).ToString("0.000", CultureInfo.InvariantCulture);
    var detail = isKey
        ? $"vk 0x{vk:X2} scan 0x{scan:X2}"
        : kind is "wheel" or "hwheel" ? $"{x},{y} delta {(short)(data >> 16)}"
        : kind.StartsWith('x') ? $"{x},{y} button {data >> 16}"
        : $"{x},{y}";
    lines.TryAdd($"{time,9}  {kind,-10} {detail,-26} {string.Join(" ", tags)}");
}

internal static unsafe class Probe
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private static nint s_mouseHook;
    private static nint s_keyboardHook;
    private static uint s_threadId;

    public static Action<string, int, int, uint, uint, nuint, bool, uint, uint> Report { get; set; } = (_, _, _, _, _, _, _, _, _) => { };

    public static void Run()
    {
        s_threadId = Native.GetCurrentThreadId();
        var module = Native.GetModuleHandleW(null);
        s_mouseHook = Native.SetWindowsHookExW(WH_MOUSE_LL, &MouseProc, module, 0);
        s_keyboardHook = Native.SetWindowsHookExW(WH_KEYBOARD_LL, &KeyboardProc, module, 0);
        if (s_mouseHook == 0 || s_keyboardHook == 0)
        {
            Console.Error.WriteLine($"SetWindowsHookEx failed ({Marshal.GetLastPInvokeError()})");
            return;
        }
        Native.MSG message;
        while (Native.GetMessageW(&message, 0, 0, 0) > 0)
        {
        }
        Native.UnhookWindowsHookEx(s_mouseHook);
        Native.UnhookWindowsHookEx(s_keyboardHook);
    }

    public static void Stop() => Native.PostThreadMessageW(s_threadId, 0x0012 /* WM_QUIT */, 0, 0);

    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static nint MouseProc(int code, nuint wParam, nint lParam)
    {
        if (code >= 0)
        {
            var info = (Native.MSLLHOOKSTRUCT*)lParam;
            var kind = (uint)wParam switch
            {
                0x0200 => "move",
                0x0201 => "left↓",
                0x0202 => "left↑",
                0x0204 => "right↓",
                0x0205 => "right↑",
                0x0207 => "middle↓",
                0x0208 => "middle↑",
                0x020A => "wheel",
                0x020B => "x↓",
                0x020C => "x↑",
                0x020E => "hwheel",
                var other => $"0x{other:X4}",
            };
            try { Report(kind, info->x, info->y, info->mouseData, info->flags, info->dwExtraInfo, false, 0, 0); }
            catch { }
        }
        return Native.CallNextHookEx(0, code, wParam, lParam);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static nint KeyboardProc(int code, nuint wParam, nint lParam)
    {
        if (code >= 0)
        {
            var info = (Native.KBDLLHOOKSTRUCT*)lParam;
            var kind = (uint)wParam switch
            {
                0x0100 => "key↓",
                0x0101 => "key↑",
                0x0104 => "syskey↓",
                0x0105 => "syskey↑",
                var other => $"0x{other:X4}",
            };
            try { Report(kind, 0, 0, 0, info->flags, info->dwExtraInfo, true, info->vkCode, info->scanCode); }
            catch { }
        }
        return Native.CallNextHookEx(0, code, wParam, lParam);
    }
}

internal static unsafe class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public int x;
        public int y;
        public uint mouseData;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public nint hwnd;
        public uint message;
        public nuint wParam;
        public nint lParam;
        public uint time;
        public int x;
        public int y;
    }

    [DllImport("user32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern nint SetWindowsHookExW(int hook, delegate* unmanaged[Stdcall]<int, nuint, nint, nint> proc, nint module, uint threadId);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern int UnhookWindowsHookEx(nint hook);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern nint CallNextHookEx(nint hook, int code, nuint wParam, nint lParam);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern int GetMessageW(MSG* message, nint hwnd, uint min, uint max);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern int PostThreadMessageW(uint threadId, uint message, nuint wParam, nint lParam);

    [DllImport("user32.dll", ExactSpelling = true)]
    public static extern int GetSystemMetrics(int index);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern nint GetModuleHandleW(string? name);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    public static extern uint GetCurrentThreadId();
}
