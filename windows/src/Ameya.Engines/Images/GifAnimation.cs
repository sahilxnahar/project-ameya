using Ameya.Core.Conversion;
using Windows.Graphics.Imaging;

namespace Ameya.Engines.Images;

/// <summary>
/// Reads and writes animated GIFs. WIC hands back each GIF frame as the small rectangle that
/// changed, so frames are composed onto a full canvas here, honouring each frame's disposal method.
/// </summary>
internal static class GifAnimation
{
    public static async Task<IReadOnlyList<ImageFrame>> DecodeAsync(BitmapDecoder decoder, int frameCount, ConversionOptions options, long maxTotalBytes)
    {
        var container = decoder.BitmapContainerProperties;
        var width = await IntProperty(container, "/logscrdesc/Width") ?? (int)decoder.PixelWidth;
        var height = await IntProperty(container, "/logscrdesc/Height") ?? (int)decoder.PixelHeight;
        if ((long)width * height > options.MaxPixels || width <= 0 || height <= 0)
        {
            throw new ConversionException("The animation is too large to convert safely.");
        }
        if ((long)width * height * 4 * frameCount > maxTotalBytes)
        {
            throw new ConversionException("The animation has too many large frames to convert safely.");
        }

        var canvas = new byte[width * height * 4]; // starts fully transparent
        var frames = new List<ImageFrame>(frameCount);
        for (var i = 0; i < frameCount; i++)
        {
            var frame = await decoder.GetFrameAsync((uint)i);
            var properties = frame.BitmapProperties;
            var left = await IntProperty(properties, "/imgdesc/Left") ?? 0;
            var top = await IntProperty(properties, "/imgdesc/Top") ?? 0;
            var delay = await IntProperty(properties, "/grctlext/Delay") ?? 10;
            var disposal = await IntProperty(properties, "/grctlext/Disposal") ?? 0;
            var patch = await WicDecoder.DecodeFrameAsync(frame, "gif", options, applyOrientation: false);

            var previous = disposal == 3 ? (byte[])canvas.Clone() : null;
            Draw(patch, canvas, width, height, left, top);
            frames.Add(new ImageFrame(width, height, (byte[])canvas.Clone(), 96, 96, delay));

            if (disposal == 2) Clear(canvas, width, height, left, top, patch.Width, patch.Height); // restore to background
            else if (previous is not null) canvas = previous; // restore to previous
        }
        return frames;
    }

    /// <summary>The NETSCAPE2.0 loop count: 0 repeats forever. A GIF without one plays once.</summary>
    public static async Task<int> LoopCountAsync(BitmapDecoder decoder)
    {
        var data = await Property(decoder.BitmapContainerProperties, "/appext/Data") as byte[];
        return data is { Length: >= 4 } && data[0] >= 3 && data[1] == 1 ? data[2] | (data[3] << 8) : 1;
    }

    /// <summary>Writes full-canvas frames as an animated GIF with their delays and loop count.</summary>
    public static async Task WriteAsync(BitmapEncoder encoder, IReadOnlyList<ImageFrame> frames, int loopCount)
    {
        if (loopCount != 1)
        {
            await encoder.BitmapContainerProperties.SetPropertiesAsync(new BitmapPropertySet
            {
                ["/appext/Application"] = new BitmapTypedValue(System.Text.Encoding.ASCII.GetBytes("NETSCAPE2.0"), Windows.Foundation.PropertyType.UInt8Array),
                ["/appext/Data"] = new BitmapTypedValue(
                    new byte[] { 3, 1, (byte)(loopCount & 0xFF), (byte)((loopCount >> 8) & 0xFF), 0 }, Windows.Foundation.PropertyType.UInt8Array),
            });
        }
        for (var i = 0; i < frames.Count; i++)
        {
            if (i > 0) await encoder.GoToNextFrameAsync();
            var frame = frames[i];
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)frame.Width, (uint)frame.Height, frame.DpiX, frame.DpiY, frame.Pixels);
            await encoder.BitmapProperties.SetPropertiesAsync(new BitmapPropertySet
            {
                ["/grctlext/Delay"] = new BitmapTypedValue((ushort)Math.Clamp(frame.DelayCentiseconds, 0, ushort.MaxValue), Windows.Foundation.PropertyType.UInt16),
            });
        }
    }

    private static void Draw(ImageFrame patch, byte[] canvas, int width, int height, int left, int top)
    {
        for (var y = 0; y < patch.Height; y++)
        {
            var cy = top + y;
            if (cy < 0 || cy >= height) continue;
            for (var x = 0; x < patch.Width; x++)
            {
                var cx = left + x;
                if (cx < 0 || cx >= width) continue;
                var p = (y * patch.Width + x) * 4;
                if (patch.Pixels[p + 3] == 0) continue; // GIF transparency is all or nothing
                Buffer.BlockCopy(patch.Pixels, p, canvas, (cy * width + cx) * 4, 4);
            }
        }
    }

    private static void Clear(byte[] canvas, int width, int height, int left, int top, int patchWidth, int patchHeight)
    {
        for (var y = Math.Max(0, top); y < Math.Min(height, top + patchHeight); y++)
        {
            var start = Math.Max(0, left);
            var end = Math.Min(width, left + patchWidth);
            if (end > start) Array.Clear(canvas, (y * width + start) * 4, (end - start) * 4);
        }
    }

    private static async Task<int?> IntProperty(BitmapPropertiesView view, string key) =>
        await Property(view, key) is { } value && value is IConvertible ? Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture) : null;

    /// <summary>One metadata value, or null when the file doesn't have it (WIC reports that as an error).</summary>
    private static async Task<object?> Property(BitmapPropertiesView view, string key)
    {
        try
        {
            var values = await view.GetPropertiesAsync([key]);
            return values.TryGetValue(key, out var value) ? value.Value : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
