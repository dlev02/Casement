namespace Vantage.Host.Windows.Interop;

/// <summary>Window messages and other small constants (from WinUser.h, WtsApi32.h, ShellAPI.h).</summary>
internal static class Win32Constants
{
    public const uint WM_NULL = 0x0000;
    public const uint WM_DESTROY = 0x0002;
    public const uint WM_CLOSE = 0x0010;
    public const uint WM_SETTINGCHANGE = 0x001A;
    public const uint WM_CONTEXTMENU = 0x007B;
    public const uint WM_DISPLAYCHANGE = 0x007E;
    public const uint WM_COMMAND = 0x0111;
    public const uint WM_SYSCOMMAND = 0x0112;
    public const uint WM_LBUTTONUP = 0x0202;
    public const uint WM_RBUTTONUP = 0x0205;
    public const uint WM_POWERBROADCAST = 0x0218;
    public const uint WM_WTSSESSION_CHANGE = 0x02B1;
    public const uint WM_DPICHANGED = 0x02E0;
    public const uint WM_CLIPBOARDUPDATE = 0x031D;
    public const uint WM_USER = 0x0400;
    public const uint WM_APP = 0x8000;

    // Tray (ShellAPI.h, NOTIFYICON_VERSION_4)
    public const uint NIN_SELECT = WM_USER + 0;
    public const uint NIN_KEYSELECT = WM_USER + 1;
    public const uint NIN_POPUPOPEN = WM_USER + 6;
    public const uint NIN_POPUPCLOSE = WM_USER + 7;

    // WM_SYSCOMMAND
    public const nuint SC_MONITORPOWER = 0xF170;

    // WM_POWERBROADCAST
    public const nuint PBT_APMRESUMEAUTOMATIC = 0x0012;
    public const nuint PBT_POWERSETTINGCHANGE = 0x8013;

    // WM_WTSSESSION_CHANGE wParam
    public const nuint WTS_CONSOLE_CONNECT = 0x1;
    public const nuint WTS_CONSOLE_DISCONNECT = 0x2;
    public const nuint WTS_REMOTE_CONNECT = 0x3;
    public const nuint WTS_REMOTE_DISCONNECT = 0x4;
    public const nuint WTS_SESSION_LOGON = 0x5;
    public const nuint WTS_SESSION_LOGOFF = 0x6;
    public const nuint WTS_SESSION_LOCK = 0x7;
    public const nuint WTS_SESSION_UNLOCK = 0x8;

    // WTSRegisterSessionNotification
    public const uint NOTIFY_FOR_THIS_SESSION = 0;

    // WTSINFOEX_LEVEL1.SessionFlags
    public const int WTS_SESSIONSTATE_LOCK = 0;
    public const int WTS_SESSIONSTATE_UNLOCK = 1;

    // TrackPopupMenuEx
    public const uint TPM_RIGHTBUTTON = 0x0002;
    public const uint TPM_BOTTOMALIGN = 0x0020;
    public const uint TPM_RIGHTALIGN = 0x0008;
    public const uint TPM_RETURNCMD = 0x0100;
    public const uint TPM_NONOTIFY = 0x0080;

    // Clipboard formats
    public const uint CF_UNICODETEXT = 13;
    public const uint CF_DIB = 8;
    public const uint CF_DIBV5 = 17;

    // HRESULTs
    public const int S_OK = 0;
    public const int E_NOINTERFACE = unchecked((int)0x80004002);
}
