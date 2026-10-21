using System.Buffers.Binary;

namespace Ameya.Engines.Images;

/// <summary>
/// Writes a Windows icon. WIC can read ICO but not write it, so the container is built here:
/// an ICONDIR, one entry per size, and each image stored as PNG (supported since Windows Vista).
/// </summary>
internal static class IcoWriter
{
    /// <summary>Standard icon sizes up to the image's larger side (always at least the smallest).</summary>
    public static IReadOnlyList<int> Sizes(ImageFrame frame)
    {
        int[] standard = [16, 24, 32, 48, 64, 128, 256];
        var largest = Math.Max(frame.Width, frame.Height);
        var sizes = standard.Where(side => side <= largest).ToList();
        return sizes.Count == 0 ? [standard[0]] : sizes;
    }

    public static async Task WriteAsync(IReadOnlyList<ImageFrame> squares, Stream output)
    {
        var images = new List<byte[]>();
        foreach (var square in squares) images.Add(await WicEncoder.EncodePngAsync(square));

        await output.WriteAsync(Header(squares, images));
        foreach (var image in images) await output.WriteAsync(image);
    }

    /// <summary>The ICONDIR and its entries. Separate from WriteAsync because spans can't live in async methods.</summary>
    private static byte[] Header(IReadOnlyList<ImageFrame> squares, IReadOnlyList<byte[]> images)
    {
        var header = new byte[6 + 16 * squares.Count];
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(2), 1); // type: icon
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(4), (ushort)squares.Count);
        var offset = header.Length;
        for (var i = 0; i < squares.Count; i++)
        {
            var entry = header.AsSpan(6 + 16 * i);
            entry[0] = squares[i].Width >= 256 ? (byte)0 : (byte)squares[i].Width; // 0 means 256
            entry[1] = squares[i].Height >= 256 ? (byte)0 : (byte)squares[i].Height;
            BinaryPrimitives.WriteUInt16LittleEndian(entry[4..], 1); // colour planes
            BinaryPrimitives.WriteUInt16LittleEndian(entry[6..], 32); // bits per pixel
            BinaryPrimitives.WriteInt32LittleEndian(entry[8..], images[i].Length);
            BinaryPrimitives.WriteInt32LittleEndian(entry[12..], offset);
            offset += images[i].Length;
        }
        return header;
    }
}
