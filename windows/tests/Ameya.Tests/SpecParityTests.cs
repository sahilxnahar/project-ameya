using System.Text.Json;
using Ameya.Core.Conversion;
using Ameya.Core.Formats;
using Ameya.Engines;
using Xunit;

namespace Ameya.Tests;

/// <summary>
/// The Windows core must agree with the Mac on formats, routes and notes. The embedded spec is
/// checked against the copy on disk, and a sample of answers is asserted independently, so a
/// broken export or loader can't pass silently.
/// </summary>
public class SpecParityTests
{
    private static readonly FormatCatalog Catalog = FormatCatalog.Shared;
    private static FileFormat F(string id) => Catalog.Get(id);

    [Fact]
    public void EmbeddedSpecMatchesTheCommittedFile()
    {
        var onDisk = FormatCatalog.Parse(File.ReadAllText(TestPaths.Spec("formats.json")));
        Assert.Equal(onDisk.All.Select(f => f.Id), Catalog.All.Select(f => f.Id));
        Assert.Equal(onDisk.Routes.Count, Catalog.Routes.Count);
    }

    [Fact]
    public void EveryFormatAndRouteFromTheSpecIsLoaded()
    {
        using var spec = JsonDocument.Parse(File.ReadAllText(TestPaths.Spec("formats.json")));
        var root = spec.RootElement;
        Assert.Equal(root.GetProperty("formats").GetArrayLength(), Catalog.All.Count);
        foreach (var route in root.GetProperty("routes").EnumerateArray())
        {
            var from = F(route.GetProperty("from").GetString()!);
            var to = F(route.GetProperty("to").GetString()!);
            var loaded = Catalog.FindRoute(from, to);
            Assert.NotNull(loaded);
            Assert.Equal(route.GetProperty("possibleLosses").EnumerateArray().Select(n => n.GetString()!), loaded.PossibleLosses);
            Assert.Equal(route.GetProperty("needsFFmpeg").GetBoolean(), loaded.NeedsFFmpeg);
        }
    }

    [Fact]
    public void EveryNoteInARouteHasAMessage()
    {
        foreach (var route in Catalog.Routes)
        {
            foreach (var note in route.PossibleLosses) Assert.True(Catalog.IsKnownNote(note), note);
        }
        foreach (var note in NoteIds.All) Assert.True(Catalog.IsKnownNote(note), $"engine note {note} is not in the spec");
        Assert.Equal("Transparent areas were filled with white.", Catalog.NoteMessage(NoteIds.TransparencyFilledWhite));
    }

    [Theory]
    [InlineData("png", "jpeg", new[] { "transparencyFilledWhite", "onlyFirstFrameKept" })]
    [InlineData("gif", "ico", new[] { "madeSquareIcon" })]
    [InlineData("tiff", "jpeg", new[] { "transparencyFilledWhite", "onlyFirstPageKept" })]
    [InlineData("gif", "tiff", new[] { "animationBecamePages" })]
    [InlineData("jpeg", "png", new string[0])]
    [InlineData("srt", "lrc", new[] { "subtitleStylingRemoved", "subtitleEndTimesDropped" })]
    [InlineData("pdf", "md", new[] { "onlyTextKept", "markdownSimplified" })]
    public void PossibleLossesMatchTheMac(string from, string to, string[] expected)
    {
        var matrix = new ConversionMatrix(Catalog, Catalog.All, Catalog.All, ffmpeg: true);
        Assert.Equal(expected, matrix.PossibleLosses(F(from), F(to)));
    }

    [Theory]
    [InlineData("jpeg", "pdf", true)]
    [InlineData("heic", "jpeg", true)]
    [InlineData("pdf", "jpeg", true)]
    [InlineData("jpeg", "jpeg", false)]
    [InlineData("png", "rar", false)]
    [InlineData("mp4", "flv", false)]
    [InlineData("txt", "png", true)]
    public void RoutesMatchTheMac(string from, string to, bool expected) =>
        Assert.Equal(expected, ConversionMatrix.CanConvert(Catalog, F(from), F(to), ffmpeg: true));

    [Fact]
    public void FFmpegRoutesNeedTheHelper()
    {
        Assert.True(ConversionMatrix.CanConvert(Catalog, F("mkv"), F("mp4"), ffmpeg: true));
        Assert.False(ConversionMatrix.CanConvert(Catalog, F("mkv"), F("mp4"), ffmpeg: false));
    }

    [Fact]
    public void FormatFactsMatchTheMac()
    {
        Assert.Equal("JPEG", F("jpeg").DisplayName);
        Assert.Equal("jpg", F("jpeg").PreferredExtension);
        Assert.Equal("tar.gz", F("tgz").PreferredExtension);
        Assert.Equal("m4a", F("alac").PreferredExtension);
        Assert.Equal(F("jpeg"), Catalog.FromExtension("JPEG"));
        Assert.Equal(F("tiff"), Catalog.FromExtension("tif"));
        Assert.Null(Catalog.FromExtension("xyz"));
        Assert.Equal(TimeSpan.FromSeconds(120), Catalog.Timeout(F("png")));
        Assert.Equal(TimeSpan.FromSeconds(3600), Catalog.Timeout(F("mp4")));
        Assert.True(F("png").SupportsAlpha);
        Assert.False(F("jpeg").SupportsAlpha);
        Assert.True(F("tiff").SupportsPages);
        Assert.True(F("ico").IsIcon);
    }

    [Fact]
    public void WindowsNeverOffersARouteTheSpecDoesNotHave()
    {
        var matrix = WindowsCapabilities.Matrix();
        foreach (var source in Catalog.All)
        {
            foreach (var target in matrix.Targets(source))
            {
                Assert.NotNull(Catalog.FindRoute(source, target));
                Assert.Contains(target.Id, WindowsCapabilities.WritableIds());
                Assert.Contains(source.Id, WindowsCapabilities.ReadableIds());
            }
        }
    }

    [Fact]
    public void PngTargetsOnWindowsAreTheImplementedOnes()
    {
        var targets = WindowsCapabilities.Matrix().Targets(F("png")).Select(f => f.Id);
        Assert.Equal(new[] { "jpeg", "tiff", "bmp", "gif", "ico", "pdf" }, targets);
    }

    [Fact]
    public void CommonTargetsAreTheIntersection()
    {
        var matrix = WindowsCapabilities.Matrix();
        var common = matrix.CommonTargets([F("png"), F("jpeg")]).Select(f => f.Id).ToList();
        Assert.DoesNotContain("png", common);
        Assert.DoesNotContain("jpeg", common);
        Assert.Contains("pdf", common);
    }
}
