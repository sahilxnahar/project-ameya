namespace Ameya.Engines.Images;

/// <summary>Pixel work done in plain C#, so it behaves the same whatever codecs a PC has.</summary>
internal static class PixelOps
{
    /// <summary>True only if some pixel is not fully opaque. Decoders often give opaque photos an
    /// alpha channel, so having the channel proves nothing (same rule as the Mac's hasTransparentPixels).
    /// Every pixel is checked: the frame is already in memory, and a single see-through pixel counts.</summary>
    public static bool HasTransparentPixels(ImageFrame frame)
    {
        var pixels = frame.Pixels;
        for (var i = 3; i < pixels.Length; i += 4)
        {
            if (pixels[i] != 255) return true;
        }
        return false;
    }

    /// <summary>The frame drawn onto white, fully opaque.</summary>
    public static ImageFrame FlattenOnWhite(ImageFrame frame)
    {
        var source = frame.Pixels;
        var flat = new byte[source.Length];
        for (var i = 0; i < source.Length; i += 4)
        {
            var alpha = source[i + 3];
            for (var c = 0; c < 3; c++)
            {
                flat[i + c] = (byte)((source[i + c] * alpha + 255 * (255 - alpha) + 127) / 255);
            }
            flat[i + 3] = 255;
        }
        return frame.WithPixels(frame.Width, frame.Height, flat);
    }

    /// <summary>Resizes with an area-averaging (box) filter on premultiplied colour, so edges of
    /// transparent areas don't pick up dark fringes. Enlarging falls back to the nearest pixel.</summary>
    public static ImageFrame Resize(ImageFrame frame, int width, int height)
    {
        var columns = Weights(frame.Width, width);
        var rows = Weights(frame.Height, height);
        var source = frame.Pixels;

        // Horizontal pass into premultiplied floats.
        var horizontal = new float[frame.Height * width * 4];
        for (var y = 0; y < frame.Height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                float b = 0, g = 0, r = 0, a = 0;
                foreach (var (index, weight) in columns[x])
                {
                    var p = (y * frame.Width + index) * 4;
                    var alpha = source[p + 3] / 255f;
                    b += source[p] * alpha * weight;
                    g += source[p + 1] * alpha * weight;
                    r += source[p + 2] * alpha * weight;
                    a += source[p + 3] * weight;
                }
                var o = (y * width + x) * 4;
                horizontal[o] = b;
                horizontal[o + 1] = g;
                horizontal[o + 2] = r;
                horizontal[o + 3] = a;
            }
        }

        // Vertical pass, then back to straight alpha.
        var result = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                float b = 0, g = 0, r = 0, a = 0;
                foreach (var (index, weight) in rows[y])
                {
                    var p = (index * width + x) * 4;
                    b += horizontal[p] * weight;
                    g += horizontal[p + 1] * weight;
                    r += horizontal[p + 2] * weight;
                    a += horizontal[p + 3] * weight;
                }
                var o = (y * width + x) * 4;
                var unpremultiply = a > 0 ? 255f / a : 0;
                result[o] = ToByte(b * unpremultiply);
                result[o + 1] = ToByte(g * unpremultiply);
                result[o + 2] = ToByte(r * unpremultiply);
                result[o + 3] = ToByte(a);
            }
        }
        return frame.WithPixels(width, height, result);
    }

    /// <summary>The frame scaled to fit a transparent square of the given side, centred.</summary>
    public static ImageFrame SquareIcon(ImageFrame frame, int side)
    {
        var scale = (double)side / Math.Max(frame.Width, frame.Height);
        var width = Math.Clamp((int)Math.Round(frame.Width * scale), 1, side);
        var height = Math.Clamp((int)Math.Round(frame.Height * scale), 1, side);
        var scaled = Resize(frame, width, height);
        var square = new byte[side * side * 4];
        var left = (side - width) / 2;
        var top = (side - height) / 2;
        for (var y = 0; y < height; y++)
        {
            Buffer.BlockCopy(scaled.Pixels, y * width * 4, square, ((top + y) * side + left) * 4, width * 4);
        }
        return new ImageFrame(side, side, square);
    }

    private static byte ToByte(float value) => (byte)Math.Clamp((int)MathF.Round(value), 0, 255);

    /// <summary>For each destination index, the source indices it covers and how much of each.</summary>
    private static (int Index, float Weight)[][] Weights(int source, int destination)
    {
        var scale = (double)source / destination;
        var result = new (int, float)[destination][];
        for (var d = 0; d < destination; d++)
        {
            var start = d * scale;
            var end = (d + 1) * scale;
            var list = new List<(int, float)>();
            var last = Math.Min(source, (int)Math.Ceiling(end));
            for (var s = (int)Math.Floor(start); s < last; s++)
            {
                var overlap = Math.Min(end, s + 1) - Math.Max(start, s);
                if (overlap > 1e-9) list.Add((s, (float)overlap));
            }
            if (list.Count == 0) list.Add((Math.Min(source - 1, (int)start), 1));
            var total = list.Sum(entry => entry.Item2);
            result[d] = list.Select(entry => (entry.Item1, entry.Item2 / total)).ToArray();
        }
        return result;
    }
}
