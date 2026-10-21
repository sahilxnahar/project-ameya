using System.Text.Json;
using Ameya.Core.Formats;
using Xunit;

namespace Ameya.Tests;

/// <summary>Every detection vector exported by the Mac (spec/detection-vectors.json) must give the same answer here.</summary>
public class DetectionTests
{
    public static TheoryData<string, string, string, string?> Vectors()
    {
        var data = new TheoryData<string, string, string, string?>();
        using var document = JsonDocument.Parse(File.ReadAllText(TestPaths.Spec("detection-vectors.json")));
        foreach (var vector in document.RootElement.GetProperty("vectors").EnumerateArray())
        {
            var expected = vector.TryGetProperty("expected", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            data.Add(vector.GetProperty("name").GetString()!, vector.GetProperty("hex").GetString()!, vector.GetProperty("fileName").GetString()!, expected);
        }
        return data;
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void MatchesTheMac(string name, string hex, string fileName, string? expected)
    {
        var header = Convert.FromHexString(hex);
        var detected = FormatDetection.RefineCompressed(FormatDetection.Detect(header, FormatDetection.PathExtension(fileName)), fileName);
        Assert.True(expected == detected?.Id, $"{name}: expected {expected ?? "nothing"}, got {detected?.Id ?? "nothing"}");
    }

    [Fact]
    public void ThereAreEnoughVectors() => Assert.True(Vectors().Count() > 150);

    [Fact]
    public void DetectsFilesOnDisk()
    {
        using var folder = new TestPaths.TempFolder();
        // Contents win over the extension.
        var png = folder.File("really-a-png.jpg", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);
        Assert.Equal("png", FormatDetection.Detect(png)?.Id);
        var unknown = folder.File("notes.weird", "hello"u8.ToArray());
        Assert.Null(FormatDetection.Detect(unknown));
        Assert.Equal("other", FormatDetection.DetectForConversion(unknown)?.Id);
        var empty = folder.File("empty.weird", []);
        Assert.Null(FormatDetection.DetectForConversion(empty));
    }

    [Theory]
    [InlineData("a.tar.gz", "gz")]
    [InlineData("photo.JPG", "JPG")]
    [InlineData("noext", "")]
    [InlineData("trailing.", "")]
    public void PathExtensionMatchesFoundation(string name, string expected) =>
        Assert.Equal(expected, FormatDetection.PathExtension(name));

    [Fact]
    public void GzipStoredNameIsMadeSafe()
    {
        byte[] header = [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03, .. "dir/.report.pdf"u8.ToArray(), 0, 1, 2];
        Assert.Equal("report.pdf", FormatDetection.GzipOriginalName(header));
        byte[] noName = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03, 1, 2];
        Assert.Null(FormatDetection.GzipOriginalName(noName));
    }
}
