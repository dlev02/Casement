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

    /// <summary>
    /// Puts <paramref name="text"/> (wire text, LF line endings) on the clipboard for a paste
    /// (<see cref="ClipboardPaster"/>) and returns what was there before, in one clipboard open so
    /// nothing slips in between. When <paramref name="earlier"/> is given and the clipboard still holds
    /// that paste's write, the result keeps <paramref name="earlier"/>'s former contents instead of
    /// taking the earlier paste's text for them (pastes in a row give back the clipboard from before the
    /// first). Like <see cref="Apply"/>, the write must not come back through <see cref="Watch"/>.
    /// Returns null, having changed nothing, when another app holds the clipboard.
    /// </summary>
    PasteWrite? WriteForPaste(string text, PasteWrite? earlier);

    /// <summary>
    /// Puts <paramref name="write"/>'s former contents back, but only while the clipboard still holds
    /// that write: a copy made since then wins. Not reported through <see cref="Watch"/> either.
    /// Returns whether it restored; false when something else changed the clipboard or it couldn't be
    /// opened. Called from a timer thread; marshal as needed.
    /// </summary>
    bool RestoreAfterPaste(PasteWrite write);
}

/// <summary>A clipboard write made for a paste (<see cref="IClipboard.WriteForPaste"/>).</summary>
/// <param name="Former">
/// What the clipboard held before, opaque to the session: only the clipboard that made it reads it.
/// Null means it was empty, and a restore empties it again.
/// </param>
/// <param name="Mark">
/// The clipboard's change mark right after the write (Windows: <c>GetClipboardSequenceNumber</c>), so a
/// restore can tell whether anything has changed it since.
/// </param>
public sealed record PasteWrite(object? Former, ulong Mark);
