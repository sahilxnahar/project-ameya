using System.Diagnostics;
using System.Text;
using Ameya.Core.Conversion;
using Ameya.Core.Files;
using Ameya.Core.Formats;
using Ameya.Core.Worker;
using Ameya.Engines;

namespace Ameya.Worker;

/// <summary>
/// One conversion per process. Source bytes arrive on stdin, the result leaves on stdout, and
/// status lines go to stderr (see WorkerProtocol). The worker never opens the user's files by
/// path: it copies stdin into a private scratch folder under AppData\LocalLow (the only place a
/// Low integrity process may write), converts there, and deletes it.
/// </summary>
internal static class Program
{
    private const long MaxInputBytes = 20L << 30; // 20 GiB
    private const int ChunkSize = 4 << 20;

    private static readonly StreamWriter Status = new(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true };

    private static async Task<int> Main(string[] args)
    {
#if DEBUG
        // A stand-in for a helper process (FFmpeg later), used to test that stopping a job stops it too.
        if (args.Length == 2 && args[0] == "--debug-sleep")
        {
            Thread.Sleep(TimeSpan.FromSeconds(double.Parse(args[1], System.Globalization.CultureInfo.InvariantCulture)));
            return 0;
        }
#endif
        var flag = Array.IndexOf(args, WorkerProtocol.RequestArgument);
        ConversionRequest request;
        try
        {
            if (flag < 0 || flag + 1 >= args.Length) return Fail("The converter received an invalid request.");
            request = WorkerProtocol.DecodeRequest(args[flag + 1]);
        }
        catch (System.Text.Json.JsonException)
        {
            return Fail("The converter received an invalid request.");
        }

        using var stdin = Console.OpenStandardInput();
        if (request.Options.SecretOnStdin == true)
        {
            try
            {
                // Read now, so the file that follows starts at the right byte. Engines that take
                // passwords (PDF) will receive it; none of the current Windows engines do.
                _ = WorkerSecret.Receive(stdin);
            }
            catch (InvalidDataException error)
            {
                return Fail(error.Message);
            }
        }

#if DEBUG
        if (await DebugHooks(request) is { } exit) return exit;
#endif
        var scratch = CreateScratch();
        if (scratch is null) return Fail("Couldn't create a working folder.");
        try
        {
            var inputs = ReceiveInputs(stdin, request, scratch, out var problem);
            if (inputs is null) return Fail(problem ?? "Couldn't read the file.");
            Status.WriteLine(WorkerProtocol.ProgressLine(0.02));

            var (outputs, result) = await Engine.RunAsync(inputs, request, scratch,
                fraction => Status.WriteLine(WorkerProtocol.ProgressLine(fraction)));
            using var stdout = Console.OpenStandardOutput();
            if (result.OutputNames is { } names)
            {
                // Several files leave as a TAR stream; outputBytes is then the stream's size.
                if (names.Count != outputs.Count) return Fail("The converter produced an unexpected set of files.");
                result.OutputBytes = TarStream.Write(names.Zip(outputs), stdout);
            }
            else
            {
                if (outputs.Count != 1) return Fail("The converter produced an unexpected set of files.");
                await using var reader = new FileStream(outputs[0], FileMode.Open, FileAccess.Read, FileShare.Read);
                await reader.CopyToAsync(stdout, ChunkSize);
                result.OutputBytes = reader.Length;
            }
            stdout.Flush();
            Status.WriteLine(WorkerProtocol.DonePrefix + WorkerProtocol.Encode(result));
            return 0;
        }
        catch (ConversionException error)
        {
            return Fail(error.Message);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            // Codec errors arrive as COM exceptions with technical text; keep it short and on one line.
            return Fail($"The conversion failed: {error.Message}");
        }
        finally
        {
            try { Directory.Delete(scratch, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static int Fail(string message)
    {
        Status.WriteLine(WorkerProtocol.ErrorLine(message));
        return 2;
    }

    /// <summary>A fresh folder under AppData\LocalLow\Ameya\Scratch. The app sweeps old ones away.</summary>
    private static string? CreateScratch()
    {
        var root = NativeMethods.LocalLowFolder() is { } low
            ? Path.Combine(low, "Ameya", "Scratch")
            : Path.GetTempPath();
        var folder = Path.Combine(root, $"ameya-worker-{Environment.ProcessId}-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(folder);
            return folder;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static List<string>? ReceiveInputs(Stream stdin, ConversionRequest request, string scratch, out string? problem)
    {
        problem = null;
        if (request.Inputs is { Count: > 1 } formats)
        {
            // Several files arrive as a strict TAR stream named 0.ext, 1.ext, … in order.
            var folder = Directory.CreateDirectory(Path.Combine(scratch, "inputs")).FullName;
            try
            {
                var names = TarStream.Extract(stdin, folder, new TarStream.Limits(1_000, MaxInputBytes));
                var expected = formats.Select((id, index) => $"{index}.{FormatCatalog.Shared.Find(id)?.PreferredExtension ?? "bin"}");
                if (!names.SequenceEqual(expected, StringComparer.Ordinal))
                {
                    problem = "The converter received an unexpected set of files.";
                    return null;
                }
                return names.Select(name => Path.Combine(folder, name)).ToList();
            }
            catch (IOException error)
            {
                problem = error.Message;
                return null;
            }
        }

        // Copy stdin to a file: codecs want a file, and streaming keeps memory flat for big inputs.
        var extension = FormatCatalog.Shared.Find(request.Source)?.PreferredExtension ?? "bin";
        var input = Path.Combine(scratch, $"input.{extension}");
        long total = 0;
        using (var writer = new FileStream(input, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            var buffer = new byte[ChunkSize];
            int read;
            while ((read = stdin.Read(buffer, 0, buffer.Length)) > 0)
            {
                total += read;
                if (total > MaxInputBytes)
                {
                    problem = "The file is larger than 20 GB.";
                    return null;
                }
                writer.Write(buffer, 0, read);
            }
        }
        if (total == 0)
        {
            problem = "The file is empty.";
            return null;
        }
        return [input];
    }

#if DEBUG
    /// <summary>Test hooks for timeouts, cancelling, crashes and sandbox checks. Not in Release builds.</summary>
    private static async Task<int?> DebugHooks(ConversionRequest request)
    {
        var options = request.Options;
        if (options.DebugSpawnChild == true && Environment.ProcessPath is { } self)
        {
            using var child = Process.Start(new ProcessStartInfo(self, "--debug-sleep 600") { UseShellExecute = false, CreateNoWindow = true });
        }
        if (options.DebugDelaySeconds is { } delay) await Task.Delay(TimeSpan.FromSeconds(delay));
        if (options.DebugCrash == true) Environment.FailFast("Ameya worker test crash");
        if (options.DebugReportSandbox == true)
        {
            var report = SandboxReport.Create();
            using var stdout = Console.OpenStandardOutput();
            stdout.Write(report);
            stdout.Flush();
            Status.WriteLine(WorkerProtocol.DonePrefix + WorkerProtocol.Encode(new ConversionResult { OutputBytes = report.Length, Frames = 0 }));
            return 0;
        }
        return null;
    }
#endif
}
