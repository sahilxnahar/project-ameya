using Ameya.Core.Conversion;
using Ameya.Core.Formats;
using Ameya.Core.Testing;
using Ameya.Core.Worker;
using Windows.Data.Pdf;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Xunit;

namespace Ameya.Tests;

/// <summary>Picture conversions through the real worker, checked by decoding the results with WIC.</summary>
[Collection("Worker")]
public class ImageConversionTests
{
    private static readonly WorkerRunner Runner = new(TestPaths.Worker) { Timeout = TimeSpan.FromSeconds(120) };

    private static async Task<(string Path, ConversionResult Result)> Convert(TestPaths.TempFolder folder, string input, string target)
    {
        var source = FormatDetection.Detect(input)!;
        var output = folder.Combine($"out-{Guid.NewGuid():N}.{FormatCatalog.Shared.Get(target).PreferredExtension}");
        var result = await Runner.RunAsync(input, output, new ConversionRequest { Source = source.Id, Target = target });
        Assert.Equal(target, FormatDetection.Detect(output)?.Id);
        return (output, result);
    }

    [Theory]
    [InlineData("jpeg")]
    [InlineData("tiff")]
    [InlineData("bmp")]
    [InlineData("gif")]
    [InlineData("ico")]
    [InlineData("pdf")]
    public async Task PngConvertsToEveryWindowsTarget(string target)
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(40, 30, transparentCorner: true));
        var (_, result) = await Convert(folder, input, target);
        if (!FormatCatalog.Shared.Get(target).SupportsAlpha || target == "gif")
        {
            Assert.Contains(NoteIds.TransparencyFilledWhite, result.Notes);
        }
    }

    [Fact]
    public async Task IconsHoldEveryStandardSizeUpToThePicture()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(64, 48, transparentCorner: true));
        var (output, result) = await Convert(folder, input, "ico");
        Assert.Equal(new[] { NoteIds.MadeSquareIcon }, result.Notes);
        var sizes = await FrameSizes(output);
        Assert.Equal(new[] { (16, 16), (24, 24), (32, 32), (48, 48), (64, 64) }, sizes.OrderBy(s => s.Item1));
    }

    [Fact]
    public async Task PdfPagesComeFromThePictures()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(96, 48, transparentCorner: true));
        var (output, _) = await Convert(folder, input, "pdf");
        Assert.Equal(1u, await PdfPageCount(output));
    }

    [Fact]
    public async Task MultiPageTiffKeepsItsPagesInPdfAndTiff()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("pages.tif", await Encode(BitmapEncoder.TiffEncoderId, 3, 20, 10));
        var (pdf, pdfResult) = await Convert(folder, input, "pdf");
        Assert.Equal(3u, await PdfPageCount(pdf));
        Assert.Equal(3, pdfResult.Frames);
        var (_, png) = await Convert(folder, input, "png");
        Assert.Equal(new[] { NoteIds.OnlyFirstPageKept }, png.Notes);
    }

    [Fact]
    public async Task AnimatedGifsStayAnimatedOrSayWhatHappened()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("anim.gif", await Encode(BitmapEncoder.GifEncoderId, 3, 24, 16));
        Assert.Equal(3, (await FrameSizes(input)).Count);

        var (_, png) = await Convert(folder, input, "png");
        Assert.Equal(new[] { NoteIds.OnlyFirstFrameKept }, png.Notes);

        var (tiff, tiffResult) = await Convert(folder, input, "tiff");
        Assert.Contains(NoteIds.AnimationBecamePages, tiffResult.Notes);
        Assert.Equal(3, (await FrameSizes(tiff)).Count);
    }

    [Fact]
    public async Task AnimatedGifsAreWrittenWithTheirTimingAndLoop()
    {
        // GIF to GIF isn't a conversion, so the writer (used by animation tools later) is tested directly.
        var frames = Enumerable.Range(0, 3).Select(i =>
            new Ameya.Engines.Images.ImageFrame(24, 16, Enumerable.Repeat((byte)(i * 90), 24 * 16 * 4).ToArray(), 96, 96, 20 + i)).ToList();
        using var memory = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.GifEncoderId, memory);
        await Ameya.Engines.Images.GifAnimation.WriteAsync(encoder, frames, loopCount: 0);
        await encoder.FlushAsync();
        memory.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(memory);
        var decoded = await Ameya.Engines.Images.GifAnimation.DecodeAsync(decoder, (int)decoder.FrameCount, new ConversionOptions(), long.MaxValue);
        Assert.Equal(3, decoded.Count);
        Assert.Equal(new[] { 20, 21, 22 }, decoded.Select(f => f.DelayCentiseconds));
        Assert.Equal(0, await Ameya.Engines.Images.GifAnimation.LoopCountAsync(decoder));
    }

    [Fact]
    public async Task ExifOrientationIsApplied()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("turned.jpg", await Encode(BitmapEncoder.JpegEncoderId, 1, 40, 20, orientation: 6));
        var (output, _) = await Convert(folder, input, "png");
        Assert.Equal(new[] { (20, 40) }, await FrameSizes(output));
    }

    [Fact]
    public async Task OpaquePicturesWithAnAlphaChannelGetNoTransparencyNote()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("opaque.png", TestImages.Png(20, 20, withAlphaChannel: true));
        var (_, result) = await Convert(folder, input, "jpeg");
        Assert.DoesNotContain(NoteIds.TransparencyFilledWhite, result.Notes);
    }

    /// <summary>Builds a test file with WIC: frames of solid colour, optionally with an EXIF orientation.</summary>
    private static async Task<byte[]> Encode(Guid encoderId, int frames, int width, int height, ushort? orientation = null)
    {
        using var memory = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(encoderId, memory);
        for (var i = 0; i < frames; i++)
        {
            if (i > 0) await encoder.GoToNextFrameAsync();
            var pixels = new byte[width * height * 4];
            for (var p = 0; p < pixels.Length; p += 4)
            {
                pixels[p] = (byte)(i * 80);
                pixels[p + 1] = (byte)(p % 255);
                pixels[p + 2] = 200;
                pixels[p + 3] = 255;
            }
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
            if (orientation is { } value)
            {
                await encoder.BitmapProperties.SetPropertiesAsync(new BitmapPropertySet
                {
                    ["System.Photo.Orientation"] = new BitmapTypedValue(value, PropertyType.UInt16),
                });
            }
        }
        await encoder.FlushAsync();
        memory.Seek(0);
        using var stream = memory.AsStreamForRead();
        using var copy = new MemoryStream();
        await stream.CopyToAsync(copy);
        return copy.ToArray();
    }

    private static async Task<List<(int, int)>> FrameSizes(string path)
    {
        await using var file = File.OpenRead(path);
        var decoder = await BitmapDecoder.CreateAsync(file.AsRandomAccessStream());
        var sizes = new List<(int, int)>();
        for (var i = 0u; i < decoder.FrameCount; i++)
        {
            var frame = await decoder.GetFrameAsync(i);
            sizes.Add(((int)frame.OrientedPixelWidth, (int)frame.OrientedPixelHeight));
        }
        return sizes;
    }

    private static async Task<uint> PdfPageCount(string path)
    {
        await using var file = File.OpenRead(path);
        var document = await PdfDocument.LoadFromStreamAsync(file.AsRandomAccessStream());
        return document.PageCount;
    }
}
