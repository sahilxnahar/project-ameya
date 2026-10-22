using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Ameya.Engines.Images;

/// <summary>Encodes frames with WIC. JPEG, PNG, TIFF (several pages), BMP and GIF (animated) are
/// built into every Windows 10 and 11.</summary>
internal static class WicEncoder
{
    public const double DefaultQuality = 0.85;

    public static bool CanEncode(string targetId) => targetId is "jpeg" or "png" or "tiff" or "bmp" or "gif";

    public static async Task EncodeAsync(IReadOnlyList<ImageFrame> frames, string targetId, bool animated, int loopCount, double? quality, Stream output)
    {
        using var memory = new InMemoryRandomAccessStream();
        var encoder = targetId == "jpeg"
            ? await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, memory, new BitmapPropertySet
            {
                ["ImageQuality"] = new BitmapTypedValue((float)Math.Clamp(quality ?? DefaultQuality, 0, 1), Windows.Foundation.PropertyType.Single),
            })
            : await BitmapEncoder.CreateAsync(EncoderId(targetId), memory);

        if (targetId == "gif" && animated && frames.Count > 1)
        {
            await GifAnimation.WriteAsync(encoder, frames, loopCount);
        }
        else
        {
            // Only TIFF keeps several pages; everything else writes the first frame.
            var count = targetId == "tiff" ? frames.Count : 1;
            var alpha = targetId is "jpeg" or "bmp" or "gif" ? BitmapAlphaMode.Ignore : BitmapAlphaMode.Straight;
            for (var i = 0; i < count; i++)
            {
                if (i > 0) await encoder.GoToNextFrameAsync();
                var frame = frames[i];
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, alpha, (uint)frame.Width, (uint)frame.Height, frame.DpiX, frame.DpiY, frame.Pixels);
            }
        }
        await encoder.FlushAsync();

        memory.Seek(0);
        await using var encoded = memory.AsStreamForRead();
        await encoded.CopyToAsync(output);
    }

    public static async Task<byte[]> EncodePngAsync(ImageFrame frame)
    {
        using var output = new MemoryStream();
        await EncodeAsync([frame], "png", animated: false, loopCount: 0, quality: null, output);
        return output.ToArray();
    }

    private static Guid EncoderId(string targetId) => targetId switch
    {
        "png" => BitmapEncoder.PngEncoderId,
        "tiff" => BitmapEncoder.TiffEncoderId,
        "bmp" => BitmapEncoder.BmpEncoderId,
        "gif" => BitmapEncoder.GifEncoderId,
        _ => throw new ConversionException($"Ameya for Windows can't write {targetId} pictures yet."),
    };
}
