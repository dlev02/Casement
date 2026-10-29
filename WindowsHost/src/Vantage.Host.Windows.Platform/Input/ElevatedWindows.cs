using System.Diagnostics;
using System.Security.Principal;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security;
using Windows.Win32.System.Threading;
using Windows.Win32.UI.WindowsAndMessaging;

namespace Vantage.Host.Windows.Input;

/// <summary>
/// Which windows belong to a process running as administrator. Windows (UIPI) silently drops input
/// a normal process sends to them, and <c>SendInput</c> still reports success, so the host looks
/// before a click or key press instead (Task Manager runs elevated on Windows 11).
/// </summary>
public static class ElevatedWindows
{
    /// <summary>Whether this process runs as administrator (elevated), which UIPI lets reach every window.</summary>
    public static bool ThisProcessIsElevated { get; } = IsElevated();

    /// <summary>The top-level window at a virtual-desktop pixel, if its process is elevated; else null.</summary>
    public static ElevatedWindow? At(int x, int y) => Check(PInvoke.WindowFromPoint(new System.Drawing.Point(x, y)));

    /// <summary>The foreground window, if its process is elevated; else null.</summary>
    public static ElevatedWindow? Foreground() => Check(PInvoke.GetForegroundWindow());

    private static unsafe ElevatedWindow? Check(HWND window)
    {
        if (window.IsNull) return null;
        var root = PInvoke.GetAncestor(window, GET_ANCESTOR_FLAGS.GA_ROOT);
        if (root.IsNull) root = window;
        uint pid = 0;
        PInvoke.GetWindowThreadProcessId(root, &pid);
        if (pid == 0 || pid == Environment.ProcessId || !ProcessIsElevated(pid)) return null;

        Span<char> title = stackalloc char[256];
        int length;
        fixed (char* buffer = title) length = PInvoke.GetWindowText(root, buffer, title.Length);
        var name = length > 0 ? new string(title[..length]) : ProcessName(pid);
        return new ElevatedWindow((nint)root.Value, name);
    }

    private static unsafe bool ProcessIsElevated(uint pid)
    {
        // Anyone may open an elevated process for limited queries; only protected processes refuse.
        var process = PInvoke.OpenProcess(PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process.IsNull) return false;
        try
        {
            HANDLE token;
            // A token this process can't read is an elevated one's (its default DACL is for admins).
            if (!PInvoke.OpenProcessToken(process, TOKEN_ACCESS_MASK.TOKEN_QUERY, &token)) return true;
            try
            {
                TOKEN_ELEVATION elevation;
                uint size;
                return PInvoke.GetTokenInformation(token, TOKEN_INFORMATION_CLASS.TokenElevation, &elevation, (uint)sizeof(TOKEN_ELEVATION), &size)
                    && elevation.TokenIsElevated != 0;
            }
            finally
            {
                PInvoke.CloseHandle(token);
            }
        }
        finally
        {
            PInvoke.CloseHandle(process);
        }
    }

    private static string ProcessName(uint pid)
    {
        try
        {
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
            return "An administrator app";
        }
    }

    private static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }
}

/// <summary>A top-level window whose process runs as administrator.</summary>
/// <param name="Handle">Its HWND.</param>
/// <param name="Name">Its title ("Task Manager"), or its process name when untitled.</param>
public sealed record ElevatedWindow(nint Handle, string Name);
