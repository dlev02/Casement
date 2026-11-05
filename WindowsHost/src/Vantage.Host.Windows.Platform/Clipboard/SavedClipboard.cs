namespace Vantage.Host.Windows.Clipboard;

/// <summary>One clipboard format's bytes, as <c>GetClipboardData</c> gave them.</summary>
internal sealed record SavedFormat(uint Format, byte[] Data);

/// <summary>
/// What the clipboard held before a paste (<see cref="Win32Clipboard.WriteForPaste"/>): every format
/// whose data is a plain memory block, so a restore gives back what was copied (text, RTF, HTML, an
/// image, files copied in Explorer), not just the three things the protocol carries.
/// </summary>
internal sealed record SavedClipboard(IReadOnlyList<SavedFormat> Formats);

/// <summary>Which clipboard formats a paste can save and put back. Pure; unit-tested.</summary>
public static class ClipboardFormats
{
    /// <summary>
    /// Saved formats stop here (bytes, all formats together); the rest are left out of the restore and
    /// logged. Saving makes the copying app render every format it offered late, so this bounds both
    /// the memory and the time a paste can take behind a huge copy.
    /// </summary>
    public const long MaxSavedBytes = 64L * 1024 * 1024;

    // Handles that aren't a memory block (GDI objects, metafiles, owner-drawn) can't be copied as
    // bytes: the system frees them with the clipboard, so the copy would point at nothing.
    private const uint CF_TEXT = 1, CF_BITMAP = 2, CF_METAFILEPICT = 3, CF_OEMTEXT = 7, CF_PALETTE = 9,
                       CF_ENHMETAFILE = 14, CF_OWNERDISPLAY = 0x80, CF_DSPBITMAP = 0x82,
                       CF_DSPMETAFILEPICT = 0x83, CF_DSPENHMETAFILE = 0x8E,
                       CF_PRIVATEFIRST = 0x200, CF_GDIOBJLAST = 0x3FF;

    // OLE's own bookkeeping: they name the data object that was on the clipboard, which emptying it
    // releases; put back, they'd point OleGetClipboard at an object that's gone. The embedding formats
    // aren't memory blocks either.
    private static readonly HashSet<string> s_oleFormats = new(StringComparer.OrdinalIgnoreCase)
    {
        "DataObject", "Ole Private Data", "Embed Source", "Embedded Object", "Link Source",
        "Object Descriptor", "Link Source Descriptor",
    };

    /// <summary>
    /// Whether a format on the clipboard can be saved as bytes and put back.
    /// <paramref name="name"/> is a registered format's name (null for the standard ones);
    /// <paramref name="hasUnicodeText"/>: <c>CF_UNICODETEXT</c> is there, so ANSI and OEM text are the
    /// system's synthesized copies of it and come back by themselves.
    /// </summary>
    public static bool CanSave(uint format, string? name, bool hasUnicodeText)
    {
        if (format is CF_BITMAP or CF_METAFILEPICT or CF_PALETTE or CF_ENHMETAFILE or CF_OWNERDISPLAY
                   or CF_DSPBITMAP or CF_DSPMETAFILEPICT or CF_DSPENHMETAFILE) return false;
        if (format is >= CF_PRIVATEFIRST and <= CF_GDIOBJLAST) return false; // private and GDI-object ranges
        if (hasUnicodeText && format is CF_TEXT or CF_OEMTEXT) return false;
        return name is null || !s_oleFormats.Contains(name);
    }

    /// <summary>
    /// Whether a copy is marked as not meant to travel, as password managers mark theirs: the exclude
    /// marker is there, or either "can include" marker holds a DWORD 0. Those stay on this PC.
    /// </summary>
    public static bool IsPrivate(bool excludedFromMonitoring, byte[]? canIncludeInHistory, byte[]? canUploadToCloud) =>
        excludedFromMonitoring || IsDwordZero(canIncludeInHistory) || IsDwordZero(canUploadToCloud);

    private static bool IsDwordZero(byte[]? value) => value is { Length: >= 4 } && BitConverter.ToUInt32(value) == 0;
}
