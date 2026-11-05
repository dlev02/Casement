using System.Buffers.Binary;
using System.IO.Compression;
using Vantage.Host.Windows.Clipboard;

namespace Vantage.Host.Windows.Tests;

public class ClipboardTextTests
{
    [Theory]
    [InlineData("one\r\ntwo\r\n", "one\ntwo\n")]
    [InlineData("old mac\rline", "old mac\nline")]
    [InlineData("mixed\r\n\n\r", "mixed\n\n\n")]
    [InlineData("stops here\0garbage", "stops here")]
    [InlineData("plain", "plain")]
    public void WindowsTextBecomesLf(string windows, string wire) => Assert.Equal(wire, ClipboardText.ToWire(windows));

    [Theory]
    [InlineData("one\ntwo\n", "one\r\ntwo\r\n")]
    [InlineData("already\r\nwindows", "already\r\nwindows")]
    [InlineData("stray\rcr", "stray\r\ncr")]
    [InlineData("no breaks", "no breaks")]
    public void WireTextBecomesCrlf(string wire, string windows) => Assert.Equal(windows, ClipboardText.ToWindows(wire));

    [Fact]
    public void RoundTripsLfText()
    {
        const string text = "a\nb\n\nc";
        Assert.Equal(text, ClipboardText.ToWire(ClipboardText.ToWindows(text)));
    }

    [Fact]
    public void RtfLosesTrailingNuls() =>
        Assert.Equal("{\\rtf1}"u8.ToArray(), ClipboardText.TrimRtf([.. "{\\rtf1}"u8, 0, 0, 0]));
}

public class DibCodecTests
{
    private static BgraImage Sample(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++)
        {
            var i = (y * width + x) * 4;
            pixels[i] = (byte)(x * 7);
            pixels[i + 1] = (byte)(y * 13);
            pixels[i + 2] = (byte)(x + y);
            pixels[i + 3] = (byte)(x == 0 ? 128 : 255);
        }
        return new BgraImage(width, height, pixels);
    }

    [Fact]
    public void V5RoundTrips()
    {
        var image = Sample(5, 3);
        var dib = DibCodec.EncodeV5(image);
        Assert.Equal(124 + 5 * 3 * 4, dib.Length);
        Assert.True(DibCodec.TryDecode(dib, out var decoded));
        Assert.Equal(image.Width, decoded!.Width);
        Assert.Equal(image.Height, decoded.Height);
        Assert.Equal(image.Bgra, decoded.Bgra);
    }

    [Fact]
    public void ReadsA24BitBottomUpDibWithPaddedRows()
    {
        // 3×2, stride 12 (9 bytes + 3 padding); bottom-up, so the first row in memory is y = 1.
        var dib = Header(40, 3, 2, 24, 0);
        byte[] bottom = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0];
        byte[] top = [10, 11, 12, 13, 14, 15, 16, 17, 18, 0, 0, 0];
        Assert.True(DibCodec.TryDecode([.. dib, .. bottom, .. top], out var image));
        Assert.Equal<byte>([10, 11, 12, 255, 13, 14, 15, 255, 16, 17, 18, 255, 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255], image!.Bgra);
    }

    [Fact]
    public void Plain32BitDibWithZeroAlphaIsOpaque()
    {
        var dib = Header(40, 1, -2, 32, 0); // top-down
        Assert.True(DibCodec.TryDecode([.. dib, 1, 2, 3, 0, 4, 5, 6, 0], out var image));
        Assert.Equal<byte>([1, 2, 3, 255, 4, 5, 6, 255], image!.Bgra);
    }

    [Fact]
    public void BitfieldsAfterAnInfoHeader()
    {
        // BI_BITFIELDS with a 40-byte header: three masks follow. Here the pixel is stored as RGBx.
        var dib = Header(40, 1, 1, 32, 3);
        var masks = new byte[12];
        BinaryPrimitives.WriteUInt32LittleEndian(masks, 0x000000FF);      // red in the low byte
        BinaryPrimitives.WriteUInt32LittleEndian(masks.AsSpan(4), 0x0000FF00);
        BinaryPrimitives.WriteUInt32LittleEndian(masks.AsSpan(8), 0x00FF0000); // blue
        Assert.True(DibCodec.TryDecode([.. dib, .. masks, 0x11, 0x22, 0x33, 0x00], out var image));
        Assert.Equal<byte>([0x33, 0x22, 0x11, 255], image!.Bgra);
    }

    [Theory]
    [InlineData(8, 0)]  // palettes aren't read
    [InlineData(32, 1)] // RLE
    public void RefusesWhatItDoesntRead(int bits, int compression)
    {
        var dib = Header(40, 1, 1, (ushort)bits, compression);
        Assert.False(DibCodec.TryDecode([.. dib, .. new byte[16]], out _));
    }

    [Fact]
    public void RefusesTruncatedData()
    {
        Assert.False(DibCodec.TryDecode(new byte[10], out _));
        Assert.False(DibCodec.TryDecode(Header(40, 100, 100, 32, 0), out _));
    }

    private static byte[] Header(int size, int width, int height, ushort bits, int compression)
    {
        var header = new byte[size];
        BinaryPrimitives.WriteInt32LittleEndian(header, size);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(4), width);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(8), height);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(12), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(14), bits);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(16), compression);
        return header;
    }
}

public class PngWriterTests
{
    [Fact]
    public void WritesAValidPngThatDecodesToTheSamePixels()
    {
        const int width = 7, height = 4;
        var bgra = new byte[width * height * 4];
        new Random(1).NextBytes(bgra);
        var png = PngWriter.Encode(new BgraImage(width, height, bgra));

        Assert.Equal<byte>([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], png[..8]);
        var chunks = Chunks(png);
        Assert.Equal(["IHDR", "sRGB", "IDAT", "IEND"], chunks.Select(c => c.Type));
        foreach (var chunk in chunks) Assert.Equal(chunk.Crc, PngWriter.Crc32(System.Text.Encoding.ASCII.GetBytes(chunk.Type), chunk.Data));

        var ihdr = chunks[0].Data;
        Assert.Equal(width, BinaryPrimitives.ReadInt32BigEndian(ihdr));
        Assert.Equal(height, BinaryPrimitives.ReadInt32BigEndian(ihdr.AsSpan(4)));
        Assert.Equal(8, ihdr[8]);
        Assert.Equal(6, ihdr[9]);

        // Inflate and undo the Sub filter: RGBA must match the BGRA input.
        using var inflated = new MemoryStream();
        using (var zlib = new ZLibStream(new MemoryStream(chunks[2].Data), CompressionMode.Decompress)) zlib.CopyTo(inflated);
        var raw = inflated.ToArray();
        Assert.Equal(height * (1 + width * 4), raw.Length);
        for (var y = 0; y < height; y++)
        {
            var row = raw.AsSpan(y * (1 + width * 4));
            Assert.Equal(1, row[0]);
            var rgba = new byte[width * 4];
            for (var i = 0; i < rgba.Length; i++) rgba[i] = (byte)(row[1 + i] + (i >= 4 ? rgba[i - 4] : 0));
            for (var x = 0; x < width; x++)
            {
                var s = (y * width + x) * 4;
                Assert.Equal(bgra[s + 2], rgba[x * 4]);
                Assert.Equal(bgra[s + 1], rgba[x * 4 + 1]);
                Assert.Equal(bgra[s], rgba[x * 4 + 2]);
                Assert.Equal(bgra[s + 3], rgba[x * 4 + 3]);
            }
        }
    }

    [Fact]
    public void IendCrcIsTheWellKnownValue() => Assert.Equal(0xAE426082u, PngWriter.Crc32("IEND"u8, []));

    private static List<(string Type, byte[] Data, uint Crc)> Chunks(byte[] png)
    {
        var chunks = new List<(string, byte[], uint)>();
        var at = 8;
        while (at < png.Length)
        {
            var length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            var type = System.Text.Encoding.ASCII.GetString(png, at + 4, 4);
            var data = png.AsSpan(at + 8, length).ToArray();
            var crc = BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(at + 8 + length));
            chunks.Add((type, data, crc));
            at += 12 + length;
        }
        return chunks;
    }
}

/// <summary>Which formats a paste saves and puts back.</summary>
public class ClipboardFormatsTests
{
    [Fact]
    public void WhatAPasswordManagerMarksStaysOnThePc()
    {
        byte[] no = [0, 0, 0, 0], yes = [1, 0, 0, 0];
        Assert.True(ClipboardFormats.IsPrivate(true, null, null));
        Assert.True(ClipboardFormats.IsPrivate(false, no, null));
        Assert.True(ClipboardFormats.IsPrivate(false, null, no));
        Assert.False(ClipboardFormats.IsPrivate(false, yes, yes));
        Assert.False(ClipboardFormats.IsPrivate(false, null, null));
    }

    [Theory]
    [InlineData(13u, null, true)] // CF_UNICODETEXT
    [InlineData(8u, null, true)] // CF_DIB
    [InlineData(17u, null, true)] // CF_DIBV5
    [InlineData(15u, null, true)] // CF_HDROP: files copied in Explorer
    [InlineData(16u, null, true)] // CF_LOCALE
    [InlineData(0xC123u, "HTML Format", true)]
    [InlineData(0xC124u, "Rich Text Format", true)]
    [InlineData(0xC125u, "Preferred DropEffect", true)]
    [InlineData(2u, null, false)] // CF_BITMAP: a GDI handle (comes back synthesized from the DIB)
    [InlineData(3u, null, false)] // CF_METAFILEPICT
    [InlineData(9u, null, false)] // CF_PALETTE
    [InlineData(14u, null, false)] // CF_ENHMETAFILE
    [InlineData(0x80u, null, false)] // CF_OWNERDISPLAY
    [InlineData(0x8Eu, null, false)] // CF_DSPENHMETAFILE
    [InlineData(0x200u, null, false)] // private range
    [InlineData(0x3FFu, null, false)] // GDI object range
    [InlineData(0xC126u, "DataObject", false)] // OLE's pointer to an object emptying releases
    [InlineData(0xC127u, "Ole Private Data", false)]
    [InlineData(0xC128u, "Embed Source", false)]
    public void SavesMemoryBlocksOnly(uint format, string? name, bool saved) =>
        Assert.Equal(saved, ClipboardFormats.CanSave(format, name, hasUnicodeText: true));

    [Fact]
    public void AnsiTextIsSavedOnlyWithoutUnicodeText()
    {
        Assert.False(ClipboardFormats.CanSave(1, null, hasUnicodeText: true)); // CF_TEXT, synthesized
        Assert.False(ClipboardFormats.CanSave(7, null, hasUnicodeText: true)); // CF_OEMTEXT
        Assert.True(ClipboardFormats.CanSave(1, null, hasUnicodeText: false));
    }
}
