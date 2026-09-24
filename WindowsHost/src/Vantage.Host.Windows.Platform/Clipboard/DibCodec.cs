using System.Buffers.Binary;

namespace Vantage.Host.Windows.Clipboard;

/// <summary>An image as 8-bit BGRA, top-down rows, straight alpha.</summary>
/// <param name="Width">Pixels.</param>
/// <param name="Height">Pixels.</param>
/// <param name="Bgra">Width × Height × 4 bytes.</param>
public sealed record BgraImage(int Width, int Height, byte[] Bgra);

/// <summary>
/// <c>CF_DIB</c>/<c>CF_DIBV5</c> ↔ <see cref="BgraImage"/>. Reads 24- and 32-bit DIBs (BI_RGB or
/// BI_BITFIELDS, bottom-up or top-down, BITMAPINFOHEADER/V4/V5); writes a bottom-up 32-bit
/// BITMAPV5HEADER with BI_BITFIELDS masks and an sRGB colour space. Pure; unit-tested on macOS.
/// </summary>
public static class DibCodec
{
    private const int BI_RGB = 0;
    private const int BI_BITFIELDS = 3;
    private const int V5HeaderSize = 124;
    private const uint LCS_sRGB = 0x73524742;
    private const uint LCS_GM_IMAGES = 4;

    /// <summary>Largest image accepted (pixels), so a malformed header can't make us allocate gigabytes.</summary>
    public const long MaxPixels = 16384L * 16384;

    /// <summary>Decodes a DIB; false for anything unsupported or malformed.</summary>
    public static bool TryDecode(ReadOnlySpan<byte> dib, out BgraImage? image)
    {
        image = null;
        if (dib.Length < 40) return false;
        var headerSize = BinaryPrimitives.ReadInt32LittleEndian(dib);
        if (headerSize < 40 || headerSize > dib.Length) return false;
        var width = BinaryPrimitives.ReadInt32LittleEndian(dib[4..]);
        var rawHeight = BinaryPrimitives.ReadInt32LittleEndian(dib[8..]);
        var bitCount = BinaryPrimitives.ReadUInt16LittleEndian(dib[14..]);
        var compression = BinaryPrimitives.ReadInt32LittleEndian(dib[16..]);
        var colorsUsed = BinaryPrimitives.ReadInt32LittleEndian(dib[32..]);
        if (width <= 0 || rawHeight == 0 || rawHeight == int.MinValue) return false;
        var height = Math.Abs(rawHeight);
        var topDown = rawHeight < 0;
        if ((long)width * height > MaxPixels) return false;
        if (bitCount is not (24 or 32)) return false;
        if (compression is not (BI_RGB or BI_BITFIELDS)) return false;

        uint red = 0x00FF0000, green = 0x0000FF00, blue = 0x000000FF, alpha = 0;
        var offset = headerSize;
        if (compression == BI_BITFIELDS)
        {
            if (bitCount != 32) return false;
            ReadOnlySpan<byte> masks;
            if (headerSize >= 56) masks = dib[40..56];
            else
            {
                if (dib.Length < 40 + 12) return false;
                masks = dib[40..52];
                offset += 12;
            }
            red = BinaryPrimitives.ReadUInt32LittleEndian(masks);
            green = BinaryPrimitives.ReadUInt32LittleEndian(masks[4..]);
            blue = BinaryPrimitives.ReadUInt32LittleEndian(masks[8..]);
            alpha = masks.Length >= 16 ? BinaryPrimitives.ReadUInt32LittleEndian(masks[12..]) : 0;
        }
        else if (bitCount == 32 && headerSize >= 56)
        {
            alpha = BinaryPrimitives.ReadUInt32LittleEndian(dib[52..]);
        }
        if (colorsUsed > 0 && colorsUsed <= 256) offset += colorsUsed * 4;

        var bytesPerPixel = bitCount / 8;
        var stride = ((width * bitCount + 31) / 32) * 4;
        if ((long)offset + (long)stride * height > dib.Length) return false;

        var output = new byte[width * height * 4];
        var anyAlpha = false;
        for (var y = 0; y < height; y++)
        {
            var sourceRow = dib.Slice(offset + (topDown ? y : height - 1 - y) * stride, stride);
            var targetRow = output.AsSpan(y * width * 4, width * 4);
            for (var x = 0; x < width; x++)
            {
                if (bytesPerPixel == 3)
                {
                    targetRow[x * 4] = sourceRow[x * 3];
                    targetRow[x * 4 + 1] = sourceRow[x * 3 + 1];
                    targetRow[x * 4 + 2] = sourceRow[x * 3 + 2];
                    targetRow[x * 4 + 3] = 255;
                    continue;
                }
                var pixel = BinaryPrimitives.ReadUInt32LittleEndian(sourceRow[(x * 4)..]);
                targetRow[x * 4] = Channel(pixel, blue);
                targetRow[x * 4 + 1] = Channel(pixel, green);
                targetRow[x * 4 + 2] = Channel(pixel, red);
                var a = alpha != 0 ? Channel(pixel, alpha) : (byte)0;
                targetRow[x * 4 + 3] = a;
                if (a != 0) anyAlpha = true;
            }
        }
        // Plain 32-bit DIBs leave the fourth byte undefined (usually 0): treat as opaque.
        if (bytesPerPixel == 4 && !anyAlpha)
            for (var i = 3; i < output.Length; i += 4) output[i] = 255;

        image = new BgraImage(width, height, output);
        return true;
    }

    /// <summary>A <c>CF_DIBV5</c> block for <paramref name="image"/>.</summary>
    public static byte[] EncodeV5(BgraImage image)
    {
        var stride = image.Width * 4;
        var result = new byte[V5HeaderSize + stride * image.Height];
        var header = result.AsSpan(0, V5HeaderSize);
        BinaryPrimitives.WriteInt32LittleEndian(header, V5HeaderSize);
        BinaryPrimitives.WriteInt32LittleEndian(header[4..], image.Width);
        BinaryPrimitives.WriteInt32LittleEndian(header[8..], image.Height); // bottom-up
        BinaryPrimitives.WriteUInt16LittleEndian(header[12..], 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header[14..], 32);
        BinaryPrimitives.WriteInt32LittleEndian(header[16..], BI_BITFIELDS);
        BinaryPrimitives.WriteInt32LittleEndian(header[20..], stride * image.Height);
        BinaryPrimitives.WriteInt32LittleEndian(header[24..], 2835); // 72 dpi
        BinaryPrimitives.WriteInt32LittleEndian(header[28..], 2835);
        BinaryPrimitives.WriteUInt32LittleEndian(header[40..], 0x00FF0000);
        BinaryPrimitives.WriteUInt32LittleEndian(header[44..], 0x0000FF00);
        BinaryPrimitives.WriteUInt32LittleEndian(header[48..], 0x000000FF);
        BinaryPrimitives.WriteUInt32LittleEndian(header[52..], 0xFF000000);
        BinaryPrimitives.WriteUInt32LittleEndian(header[56..], LCS_sRGB);
        BinaryPrimitives.WriteUInt32LittleEndian(header[108..], LCS_GM_IMAGES);
        for (var y = 0; y < image.Height; y++)
        {
            image.Bgra.AsSpan(y * stride, stride).CopyTo(result.AsSpan(V5HeaderSize + (image.Height - 1 - y) * stride, stride));
        }
        return result;
    }

    private static byte Channel(uint pixel, uint mask)
    {
        if (mask == 0) return 0;
        var shift = System.Numerics.BitOperations.TrailingZeroCount(mask);
        var bits = System.Numerics.BitOperations.PopCount(mask);
        var value = (pixel & mask) >> shift;
        return bits >= 8 ? (byte)(value >> (bits - 8)) : (byte)(value * 255 / ((1u << bits) - 1));
    }
}
