using Ameya.Core.Conversion;
using Windows.Graphics.Imaging;

namespace Ameya.Engines.Images;

/// <summary>
/// Decodes pictures with the Windows Imaging Component (through Windows.Graphics.Imaging).
/// EXIF orientation is applied and colours are converted to sRGB by WIC itself. Every frame is
/// checked against the pixel limit before its pixels are decoded, against decompression bombs.
/// </summary>
internal static class WicDecoder
{
    /// <summary>Decoded bytes allowed for all frames together, well inside the worker's memory cap.</summary>
    private const long MaxTotalBytes = 1_500_000_000;

    public static async Task<DecodedImage> DecodeAsync(string path, string? sourceId, ConversionOptions options)
    {
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var stream = file.AsRandomAccessStream();
        BitmapDecoder decoder;
        try
        {
            decoder = await BitmapDecoder.CreateAsync(stream);
        }
        catch (Exception error) when (error is not ConversionException)
        {
            throw new ConversionException(UnreadableMessage(sourceId), error);
        }

        var codec = decoder.DecoderInformation.CodecId;
        var frameCount = (int)Math.Min(decoder.FrameCount, (uint)Math.Max(1, options.MaxFrames));
        if (codec == BitmapDecoder.GifDecoderId && frameCount > 1)
        {
            var frames = await GifAnimation.DecodeAsync(decoder, frameCount, options, MaxTotalBytes);
            return new DecodedImage(ImageKind.Animated, frames, await GifAnimation.LoopCountAsync(decoder));
        }
        if (codec == BitmapDecoder.TiffDecoderId && frameCount > 1)
        {
            var pages = new List<ImageFrame>();
            long total = 0;
            for (var i = 0; i < frameCount; i++)
            {
                var page = await DecodeFrameAsync(await decoder.GetFrameAsync((uint)i), sourceId, options);
                total += page.Pixels.Length;
                if (total > MaxTotalBytes) throw new ConversionException("The file has too many large pages to convert safely.");
                pages.Add(page);
            }
            return new DecodedImage(ImageKind.Paged, pages, 0);
        }
        var index = 0u;
        if (codec == BitmapDecoder.IcoDecoderId)
        {
            // An icon holds the same picture at several sizes: use the largest.
            long best = -1;
            for (var i = 0u; i < decoder.FrameCount; i++)
            {
                var candidate = await decoder.GetFrameAsync(i);
                var area = (long)candidate.PixelWidth * candidate.PixelHeight;
                if (area > best) (best, index) = (area, i);
            }
        }
        var frame = await DecodeFrameAsync(await decoder.GetFrameAsync(index), sourceId, options);
        return new DecodedImage(ImageKind.Single, [frame], 0);
    }

    internal static async Task<ImageFrame> DecodeFrameAsync(BitmapFrame frame, string? sourceId, ConversionOptions options, bool applyOrientation = true)
    {
        var width = applyOrientation ? frame.OrientedPixelWidth : frame.PixelWidth;
        var height = applyOrientation ? frame.OrientedPixelHeight : frame.PixelHeight;
        if ((long)width * height > options.MaxPixels)
        {
            throw new ConversionException(
                $"The picture is too large to convert safely ({(long)width * height / 1_000_000} million pixels; the limit is {options.MaxPixels / 1_000_000} million).");
        }
        var orientation = applyOrientation ? ExifOrientationMode.RespectExifOrientation : ExifOrientationMode.IgnoreExifOrientation;
        PixelDataProvider pixels;
        try
        {
            pixels = await frame.GetPixelDataAsync(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(), orientation, ColorManagementMode.ColorManageToSRgb);
        }
        catch (Exception colourError) when (colourError is not ConversionException)
        {
            // Some codecs can't colour-manage; their pixels are taken as they are.
            try
            {
                pixels = await frame.GetPixelDataAsync(
                    BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(), orientation, ColorManagementMode.DoNotColorManage);
            }
            catch (Exception error) when (error is not ConversionException)
            {
                throw new ConversionException(UnreadableMessage(sourceId), error);
            }
        }
        var bytes = pixels.DetachPixelData();
        if (bytes.Length != (long)width * height * 4) throw new ConversionException(UnreadableMessage(sourceId));
        return new ImageFrame((int)width, (int)height, bytes, frame.DpiX, frame.DpiY);
    }

    /// <summary>What to say when Windows can't read a file. HEIC, AVIF and WebP need free Store
    /// extensions; Ameya never downloads anything itself.</summary>
    internal static string UnreadableMessage(string? sourceId) => sourceId switch
    {
        "heic" or "heics" => "Windows can't open this HEIC photo yet. Install the free “HEIF Image Extensions” and “HEVC Video Extensions” from the Microsoft Store, then try again.",
        "avif" => "Windows can't open this AVIF picture yet. Install the free “AV1 Video Extension” from the Microsoft Store, then try again.",
        "webp" => "Windows can't open this WebP picture yet. Install the free “WebP Image Extensions” from the Microsoft Store, then try again.",
        _ => "This picture couldn't be read. It may be damaged, or in a variant Windows can't open.",
    };
}
