using System.Buffers.Binary;
using System.IO.Compression;

namespace Vantage.Host.Windows.Clipboard;

/// <summary>
/// A minimal PNG encoder (8-bit RGBA, non-interlaced, Sub filter, zlib) for clipboard images that
/// Windows only has as a DIB. Pure managed code; unit-tested on macOS.
/// </summary>
public static class PngWriter
{
    private static readonly uint[] s_crcTable = BuildCrcTable();

    /// <summary>Encodes a BGRA image as PNG.</summary>
    public static byte[] Encode(BgraImage image)
    {
        using var output = new MemoryStream(image.Bgra.Length / 3 + 1024);
        output.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);

        Span<byte> ihdr = stackalloc byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr, image.Width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr[4..], image.Height);
        ihdr[8] = 8;  // bit depth
        ihdr[9] = 6;  // RGBA
        ihdr[10] = 0; // deflate
        ihdr[11] = 0; // adaptive filtering
        ihdr[12] = 0; // no interlace
        WriteChunk(output, "IHDR"u8, ihdr);

        // sRGB rendering intent: perceptual, so viewers don't colour-manage the pixels twice.
        WriteChunk(output, "sRGB"u8, [0]);

        using (var idat = new MemoryStream())
        {
            using (var zlib = new ZLibStream(idat, CompressionLevel.Fastest, leaveOpen: true))
            {
                var rowBytes = image.Width * 4;
                var row = new byte[1 + rowBytes];
                for (var y = 0; y < image.Height; y++)
                {
                    row[0] = 1; // Sub
                    var source = image.Bgra.AsSpan(y * rowBytes, rowBytes);
                    for (var x = 0; x < image.Width; x++)
                    {
                        var i = x * 4;
                        byte r = source[i + 2], g = source[i + 1], b = source[i], a = source[i + 3];
                        if (x == 0)
                        {
                            row[1 + i] = r;
                            row[2 + i] = g;
                            row[3 + i] = b;
                            row[4 + i] = a;
                        }
                        else
                        {
                            row[1 + i] = (byte)(r - source[i - 2]);
                            row[2 + i] = (byte)(g - source[i - 3]);
                            row[3 + i] = (byte)(b - source[i - 4]);
                            row[4 + i] = (byte)(a - source[i - 1]);
                        }
                    }
                    zlib.Write(row);
                }
            }
            WriteChunk(output, "IDAT"u8, idat.GetBuffer().AsSpan(0, (int)idat.Length));
        }
        WriteChunk(output, "IEND"u8, []);
        return output.ToArray();
    }

    /// <summary>CRC-32 (ISO 3309 / PNG).</summary>
    public static uint Crc32(ReadOnlySpan<byte> type, ReadOnlySpan<byte> data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in type) crc = s_crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        foreach (var b in data) crc = s_crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    private static void WriteChunk(Stream output, ReadOnlySpan<byte> type, ReadOnlySpan<byte> data)
    {
        Span<byte> word = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(word, data.Length);
        output.Write(word);
        output.Write(type);
        output.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(word, Crc32(type, data));
        output.Write(word);
    }

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }
}
