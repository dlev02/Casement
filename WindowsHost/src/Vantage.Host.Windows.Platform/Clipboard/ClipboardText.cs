using System.Text;

namespace Vantage.Host.Windows.Clipboard;

/// <summary>
/// Line endings and terminators between the wire (LF, spec §9.3) and the Windows clipboard
/// (<c>CF_UNICODETEXT</c> with CRLF, NUL-terminated; RTF NUL-terminated). Pure; unit-tested on macOS.
/// </summary>
public static class ClipboardText
{
    /// <summary>Windows text → wire: CRLF and lone CR become LF; stops at the first NUL.</summary>
    public static string ToWire(string windowsText)
    {
        var nul = windowsText.IndexOf('\0');
        if (nul >= 0) windowsText = windowsText[..nul];
        if (windowsText.IndexOf('\r') < 0) return windowsText;
        var builder = new StringBuilder(windowsText.Length);
        for (var i = 0; i < windowsText.Length; i++)
        {
            var c = windowsText[i];
            if (c == '\r')
            {
                builder.Append('\n');
                if (i + 1 < windowsText.Length && windowsText[i + 1] == '\n') i++;
            }
            else
            {
                builder.Append(c);
            }
        }
        return builder.ToString();
    }

    /// <summary>Wire text → Windows: every LF (and any stray CR or CRLF) becomes CRLF.</summary>
    public static string ToWindows(string wireText)
    {
        var normalized = ToWire(wireText);
        if (normalized.IndexOf('\n') < 0) return normalized;
        var builder = new StringBuilder(normalized.Length + 16);
        foreach (var c in normalized)
        {
            if (c == '\n') builder.Append('\r');
            builder.Append(c);
        }
        return builder.ToString();
    }

    /// <summary>RTF from the clipboard without trailing NULs (some apps pad the global block).</summary>
    public static byte[] TrimRtf(ReadOnlySpan<byte> rtf)
    {
        var end = rtf.IndexOf((byte)0);
        return (end >= 0 ? rtf[..end] : rtf).ToArray();
    }
}
