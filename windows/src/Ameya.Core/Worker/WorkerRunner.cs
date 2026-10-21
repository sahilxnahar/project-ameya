using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Ameya.Core.Conversion;
using Ameya.Core.Files;
using Ameya.Core.Formats;
using Ameya.Core.Windows;
using Microsoft.Win32.SafeHandles;

namespace Ameya.Core.Worker;

/// <summary>
/// Runs one conversion in its own worker process, as on the Mac: a fresh process per job, so a
/// hang, crash or runaway allocation affects only that job. The source is handed over as a
/// read-only stdin handle; the worker writes to a hidden ".partial" file through its stdout handle,
/// and that file is moved into place only after the worker reports success — never over anything
/// that exists (File.Move without overwrite is MoveFileEx without MOVEFILE_REPLACE_EXISTING).
/// The worker runs at Low integrity inside a Job Object (see SandboxedProcess).
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WorkerRunner(string executable)
{
    public string Executable { get; } = executable;
    public TimeSpan Timeout { get; init; } = TimeSpan.FromMinutes(5);
    public SandboxOptions Sandbox { get; init; } = new();
    public string TemporaryDirectory { get; init; } = Path.GetTempPath();

    public Task<ConversionResult> RunAsync(
        string input, string destination, ConversionRequest request,
        IProgress<double>? progress = null, string? secret = null, CancellationToken cancellationToken = default) =>
        RunAsync([input], destination, request, progress, secret, cancellationToken);

    /// <summary>Runs one job over one or more files. Several inputs travel, in order, as a strict TAR
    /// stream (entries 0.ext, 1.ext, …). When the worker reports outputNames, its output is a TAR
    /// stream that is unpacked into a hidden folder and moved to <paramref name="destination"/>.</summary>
    public async Task<ConversionResult> RunAsync(
        IReadOnlyList<string> inputs, string destination, ConversionRequest request,
        IProgress<double>? progress = null, string? secret = null, CancellationToken cancellationToken = default)
    {
        if (inputs.Count == 0) throw WorkerException.CannotOpenInput("(no files)");
        request = WorkerProtocol.DecodeRequest(WorkerProtocol.Encode(request)); // a private copy we may adjust
        var name = Path.GetFileName(destination);
        var directory = Path.GetDirectoryName(Path.GetFullPath(destination)) ?? throw WorkerException.CannotCreateOutput(name);
        var token = Guid.NewGuid().ToString("N");
        var partial = Path.Combine(directory, $".{name}.{token}.partial");
        var partialFolder = Path.Combine(directory, $".{name}.{token}.files.partial");
        string? bundle = null;
        var succeeded = false;
        SafeFileHandle? input = null;
        SafeFileHandle? output = null;
        try
        {
            var source = inputs[0];
            if (inputs.Count > 1)
            {
                var formats = request.Inputs ?? inputs.Select(path =>
                    FormatDetection.Detect(path)?.Id ?? throw WorkerException.CannotOpenInput(Path.GetFileName(path))).ToList();
                if (formats.Count != inputs.Count)
                {
                    throw WorkerException.Failed($"The request lists {formats.Count} formats for {inputs.Count} files.");
                }
                request.Inputs = formats;
                bundle = Path.Combine(TemporaryDirectory, $"ameya-inputs-{token}.tar");
                Bundle(inputs, formats, bundle);
                source = bundle;
            }
            input = Open(() => File.OpenHandle(source, FileMode.Open, FileAccess.Read, FileShare.Read),
                () => WorkerException.CannotOpenInput(Path.GetFileName(inputs[0])));
            output = Open(() => File.OpenHandle(partial, FileMode.CreateNew, FileAccess.Write, FileShare.Read),
                () => WorkerException.CannotCreateOutput(name));
            File.SetAttributes(partial, FileAttributes.Hidden);

            var result = await RunWorkerAsync(request, input, output, secret, progress, cancellationToken).ConfigureAwait(false);
            input = null; // handed over (and closed) by RunWorkerAsync
            output = null;

            var written = new FileInfo(partial).Length;
            if (written != result.OutputBytes)
            {
                throw WorkerException.ProtocolViolation($"reported {result.OutputBytes} bytes, wrote {written}");
            }
            var moving = partial;
            if (result.OutputNames is { } names)
            {
                Unpack(partial, names, partialFolder);
                moving = partialFolder;
            }
            MoveIntoPlace(moving, destination, isFolder: result.OutputNames is not null);
            succeeded = true;
            return result;
        }
        finally
        {
            input?.Dispose();
            output?.Dispose();
            TryDelete(partial);
            if (!succeeded) TryDeleteFolder(partialFolder);
            if (bundle is not null) TryDelete(bundle);
        }
    }

    private async Task<ConversionResult> RunWorkerAsync(
        ConversionRequest request, SafeFileHandle input, SafeFileHandle output, string? secret,
        IProgress<double>? progress, CancellationToken cancellationToken)
    {
        // A password travels ahead of the file on stdin, never on the command line (WorkerSecret).
        AnonymousPipeServerStream? secretPipe = null;
        if (secret is not null)
        {
            request.Options.SecretOnStdin = true;
            secretPipe = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
        }
        using var stderr = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        SafeHandle stdin = secretPipe is null ? input : secretPipe.ClientSafePipeHandle;
        string[] arguments = [WorkerProtocol.RequestArgument, WorkerProtocol.Encode(request)];

        SandboxedProcess process;
        try
        {
            process = SandboxedProcess.Start(Executable, arguments, stdin, output, stderr.ClientSafePipeHandle, Sandbox);
        }
        catch (Win32Exception error)
        {
            input.Dispose();
            output.Dispose();
            secretPipe?.Dispose();
            throw WorkerException.Failed($"Couldn't start the converter: {error.Message}");
        }

        using (process)
        {
            // The worker holds its own copies now. Closing ours lets stderr end when the job ends.
            stderr.DisposeLocalCopyOfClientHandle();
            output.Dispose();
            var feeder = Task.CompletedTask;
            if (secretPipe is not null)
            {
                secretPipe.DisposeLocalCopyOfClientHandle();
                feeder = WorkerSecret.FeedAsync(secret!, new FileStream(input, FileAccess.Read), secretPipe);
            }
            else
            {
                input.Dispose();
            }

            var status = new WorkerStatusReader(progress);
            var reading = status.ReadAsync(stderr);
            WorkerException? stopped = null;
            using (var watchdog = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                var limit = Task.Delay(Timeout, watchdog.Token);
                if (await Task.WhenAny(process.Exited, limit).ConfigureAwait(false) != process.Exited)
                {
                    stopped = cancellationToken.IsCancellationRequested ? WorkerException.Cancelled() : WorkerException.TimedOut(Timeout);
                    process.KillTree();
                    await process.Exited.ConfigureAwait(false);
                }
                await watchdog.CancelAsync().ConfigureAwait(false);
            }
            process.KillTree(); // stops anything the worker left running
            var exitCode = process.ExitCode;
            await reading.ConfigureAwait(false);
            await feeder.ConfigureAwait(false);

            if (stopped is not null) throw stopped;
            // Exit codes from 0x80000000 up are NTSTATUS errors or a .NET fail-fast: a crash, not a refusal.
            if (exitCode >= 0x80000000) throw WorkerException.Crashed(exitCode);
            if (status.ProtocolProblem is { } problem) throw WorkerException.ProtocolViolation(problem);
            if (exitCode != 0 || status.Result is null)
            {
                throw WorkerException.Failed(status.ErrorMessage ?? $"The converter stopped with status {exitCode}.");
            }
            return status.Result;
        }
    }

    private static SafeFileHandle Open(Func<SafeFileHandle> open, Func<WorkerException> failure)
    {
        try
        {
            return open();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw failure();
        }
    }

    private static void Bundle(IReadOnlyList<string> inputs, IReadOnlyList<string> formats, string tar)
    {
        using var stream = new FileStream(tar, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        var writer = new TarStream.Writer(stream);
        for (var i = 0; i < inputs.Count; i++)
        {
            var extension = FormatCatalog.Shared.Find(formats[i])?.PreferredExtension ?? "bin";
            try
            {
                writer.Add($"{i}.{extension}", inputs[i]);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw WorkerException.CannotOpenInput(Path.GetFileName(inputs[i]));
            }
        }
        writer.Finish();
    }

    /// <summary>Strictly unpacks the worker's TAR output and checks it holds exactly the reported names, in order.</summary>
    private static void Unpack(string tar, IReadOnlyList<string> names, string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            File.SetAttributes(folder, FileAttributes.Directory | FileAttributes.Hidden);
            using var stream = new FileStream(tar, FileMode.Open, FileAccess.Read, FileShare.Read);
            var extracted = TarStream.Extract(stream, folder);
            if (!extracted.SequenceEqual(names, StringComparer.Ordinal))
            {
                throw WorkerException.ProtocolViolation("the files sent don't match the files reported");
            }
        }
        catch (IOException error)
        {
            throw WorkerException.ProtocolViolation(error.Message);
        }
    }

    private static void MoveIntoPlace(string from, string destination, bool isFolder)
    {
        var name = Path.GetFileName(destination);
        try
        {
            if (isFolder) Directory.Move(from, destination); else File.Move(from, destination, overwrite: false);
        }
        catch (IOException)
        {
            if (OutputPlanner.Exists(destination)) throw WorkerException.OutputExists(name);
            throw WorkerException.CannotCreateOutput(name);
        }
        catch (UnauthorizedAccessException)
        {
            throw WorkerException.CannotCreateOutput(name);
        }
        var attributes = File.GetAttributes(destination);
        File.SetAttributes(destination, attributes & ~FileAttributes.Hidden);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void TryDeleteFolder(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
