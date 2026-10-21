using System.Text;
using Ameya.Core.Files;
using Xunit;

namespace Ameya.Tests;

public class TarStreamTests
{
    private static byte[] Sample()
    {
        using var stream = new MemoryStream();
        var writer = new TarStream.Writer(stream);
        writer.Add("0.png", "first file\n"u8);
        writer.Add("page 2 – ü.txt", Enumerable.Repeat((byte)0x41, 600).ToArray());
        writer.Finish();
        return stream.ToArray();
    }

    [Fact]
    public void WritesTheSameBytesAsTheMac() =>
        Assert.Equal(File.ReadAllBytes(TestPaths.Spec("tar-sample.tar")), Sample());

    [Fact]
    public void ReadsTheMacSample()
    {
        using var folder = new TestPaths.TempFolder();
        using var stream = File.OpenRead(TestPaths.Spec("tar-sample.tar"));
        var names = TarStream.Extract(stream, folder.Path);
        Assert.Equal(new[] { "0.png", "page 2 – ü.txt" }, names);
        Assert.Equal("first file\n", File.ReadAllText(folder.Combine("0.png")));
        Assert.Equal(600, new FileInfo(folder.Combine("page 2 – ü.txt")).Length);
    }

    [Theory]
    [InlineData("../evil")]
    [InlineData("a/b")]
    [InlineData("a\\b")]
    [InlineData(".hidden")]
    [InlineData("")]
    public void RejectsUnsafeNamesWhenWriting(string name)
    {
        var writer = new TarStream.Writer(new MemoryStream());
        Assert.Throws<TarStreamException>(() => writer.Add(name, "x"u8));
    }

    [Theory]
    [InlineData("CON.txt")]
    [InlineData("a:stream")]
    [InlineData("trailing.")]
    [InlineData("LPT1")]
    public void RejectsNamesWindowsCannotHoldWhenReading(string name)
    {
        using var folder = new TestPaths.TempFolder();
        var bytes = Stream(name, "x"u8.ToArray());
        Assert.Throws<TarStreamException>(() => TarStream.Extract(new MemoryStream(bytes), folder.Path));
    }

    [Fact]
    public void RejectsADamagedChecksum()
    {
        var bytes = Sample();
        bytes[0] ^= 0x01;
        using var folder = new TestPaths.TempFolder();
        var error = Assert.Throws<TarStreamException>(() => TarStream.Extract(new MemoryStream(bytes), folder.Path));
        Assert.Contains("checksum", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsATruncatedStream()
    {
        var bytes = Sample()[..700];
        using var folder = new TestPaths.TempFolder();
        Assert.Throws<TarStreamException>(() => TarStream.Extract(new MemoryStream(bytes), folder.Path));
    }

    [Fact]
    public void RejectsDuplicateNames()
    {
        var bytes = Stream("a.txt", "1"u8.ToArray(), "a.txt");
        using var folder = new TestPaths.TempFolder();
        Assert.Throws<TarStreamException>(() => TarStream.Extract(new MemoryStream(bytes), folder.Path));
    }

    [Fact]
    public void NeverReplacesAnExistingFile()
    {
        using var folder = new TestPaths.TempFolder();
        File.WriteAllText(folder.Combine("0.png"), "mine");
        using var stream = File.OpenRead(TestPaths.Spec("tar-sample.tar"));
        Assert.ThrowsAny<IOException>(() => TarStream.Extract(stream, folder.Path));
        Assert.Equal("mine", File.ReadAllText(folder.Combine("0.png")));
    }

    [Fact]
    public void CapsEntriesAndBytes()
    {
        using var folder = new TestPaths.TempFolder();
        Assert.Throws<TarStreamException>(() => TarStream.Extract(new MemoryStream(Sample()), folder.Path, new TarStream.Limits(MaxEntries: 1)));
        using var other = new TestPaths.TempFolder();
        Assert.Throws<TarStreamException>(() => TarStream.Extract(new MemoryStream(Sample()), other.Path, new TarStream.Limits(MaxTotalBytes: 100)));
    }

    [Theory]
    [InlineData(0L)]
    [InlineData(600L)]
    [InlineData(0x1FFFFFFFFL)]
    [InlineData(0x200000000L)]
    [InlineData(long.MaxValue)]
    public void SizesRoundTrip(long size) => Assert.Equal(size, TarStream.DecodeSize(TarStream.EncodeSize(size)));

    [Fact]
    public void LargeSizesUseBase256()
    {
        Assert.Equal(0x80, TarStream.EncodeSize(0x200000000L)[0]);
        Assert.Equal("77777777777", Encoding.ASCII.GetString(TarStream.EncodeSize(0x1FFFFFFFFL), 0, 11));
    }

    /// <summary>A stream with entries whose names skip the writer's checks (to test the reader).</summary>
    private static byte[] Stream(string name, byte[] data, string? secondName = null)
    {
        using var stream = new MemoryStream();
        foreach (var entry in secondName is null ? new[] { name } : new[] { name, secondName })
        {
            stream.Write(TarStream.Header(entry, data.Length));
            stream.Write(data);
            stream.Write(new byte[TarStream.BlockSize - data.Length % TarStream.BlockSize]);
        }
        stream.Write(new byte[2 * TarStream.BlockSize]);
        return stream.ToArray();
    }
}
