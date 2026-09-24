using System.Buffers.Binary;

namespace Vantage.Host.Windows.Tray;

/// <summary>
/// Picks the image for a size out of an <c>.ico</c> file (for <c>CreateIconFromResourceEx</c>, which
/// takes one image, PNG or DIB). Pure; unit-tested on macOS.
/// </summary>
public static class IconDirectory
{
    /// <summary>One image in the file.</summary>
    public readonly record struct Entry(int Width, int Height, int Offset, int Length);

    /// <summary>The images in an ICO file (empty when it isn't one).</summary>
    public static IReadOnlyList<Entry> Read(ReadOnlySpan<byte> ico)
    {
        if (ico.Length < 6 || BinaryPrimitives.ReadUInt16LittleEndian(ico) != 0 || BinaryPrimitives.ReadUInt16LittleEndian(ico[2..]) != 1)
            return [];
        var count = BinaryPrimitives.ReadUInt16LittleEndian(ico[4..]);
        var entries = new List<Entry>(count);
        for (var i = 0; i < count; i++)
        {
            var at = 6 + 16 * i;
            if (at + 16 > ico.Length) break;
            var width = ico[at] == 0 ? 256 : ico[at];
            var height = ico[at + 1] == 0 ? 256 : ico[at + 1];
            var length = BinaryPrimitives.ReadInt32LittleEndian(ico[(at + 8)..]);
            var offset = BinaryPrimitives.ReadInt32LittleEndian(ico[(at + 12)..]);
            if (offset < 0 || length <= 0 || (long)offset + length > ico.Length) continue;
            entries.Add(new Entry(width, height, offset, length));
        }
        return entries;
    }

    /// <summary>The smallest image at least <paramref name="size"/> pixels wide, else the largest.</summary>
    public static Entry? Pick(IReadOnlyList<Entry> entries, int size)
    {
        Entry? best = null;
        foreach (var entry in entries)
        {
            if (entry.Width >= size && (best is null || best.Value.Width < size || entry.Width < best.Value.Width)) best = entry;
            else if (best is null || (best.Value.Width < size && entry.Width > best.Value.Width)) best = entry;
        }
        return best;
    }
}
