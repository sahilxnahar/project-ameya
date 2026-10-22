namespace Ameya.Engines.Images;

internal enum ImageKind
{
    Single,
    /// <summary>Frames of an animation (GIF).</summary>
    Animated,
    /// <summary>Pages of a document (multi-page TIFF).</summary>
    Paged,
}

/// <summary>One decoded frame: 8-bit BGRA with straight (not premultiplied) alpha, top row first.</summary>
internal sealed class ImageFrame(int width, int height, byte[] pixels, double dpiX = 96, double dpiY = 96, int delayCentiseconds = 10)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Pixels { get; } = pixels;
    public double DpiX { get; } = dpiX > 0 ? dpiX : 96;
    public double DpiY { get; } = dpiY > 0 ? dpiY : 96;
    /// <summary>How long an animation frame shows, in hundredths of a second (GIF's unit).</summary>
    public int DelayCentiseconds { get; } = delayCentiseconds;

    public ImageFrame WithPixels(int newWidth, int newHeight, byte[] newPixels) =>
        new(newWidth, newHeight, newPixels, DpiX, DpiY, DelayCentiseconds);
}

internal sealed class DecodedImage(ImageKind kind, IReadOnlyList<ImageFrame> frames, int loopCount)
{
    public ImageKind Kind { get; } = kind;
    public IReadOnlyList<ImageFrame> Frames { get; } = frames;
    /// <summary>GIF loop count: 0 repeats forever.</summary>
    public int LoopCount { get; } = loopCount;
}
