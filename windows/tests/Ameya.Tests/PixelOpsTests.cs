using Ameya.Engines.Images;
using Xunit;

namespace Ameya.Tests;

public class PixelOpsTests
{
    private static ImageFrame Solid(int width, int height, byte alpha) =>
        new(width, height, Enumerable.Range(0, width * height).SelectMany(_ => new byte[] { 0, 0, 0, alpha }).ToArray());

    [Fact]
    public void OnlyRealTransparencyCounts()
    {
        Assert.False(PixelOps.HasTransparentPixels(Solid(4, 4, 255)));
        var frame = Solid(4, 4, 255);
        frame.Pixels[^1] = 254; // one barely see-through pixel
        Assert.True(PixelOps.HasTransparentPixels(frame));
    }

    [Fact]
    public void FlatteningPutsTransparentAreasOnWhite()
    {
        var flat = PixelOps.FlattenOnWhite(Solid(2, 2, 0));
        Assert.All(flat.Pixels, value => Assert.Equal(255, value));
        var half = PixelOps.FlattenOnWhite(Solid(1, 1, 128));
        Assert.Equal(new byte[] { 127, 127, 127, 255 }, half.Pixels);
    }

    [Fact]
    public void IconsAreSquareAndCentred()
    {
        var icon = PixelOps.SquareIcon(Solid(40, 20, 255), 16);
        Assert.Equal((16, 16), (icon.Width, icon.Height));
        Assert.Equal(0, icon.Pixels[3]); // top-left corner is padding
        Assert.Equal(255, icon.Pixels[(8 * 16 + 8) * 4 + 3]); // centre is the picture
    }

    [Fact]
    public void ResizingAveragesColours()
    {
        var frame = new ImageFrame(2, 1, [0, 0, 0, 255, 255, 255, 255, 255]);
        var resized = PixelOps.Resize(frame, 1, 1);
        Assert.InRange(resized.Pixels[0], (byte)126, (byte)129);
        Assert.Equal(255, resized.Pixels[3]);
    }
}
