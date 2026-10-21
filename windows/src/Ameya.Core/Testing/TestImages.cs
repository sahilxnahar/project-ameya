using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace Ameya.Core.Testing;

/// <summary>
/// Tiny pictures written from scratch (no codec involved), so the self-test and the unit tests
/// can feed the real worker known inputs on any PC.
/// </summary>
public static class TestImages
{
    /// <summary>A gradient PNG. With <paramref name="transparentCorner"/>, its top-left quarter is see-through.</summary>
    public static byte[] Png(int width, int height, bool transparentCorner = false, bool withAlphaChannel = true)
    {
        var channels = withAlphaChannel ? 4 : 3;
        var raw = new byte[height * (1 + width * channels)];
        var index = 0;
        for (var y = 0; y < height; y++)
        {
            raw[index++] = 0; // filter: none
            for (var x = 0; x < width; x++)
            {
                raw[index++] = (byte)(x * 255 / Math.Max(1, width - 1));
                raw[index++] = (byte)(y * 255 / Math.Max(1, height - 1));
                raw[index++] = 128;
                if (withAlphaChannel) raw[index++] = transparentCorner && x < width / 2 && y < height / 2 ? (byte)0 : (byte)255;
            }
        }
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);

        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), height);
        header[8] = 8; // bits per channel
        header[9] = withAlphaChannel ? (byte)6 : (byte)2; // RGBA or RGB
        Chunk(png, "IHDR", header);
        Chunk(png, "IDAT", compressed.ToArray());
        Chunk(png, "IEND", []);
        return png.ToArray();
    }

    /// <summary>A 24-bit bottom-up BMP with a colour gradient.</summary>
    public static byte[] Bmp(int width, int height)
    {
        var stride = (width * 3 + 3) & ~3;
        var size = 54 + stride * height;
        var bmp = new byte[size];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(2), size);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(10), 54);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(14), 40);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(18), width);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(22), height);
        BinaryPrimitives.WriteInt16LittleEndian(bmp.AsSpan(26), 1);
        BinaryPrimitives.WriteInt16LittleEndian(bmp.AsSpan(28), 24);
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = 54 + y * stride + x * 3;
                bmp[offset] = (byte)(x * 7);
                bmp[offset + 1] = (byte)(y * 5);
                bmp[offset + 2] = 200;
            }
        }
        return bmp;
    }

    private static void Chunk(Stream png, string type, byte[] data)
    {
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(length, data.Length);
        png.Write(length);
        var typeBytes = Encoding.ASCII.GetBytes(type);
        png.Write(typeBytes);
        png.Write(data);
        Span<byte> crc = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crc, Crc32(typeBytes, data));
        png.Write(crc);
    }

    private static readonly uint[] CrcTable = BuildCrcTable();

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

    private static uint Crc32(byte[] first, byte[] second)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in first) crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        foreach (var b in second) crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }
}
