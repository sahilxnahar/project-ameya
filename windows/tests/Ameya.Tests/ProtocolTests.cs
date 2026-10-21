using System.Runtime.InteropServices;
using Ameya.Core.Conversion;
using Ameya.Core.Worker;
using Xunit;

namespace Ameya.Tests;

public class ProtocolTests
{
    [Fact]
    public void RequestJsonMatchesTheMacShape()
    {
        var json = WorkerProtocol.Encode(new ConversionRequest { Source = "png", Target = "jpeg" });
        Assert.Contains("\"source\":\"png\"", json, StringComparison.Ordinal);
        Assert.Contains("\"target\":\"jpeg\"", json, StringComparison.Ordinal);
        Assert.Contains("\"maxPixels\":100000000", json, StringComparison.Ordinal);
        Assert.Contains("\"maxFrames\":1000", json, StringComparison.Ordinal);
        Assert.DoesNotContain("quality", json, StringComparison.Ordinal); // nil values are left out, as Swift does
    }

    [Fact]
    public void ReadsARequestWrittenByTheMac()
    {
        const string mac = """{"target":"png","source":"heic","options":{"maxPixels":5,"maxFrames":2,"quality":0.5,"image":{"rotation":90},"debugCrash":true},"inputs":["heic","jpeg"]}""";
        var request = WorkerProtocol.DecodeRequest(mac);
        Assert.Equal("png", request.Target);
        Assert.Equal(5, request.Options.MaxPixels);
        Assert.Equal(0.5, request.Options.Quality);
        Assert.True(request.Options.DebugCrash);
        Assert.Equal(90, request.Options.Image!.Value.GetProperty("rotation").GetInt32());
        Assert.Equal(new[] { "heic", "jpeg" }, request.Inputs);
        Assert.Contains("\"rotation\":90", WorkerProtocol.Encode(request), StringComparison.Ordinal);
    }

    [Fact]
    public void ResultRoundTrips()
    {
        var line = WorkerProtocol.Encode(new ConversionResult { OutputBytes = 5_000_000_000, Frames = 2, Notes = [NoteIds.MadeSquareIcon] });
        var result = WorkerProtocol.DecodeResult(line);
        Assert.Equal(5_000_000_000, result.OutputBytes);
        Assert.Equal(new[] { NoteIds.MadeSquareIcon }, result.Notes);
        Assert.Null(result.OutputNames);
    }

    [Theory]
    [InlineData("0.5", 0.5)]
    [InlineData("1.7", 1.0)]
    [InlineData("-3", 0.0)]
    public void ProgressIsClamped(string value, double expected)
    {
        Assert.True(WorkerProtocol.TryParseProgress(WorkerProtocol.ProgressPrefix + value, out var fraction));
        Assert.Equal(expected, fraction);
    }

    [Fact]
    public void ErrorLinesStayOnOneLine() =>
        Assert.Equal("AMEYA:error:a b", WorkerProtocol.ErrorLine("a\nb"));

    [Theory]
    [InlineData("simple")]
    [InlineData("with space")]
    [InlineData("")]
    [InlineData("""{"target":"png","note":"say \"hi\""}""")]
    [InlineData(@"C:\folder with space\")]
    [InlineData(@"back\\slashes\""quote")]
    public void ArgumentsSurviveTheCommandLine(string argument)
    {
        var commandLine = "worker.exe " + WorkerProtocol.QuoteArgument(argument);
        var parsed = Parse(commandLine);
        Assert.Equal(2, parsed.Length);
        Assert.Equal(argument, parsed[1]);
    }

    [Fact]
    public void SecretsAreFramedLikeTheMac()
    {
        var header = WorkerSecret.Header("pässword");
        Assert.Equal(new byte[] { 0, 0, 0, 9 }, header[..4]);
        using var stream = new MemoryStream([.. header, .. "FILE"u8.ToArray()]);
        Assert.Equal("pässword", WorkerSecret.Receive(stream));
        Assert.Equal((byte)'F', stream.ReadByte()); // exactly the header was consumed
        Assert.Throws<InvalidDataException>(() => WorkerSecret.Header(new string('x', WorkerSecret.MaxBytes + 1)));
    }

    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    private static string[] Parse(string commandLine)
    {
        var argv = CommandLineToArgvW(commandLine, out var count);
        try
        {
            return Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size))!).ToArray();
        }
        finally
        {
            LocalFree(argv);
        }
    }
}
