using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// The host's clipboard (spec §9.3). Windows: Win32 clipboard on the app's message window,
/// <c>AddClipboardFormatListener</c> for changes, <c>GetClipboardSequenceNumber</c> for echo
/// suppression.
/// </summary>
/// <remarks>
/// Text on the wire has LF line endings: convert CRLF → LF when reading and LF → CRLF when
/// applying (<c>CF_UNICODETEXT</c>). RTF is the registered <c>"Rich Text Format"</c> format.
/// Images: read <c>"PNG"</c> if present, else convert <c>CF_DIBV5</c> to PNG (≤ 24 MiB, else
/// leave the image out); write both <c>"PNG"</c> and <c>CF_DIBV5</c>.
/// </remarks>
public interface IClipboard
{
    /// <summary>
    /// The clipboard now, or null when it holds nothing the protocol carries. Sent once when a
    /// stream starts. Never return a payload whose three fields are all null.
    /// </summary>
    ClipboardPayload? Read();

    /// <summary>
    /// Replaces the clipboard with what the client sent (text, RTF and/or PNG together). The change
    /// this makes must not come back through <see cref="Watch"/> (echo suppression). Called from
    /// the session's receive loop; marshal to the clipboard's thread as needed.
    /// </summary>
    void Apply(ClipboardPayload payload);

    /// <summary>
    /// Watches for local changes and calls <paramref name="onChanged"/> with the whole payload after
    /// each one (not for changes <see cref="Apply"/> made). One watcher per streaming session;
    /// disposing the result stops it. The synthetic host never watches.
    /// </summary>
    IDisposable Watch(Action<ClipboardPayload> onChanged);
}
