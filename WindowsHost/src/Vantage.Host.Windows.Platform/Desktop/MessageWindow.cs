using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;
using static Vantage.Host.Windows.Interop.Win32Constants;

namespace Vantage.Host.Windows.Desktop;

/// <summary>Handles one window message; return true (and set <paramref name="result"/>) to consume it.</summary>
public delegate bool MessageHook(uint message, nuint wParam, nint lParam, out nint result);

/// <summary>
/// A hidden top-level window on its own thread with a message loop: the host's Win32 anchor for
/// the tray icon, the clipboard listener, WTS session notifications, power-setting notifications
/// and <c>SC_MONITORPOWER</c>. It is a real (never shown) top-level window rather than a
/// message-only one because message-only windows don't receive broadcasts such as
/// <c>TaskbarCreated</c> and <c>WM_SETTINGCHANGE</c>.
/// </summary>
[SupportedOSPlatform("windows6.0.6000")]
public sealed unsafe class MessageWindow : IDisposable
{
    private const uint WM_RUN_QUEUED = WM_APP + 0x100;

    [ThreadStatic] private static MessageWindow? t_current;

    private readonly ConcurrentQueue<Action> _queue = new();
    private readonly Thread _thread;
    private readonly string _className;
    private MessageHook[] _hooks = [];
    private HWND _hwnd;
    private bool _disposed;

    private MessageWindow(string title)
    {
        _className = "VantageHost.MessageWindow." + Guid.NewGuid().ToString("N");
        using var ready = new ManualResetEventSlim();
        Exception? failure = null;
        _thread = new Thread(() => Run(title, ready, ref failure))
        {
            IsBackground = true,
            Name = "Vantage message window",
        };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        ready.Wait();
        if (failure is not null) throw new InvalidOperationException("Couldn't create the host's message window.", failure);
    }

    /// <summary>Creates the window and starts its thread.</summary>
    public static MessageWindow Start(string title = "Vantage Host") => new(title);

    /// <summary>The window handle.</summary>
    public nint Handle => (nint)_hwnd.Value;

    internal HWND Hwnd => _hwnd;

    /// <summary>Whether the caller is on the window's thread.</summary>
    public bool IsOnThread => Environment.CurrentManagedThreadId == _thread.ManagedThreadId;

    /// <summary>Adds a message handler (called on the window thread, in the order added).</summary>
    public IDisposable AddHook(MessageHook hook)
    {
        ImmutableInterlocked(ref _hooks, hooks => [.. hooks, hook]);
        return new Unhook(this, hook);
    }

    /// <summary>Runs <paramref name="action"/> on the window thread without waiting.</summary>
    public void Post(Action action)
    {
        _queue.Enqueue(action);
        if (!PInvoke.PostMessage(_hwnd, WM_RUN_QUEUED, default, default))
            throw new InvalidOperationException("The message window is gone.");
    }

    /// <summary>Runs <paramref name="func"/> on the window thread and waits for its result (inline if already there).</summary>
    public T Invoke<T>(Func<T> func)
    {
        if (IsOnThread) return func();
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(() =>
        {
            try { completion.SetResult(func()); }
            catch (Exception ex) { completion.SetException(ex); }
        });
        return completion.Task.GetAwaiter().GetResult();
    }

    /// <summary>Runs <paramref name="action"/> on the window thread and waits.</summary>
    public void Invoke(Action action) => Invoke(() => { action(); return true; });

    /// <summary>Destroys the window and ends its thread.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            Post(() => PInvoke.DestroyWindow(_hwnd));
            _thread.Join(TimeSpan.FromSeconds(2));
        }
        catch (InvalidOperationException)
        {
        }
    }

    private void Run(string title, ManualResetEventSlim ready, ref Exception? failure)
    {
        t_current = this;
        try
        {
            var module = PInvoke.GetModuleHandle((PCWSTR)null);
            fixed (char* className = _className)
            fixed (char* windowTitle = title)
            {
                var windowClass = new WNDCLASSEXW
                {
                    cbSize = (uint)sizeof(WNDCLASSEXW),
                    lpfnWndProc = &WindowProc,
                    hInstance = (HINSTANCE)module.Value,
                    lpszClassName = className,
                };
                if (PInvoke.RegisterClassEx(&windowClass) == 0)
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
                _hwnd = PInvoke.CreateWindowEx(WINDOW_EX_STYLE.WS_EX_TOOLWINDOW | WINDOW_EX_STYLE.WS_EX_NOACTIVATE,
                                               className, windowTitle, WINDOW_STYLE.WS_OVERLAPPED,
                                               0, 0, 0, 0, HWND.Null, HMENU.Null, (HINSTANCE)module.Value, null);
                if (_hwnd.IsNull) throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
            }
        }
        catch (Exception ex)
        {
            failure = ex;
            ready.Set();
            return;
        }
        ready.Set();

        MSG message;
        while (PInvoke.GetMessage(&message, HWND.Null, 0, 0) > 0)
        {
            PInvoke.TranslateMessage(&message);
            PInvoke.DispatchMessage(&message);
        }
        fixed (char* className = _className) PInvoke.UnregisterClass(className, (HINSTANCE)PInvoke.GetModuleHandle((PCWSTR)null).Value);
        t_current = null;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static LRESULT WindowProc(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam)
    {
        var self = t_current;
        try
        {
            if (self is not null) return self.OnMessage(hwnd, message, wParam, lParam);
        }
        catch (Exception ex)
        {
            // Never let an exception cross into user32: it would tear the process down.
            System.Diagnostics.Trace.WriteLine($"Vantage message window: {message:X}: {ex}");
        }
        return PInvoke.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private LRESULT OnMessage(HWND hwnd, uint message, WPARAM wParam, LPARAM lParam)
    {
        if (message == WM_RUN_QUEUED)
        {
            while (_queue.TryDequeue(out var action))
            {
                try { action(); }
                catch (Exception ex) { System.Diagnostics.Trace.WriteLine($"Vantage message window action: {ex}"); }
            }
            return (LRESULT)0;
        }
        if (message == WM_DESTROY)
        {
            foreach (var hook in Volatile.Read(ref _hooks)) hook(message, wParam.Value, lParam.Value, out _);
            PInvoke.PostQuitMessage(0);
            return (LRESULT)0;
        }
        foreach (var hook in Volatile.Read(ref _hooks))
        {
            if (hook(message, wParam.Value, lParam.Value, out var result)) return (LRESULT)result;
        }
        return PInvoke.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private static void ImmutableInterlocked(ref MessageHook[] location, Func<MessageHook[], MessageHook[]> change)
    {
        while (true)
        {
            var current = Volatile.Read(ref location);
            if (Interlocked.CompareExchange(ref location, change(current), current) == current) return;
        }
    }

    private sealed class Unhook(MessageWindow owner, MessageHook hook) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0)
                ImmutableInterlocked(ref owner._hooks, hooks => Array.FindAll(hooks, h => h != hook));
        }
    }
}
