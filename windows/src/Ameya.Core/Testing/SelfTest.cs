using System.Runtime.Versioning;
using Ameya.Core.Conversion;
using Ameya.Core.Formats;
using Ameya.Core.Worker;

namespace Ameya.Core.Testing;

/// <summary>
/// Converts generated pictures through the real, sandboxed worker and checks every result, like
/// the Mac app's --self-test. Prints one PASS/FAIL line per check, then "SELFTEST OK" or
/// "SELFTEST FAILED". Returns the process exit code (0 when everything passed).
/// </summary>
[SupportedOSPlatform("windows")]
public static class SelfTest
{
    private sealed record Case(string Name, string Input, string Target, string? ExpectNote = null, string? ForbidNote = null);

    public static async Task<int> RunAsync(string workerPath, TextWriter log)
    {
        var folder = Path.Combine(Path.GetTempPath(), $"ameya-selftest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);
        var failures = 0;
        try
        {
            var opaque = Write(folder, "opaque.png", TestImages.Png(64, 48));
            var transparent = Write(folder, "transparent.png", TestImages.Png(64, 48, transparentCorner: true));
            var bitmap = Write(folder, "bitmap.bmp", TestImages.Bmp(40, 30));
            Case[] cases =
            [
                new("opaque PNG to JPEG keeps quiet about transparency", opaque, "jpeg", ForbidNote: NoteIds.TransparencyFilledWhite),
                new("transparent PNG to JPEG says it was filled white", transparent, "jpeg", ExpectNote: NoteIds.TransparencyFilledWhite),
                new("PNG to TIFF", opaque, "tiff"),
                new("PNG to BMP", transparent, "bmp", ExpectNote: NoteIds.TransparencyFilledWhite),
                new("PNG to GIF", opaque, "gif"),
                new("PNG to ICO", transparent, "ico", ExpectNote: NoteIds.MadeSquareIcon),
                new("PNG to PDF", transparent, "pdf"),
                new("BMP to PNG", bitmap, "png"),
            ];
            var runner = new WorkerRunner(workerPath) { Timeout = TimeSpan.FromSeconds(120) };
            foreach (var test in cases)
            {
                failures += await Check(log, test.Name, () => Convert(runner, test, folder)).ConfigureAwait(false);
            }
            failures += await Check(log, "an existing file is never overwritten", async () =>
            {
                var destination = Path.Combine(folder, "taken.jpg");
                await File.WriteAllTextAsync(destination, "keep me").ConfigureAwait(false);
                try
                {
                    await runner.RunAsync(opaque, destination, Request(opaque, "jpeg")).ConfigureAwait(false);
                    return "the conversion replaced an existing file";
                }
                catch (WorkerException error) when (error.Failure == WorkerFailure.OutputExists)
                {
                    var kept = await File.ReadAllTextAsync(destination).ConfigureAwait(false);
                    return kept == "keep me" ? null : "the existing file changed";
                }
            }).ConfigureAwait(false);
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
        }
        log.WriteLine(failures == 0 ? "SELFTEST OK" : $"SELFTEST FAILED ({failures} failed)");
        return failures == 0 ? 0 : 1;
    }

    private static async Task<string?> Convert(WorkerRunner runner, Case test, string folder)
    {
        var target = FormatCatalog.Shared.Get(test.Target);
        var destination = Files.OutputPlanner.Destination(test.Input, target, folder);
        var result = await runner.RunAsync(test.Input, destination, Request(test.Input, test.Target)).ConfigureAwait(false);
        var detected = FormatDetection.Detect(destination);
        if (detected != target) return $"the result looks like {detected?.Id ?? "nothing known"}, not {target.Id}";
        if (test.ExpectNote is { } expected && !result.Notes.Contains(expected)) return $"missing note {expected}";
        if (test.ForbidNote is { } forbidden && result.Notes.Contains(forbidden)) return $"unexpected note {forbidden}";
        return null;
    }

    private static ConversionRequest Request(string input, string target) =>
        new() { Source = FormatDetection.Detect(input)?.Id, Target = target };

    private static async Task<int> Check(TextWriter log, string name, Func<Task<string?>> check)
    {
        string? problem;
        try
        {
            problem = await check().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            problem = error.Message;
        }
        log.WriteLine(problem is null ? $"PASS {name}" : $"FAIL {name}: {problem}");
        log.Flush();
        return problem is null ? 0 : 1;
    }

    private static string Write(string folder, string name, byte[] bytes)
    {
        var path = Path.Combine(folder, name);
        File.WriteAllBytes(path, bytes);
        return path;
    }
}
