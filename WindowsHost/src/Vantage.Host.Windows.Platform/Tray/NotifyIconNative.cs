using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Vantage.Host.Windows.Tray;

/// <summary>
/// <c>Shell_NotifyIconW</c> and <c>NOTIFYICONDATAW</c> (ShellAPI.h), declared by hand because the
/// Win32 metadata marks them architecture-specific and the platform library is AnyCPU. This is the
/// x64/ARM64 layout (976 bytes); the host ships for win-x64.
/// </summary>
internal static unsafe class NotifyIconNative
{
    public const uint NIM_ADD = 0;
    public const uint NIM_MODIFY = 1;
    public const uint NIM_DELETE = 2;
    public const uint NIM_SETFOCUS = 3;
    public const uint NIM_SETVERSION = 4;

    public const uint NIF_MESSAGE = 0x01;
    public const uint NIF_ICON = 0x02;
    public const uint NIF_TIP = 0x04;
    public const uint NIF_STATE = 0x08;
    public const uint NIF_INFO = 0x10;
    public const uint NIF_SHOWTIP = 0x80;

    public const uint NOTIFYICON_VERSION_4 = 4;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;
        public TipBuffer szTip;
        public uint dwState;
        public uint dwStateMask;
        public InfoBuffer szInfo;
        public uint uVersion; // union with uTimeout
        public InfoTitleBuffer szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [InlineArray(128)]
    public struct TipBuffer
    {
        private char _first;
    }

    [InlineArray(256)]
    public struct InfoBuffer
    {
        private char _first;
    }

    [InlineArray(64)]
    public struct InfoTitleBuffer
    {
        private char _first;
    }

    /// <summary>Copies <paramref name="text"/> into a fixed buffer, truncated and NUL-terminated.</summary>
    public static void Copy(string text, Span<char> buffer)
    {
        buffer.Clear();
        var length = Math.Min(text.Length, buffer.Length - 1);
        text.AsSpan(0, length).CopyTo(buffer);
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", ExactSpelling = true)]
    public static extern int Shell_NotifyIcon(uint message, NOTIFYICONDATAW* data);
}
