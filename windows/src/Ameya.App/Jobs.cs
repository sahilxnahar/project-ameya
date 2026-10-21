using Ameya.Core.Conversion;
using Ameya.Core.Files;
using Ameya.Core.Formats;
using Ameya.Core.Worker;
using Ameya.Engines;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Ameya.App;

/// <summary>A file waiting to be converted.</summary>
public sealed record PendingFile(string Path, FileFormat Format)
{
    public string Name => System.IO.Path.GetFileName(Path);
}

/// <summary>What happened to one file.</summary>
public sealed record JobResult(string SourceName, string? OutputPath, string Message, IReadOnlyList<string> Notes)
{
    public bool Succeeded => OutputPath is not null;
}

/// <summary>
/// The files waiting, the conversions offered for them, and the results. Shared by the tray panel
/// and the main window. Every change happens on the UI thread (awaits resume there), and
/// <see cref="Changed"/> tells both views to refresh. Jobs run one at a time, each in its own worker.
/// </summary>
public sealed class Jobs
{
    private readonly Lazy<ConversionMatrix> _matrix = new(() => WindowsCapabilities.Matrix());
    private readonly List<PendingFile> _pending = [];
    private readonly List<JobResult> _results = [];
    private CancellationTokenSource? _running;

    public event EventHandler? Changed;

    public string OutputFolder { get; } = OutputPlanner.DefaultOutputFolder();

    /// <summary>Where workers make their scratch folders (AppData\LocalLow\Ameya\Scratch).</summary>
    public string ScratchFolder { get; } = Path.Combine(
        Path.GetDirectoryName(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)) ?? "", "LocalLow", "Ameya", "Scratch");

    public IReadOnlyList<PendingFile> Pending => _pending;
    public IReadOnlyList<JobResult> Results => _results;
    public bool IsRunning => _running is not null;
    public double Progress { get; private set; }
    public string Status { get; private set; } = "Drop files here, or choose them.";

    /// <summary>Formats every waiting file can be converted to on this PC.</summary>
    public IReadOnlyList<FileFormat> Targets => _matrix.Value.CommonTargets(_pending.Select(p => p.Format).Distinct().ToList());

    /// <summary>Plain-words messages for what converting the waiting files to <paramref name="target"/> may lose.</summary>
    public IReadOnlyList<string> PossibleLosses(FileFormat target) =>
        _pending.SelectMany(p => _matrix.Value.PossibleLosses(p.Format, target)).Distinct()
            .Select(FormatCatalog.Shared.NoteMessage).ToList();

    public void Add(IEnumerable<string> paths)
    {
        var skipped = new List<string>();
        foreach (var path in paths)
        {
            if (_pending.Any(p => string.Equals(p.Path, path, StringComparison.OrdinalIgnoreCase))) continue;
            var format = File.Exists(path) ? FormatDetection.Detect(path) : null;
            if (format is not null && _matrix.Value.CanRead(format) && _matrix.Value.Targets(format).Count > 0)
            {
                _pending.Add(new PendingFile(path, format));
            }
            else
            {
                skipped.Add(Path.GetFileName(path));
            }
        }
        Status = skipped.Count switch
        {
            0 => _pending.Count == 1 ? "1 file ready. Pick what to convert it to." : $"{_pending.Count} files ready. Pick what to convert them to.",
            1 => $"{skipped[0]} can't be converted on Windows yet.",
            _ => $"{skipped.Count} files can't be converted on Windows yet.",
        };
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public async Task AddFromClipboardAsync()
    {
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.StorageItems))
            {
                Status = "There are no files to paste. Copy files in File Explorer first.";
                Changed?.Invoke(this, EventArgs.Empty);
                return;
            }
            var items = await content.GetStorageItemsAsync();
            Add(items.OfType<StorageFile>().Select(file => file.Path).Where(path => !string.IsNullOrEmpty(path)));
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            Status = "The clipboard couldn't be read. Try copying the files again.";
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void ClearPending()
    {
        _pending.Clear();
        Status = "Drop files here, or choose them.";
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void ClearResults()
    {
        _results.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void CancelAll() => _running?.Cancel();

    /// <summary>Converts every waiting file to <paramref name="target"/>, one at a time.</summary>
    public async Task ConvertAsync(FileFormat target)
    {
        if (IsRunning || _pending.Count == 0) return;
        var files = _pending.ToList();
        _pending.Clear();
        using var running = new CancellationTokenSource();
        _running = running;
        Directory.CreateDirectory(OutputFolder);
        var done = 0;
        var succeeded = 0;
        foreach (var file in files)
        {
            Status = $"Converting {file.Name} to {target.DisplayName} ({done + 1} of {files.Count})…";
            Progress = (double)done / files.Count;
            Changed?.Invoke(this, EventArgs.Empty);
            var destination = OutputPlanner.Destination(file.Path, target, OutputFolder);
            var runner = new WorkerRunner(Program.WorkerPath) { Timeout = FormatCatalog.Shared.Timeout(file.Format) };
            var step = done;
            var progress = new Progress<double>(fraction =>
            {
                Progress = (step + fraction) / files.Count;
                Changed?.Invoke(this, EventArgs.Empty);
            });
            try
            {
                var request = new ConversionRequest { Source = file.Format.Id, Target = target.Id };
                var result = await runner.RunAsync(file.Path, destination, request, progress, cancellationToken: running.Token);
                _results.Insert(0, new JobResult(file.Name, destination, $"Saved as {Path.GetFileName(destination)}",
                    result.Notes.Select(FormatCatalog.Shared.NoteMessage).ToList()));
                succeeded++;
            }
            catch (WorkerException error)
            {
                _results.Insert(0, new JobResult(file.Name, null, error.Message, []));
                if (error.Failure == WorkerFailure.Cancelled) break;
            }
            done++;
        }
        _running = null;
        Progress = 0;
        Status = succeeded == files.Count
            ? (succeeded == 1 ? "Done. 1 file converted." : $"Done. {succeeded} files converted.")
            : $"Done. {succeeded} of {files.Count} files converted.";
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
