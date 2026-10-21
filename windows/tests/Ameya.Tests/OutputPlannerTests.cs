using Ameya.Core.Files;
using Ameya.Core.Formats;
using Xunit;

namespace Ameya.Tests;

public class OutputPlannerTests
{
    private static FileFormat F(string id) => FormatCatalog.Shared.Get(id);
    private static readonly string Folder = Path.Combine(Path.GetTempPath(), "out");

    private static string Plan(string source, string target, params string[] taken) =>
        Path.GetFileName(OutputPlanner.Destination(Path.Combine(@"C:\in", source), F(target), Folder,
            path => taken.Contains(Path.GetFileName(path), StringComparer.OrdinalIgnoreCase)));

    [Fact]
    public void UsesTheTargetExtension() => Assert.Equal("photo.png", Plan("photo.jpg", "png"));

    [Fact]
    public void NeverPicksATakenName()
    {
        Assert.Equal("photo 2.png", Plan("photo.jpg", "png", "photo.png"));
        Assert.Equal("photo 3.png", Plan("photo.jpg", "png", "photo.png", "PHOTO 2.png"));
    }

    [Fact]
    public void CompoundArchiveExtensionsGoWhole() => Assert.Equal("photos.zip", Plan("photos.tar.gz", "zip"));

    [Fact]
    public void HiddenNamesBecomeVisible() => Assert.Equal("hidden.jpg", Plan(".hidden.png", "jpeg"));

    [Fact]
    public void DotFilesKeepTheirNameVisibly() => Assert.Equal("png.jpg", Plan(".png", "jpeg"));

    [Fact]
    public void CompressingKeepsTheWholeName()
    {
        Assert.Equal("report.pdf.gz", Plan("report.pdf", "gz"));
        Assert.Equal("README.xz", Plan("README", "xz"));
    }

    [Fact]
    public void DecompressingGivesTheNameBack()
    {
        Assert.Equal("report.pdf", Plan("report.pdf.gz", "decompressed"));
        Assert.Equal("notes", Plan("notes.bz2", "decompressed"));
    }

    [Fact]
    public void DecompressingUsesTheNameStoredInTheGzipHeader()
    {
        using var folder = new TestPaths.TempFolder();
        byte[] gzip = [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03, .. "report.pdf"u8.ToArray(), 0, 1, 2];
        var source = folder.File("download.gz", gzip);
        Assert.Equal("report.pdf", Path.GetFileName(OutputPlanner.Destination(source, F("decompressed"), folder.Path)));
    }

    [Fact]
    public void SuffixesAreMadeSafeForWindows() =>
        Assert.Equal("photo a-b.jpg", Path.GetFileName(OutputPlanner.Destination(@"C:\in\photo.png", F("jpeg"), Folder, _ => false, "a/b")));

    [Fact]
    public void ChecksTheDiskForFilesAndFolders()
    {
        using var folder = new TestPaths.TempFolder();
        File.WriteAllText(folder.Combine("photo.png"), "x");
        Directory.CreateDirectory(folder.Combine("photo 2.png"));
        Assert.Equal("photo 3.png", Path.GetFileName(OutputPlanner.Destination(@"C:\in\photo.jpg", F("png"), folder.Path)));
        Assert.Equal("photo (pages)", Path.GetFileName(OutputPlanner.FolderDestination(@"C:\in\photo.pdf", "(pages)", folder.Path)));
    }

    [Fact]
    public void DefaultFolderIsDownloadsAmeya() =>
        Assert.EndsWith(Path.Combine("Downloads", "Ameya"), OutputPlanner.DefaultOutputFolder(), StringComparison.OrdinalIgnoreCase);
}
