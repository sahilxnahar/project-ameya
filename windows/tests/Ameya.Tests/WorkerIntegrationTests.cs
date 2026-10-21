using System.Diagnostics;
using System.Text.Json;
using Ameya.Core.Conversion;
using Ameya.Core.Formats;
using Ameya.Core.Testing;
using Ameya.Core.Worker;
using Xunit;

namespace Ameya.Tests;

/// <summary>Worker tests count worker processes, so they never run alongside each other.</summary>
[CollectionDefinition("Worker", DisableParallelization = true)]
public class WorkerCollection;

/// <summary>Runs the real worker exe, sandboxed exactly as the app runs it.</summary>
[Collection("Worker")]
public class WorkerIntegrationTests
{
    private static WorkerRunner Runner(TimeSpan? timeout = null) =>
        new(TestPaths.Worker) { Timeout = timeout ?? TimeSpan.FromSeconds(120) };

    private static ConversionRequest Request(string source, string target, Action<ConversionOptions>? options = null)
    {
        var request = new ConversionRequest { Source = source, Target = target };
        options?.Invoke(request.Options);
        return request;
    }

    [Fact]
    public async Task ConvertsAPicture()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(32, 24));
        var output = folder.Combine("out.jpg");
        var progress = new List<double>();
        var result = await Runner().RunAsync(input, output, Request("png", "jpeg"), new SyncProgress(progress.Add));
        Assert.Equal("jpeg", FormatDetection.Detect(output)?.Id);
        Assert.Equal(new FileInfo(output).Length, result.OutputBytes);
        Assert.Empty(result.Notes);
        Assert.NotEmpty(progress);
        Assert.Equal((FileAttributes)0, File.GetAttributes(output) & FileAttributes.Hidden); // the partial was hidden; the result isn't
        Assert.Empty(Directory.GetFiles(folder.Path, ".*.partial"));
    }

    [Fact]
    public async Task NeverOverwritesAnExistingFile()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(16, 16));
        var output = folder.Combine("out.jpg");
        File.WriteAllText(output, "keep me");
        var error = await Assert.ThrowsAsync<WorkerException>(() => Runner().RunAsync(input, output, Request("png", "jpeg")));
        Assert.Equal(WorkerFailure.OutputExists, error.Failure);
        Assert.Equal("keep me", File.ReadAllText(output));
        Assert.Empty(Directory.GetFiles(folder.Path, ".*.partial"));
    }

    [Fact]
    public async Task StopsAWorkerThatTakesTooLong()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(16, 16));
        var clock = Stopwatch.StartNew();
        var error = await Assert.ThrowsAsync<WorkerException>(() =>
            Runner(TimeSpan.FromSeconds(3)).RunAsync(input, folder.Combine("out.jpg"), Request("png", "jpeg", o => o.DebugDelaySeconds = 600)));
        Assert.Equal(WorkerFailure.TimedOut, error.Failure);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(60), $"took {clock.Elapsed}");
        Assert.False(File.Exists(folder.Combine("out.jpg")));
        Assert.Empty(Directory.GetFiles(folder.Path, ".*.partial"));
    }

    [Fact]
    public async Task CancellingStopsTheWorkerAndEverythingItStarted()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(16, 16));
        var before = WorkerProcessCount();
        using var cancel = new CancellationTokenSource();
        var job = Runner().RunAsync(input, folder.Combine("out.jpg"),
            Request("png", "jpeg", o => { o.DebugSpawnChild = true; o.DebugDelaySeconds = 600; }), cancellationToken: cancel.Token);

        // The worker and its child are both running.
        Assert.True(await WaitUntil(() => WorkerProcessCount() >= before + 2), "the worker and its child never started");
        await cancel.CancelAsync();
        var error = await Assert.ThrowsAsync<WorkerException>(() => job);
        Assert.Equal(WorkerFailure.Cancelled, error.Failure);
        Assert.True(await WaitUntil(() => WorkerProcessCount() <= before), "a worker process outlived its job");
    }

    [Fact]
    public async Task ACrashIsReportedAndLeavesNothingBehind()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(16, 16));
        var error = await Assert.ThrowsAsync<WorkerException>(() =>
            Runner().RunAsync(input, folder.Combine("out.jpg"), Request("png", "jpeg", o => o.DebugCrash = true)));
        Assert.Equal(WorkerFailure.Crashed, error.Failure);
        Assert.Contains("original file is untouched", error.Message, StringComparison.Ordinal);
        Assert.Equal(new[] { input }, Directory.GetFileSystemEntries(folder.Path));
    }

    [Fact]
    public async Task TheWorkerRunsAtLowIntegrityInAJob()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(4, 4));
        var output = folder.Combine("report.json");
        await Runner().RunAsync(input, output, Request("png", "jpeg", o => o.DebugReportSandbox = true));
        using var report = JsonDocument.Parse(File.ReadAllText(output));
        var root = report.RootElement;
        Assert.Equal(0x1000, root.GetProperty("integrityLevel").GetInt32()); // SECURITY_MANDATORY_LOW_RID
        Assert.True(root.GetProperty("inJob").GetBoolean());
        Assert.False(root.GetProperty("canWriteTemp").GetBoolean());
        Assert.False(root.GetProperty("canWriteDocuments").GetBoolean());
        Assert.False(root.GetProperty("canWriteProfile").GetBoolean());
        Assert.True(root.GetProperty("canWriteLocalLow").GetBoolean());
    }

    [Fact]
    public async Task UnreadableFilesFailWithPlainWords()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("broken.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
        var error = await Assert.ThrowsAsync<WorkerException>(() => Runner().RunAsync(input, folder.Combine("out.jpg"), Request("png", "jpeg")));
        Assert.Equal(WorkerFailure.Failed, error.Failure);
        Assert.Contains("couldn't be read", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task PicturesOverThePixelLimitAreRefused()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("big.png", TestImages.Png(64, 48));
        var error = await Assert.ThrowsAsync<WorkerException>(() =>
            Runner().RunAsync(input, folder.Combine("out.jpg"), Request("png", "jpeg", o => o.MaxPixels = 1000)));
        Assert.Contains("too large", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task APasswordTravelsOnStdinAheadOfTheFile()
    {
        using var folder = new TestPaths.TempFolder();
        var input = folder.File("in.png", TestImages.Png(16, 16));
        var output = folder.Combine("out.jpg");
        await Runner().RunAsync(input, output, Request("png", "jpeg"), secret: "s3cret");
        Assert.Equal("jpeg", FormatDetection.Detect(output)?.Id);
    }

    [Fact]
    public async Task TheSelfTestPasses()
    {
        using var log = new StringWriter();
        var exitCode = await SelfTest.RunAsync(TestPaths.Worker, log);
        Assert.True(exitCode == 0, log.ToString());
        Assert.Contains("SELFTEST OK", log.ToString(), StringComparison.Ordinal);
    }

    private static int WorkerProcessCount()
    {
        var processes = Process.GetProcessesByName("Ameya.Worker");
        foreach (var process in processes) process.Dispose();
        return processes.Length;
    }

    private static async Task<bool> WaitUntil(Func<bool> condition)
    {
        for (var i = 0; i < 200; i++)
        {
            if (condition()) return true;
            await Task.Delay(100);
        }
        return condition();
    }

    /// <summary>Reports on the calling thread, so the list is filled before RunAsync returns.</summary>
    private sealed class SyncProgress(Action<double> report) : IProgress<double>
    {
        public void Report(double value)
        {
            lock (this) report(value);
        }
    }
}
