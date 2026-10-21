namespace Ameya.Core.Files;

/// <summary>
/// Removes what a killed job can leave behind: hidden ".partial" files and folders next to results,
/// and worker scratch folders. Only names Ameya itself creates are touched, and only once they are
/// old enough that no running job can still own them.
/// </summary>
public static class LeftoverCleanup
{
    public static readonly TimeSpan MinimumAge = TimeSpan.FromHours(6);

    public static int SweepPartials(string directory) =>
        Sweep(directory, ".*.partial", entry => entry.Name.StartsWith('.'));

    public static int SweepScratch(string directory) =>
        Sweep(directory, "ameya-worker-*", _ => true);

    private static int Sweep(string directory, string pattern, Func<FileSystemInfo, bool> owned)
    {
        if (!Directory.Exists(directory)) return 0;
        var removed = 0;
        var cutoff = DateTime.UtcNow - MinimumAge;
        foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos(pattern))
        {
            if (!owned(entry) || entry.LastWriteTimeUtc > cutoff) continue;
            try
            {
                if (entry is DirectoryInfo folder) folder.Delete(recursive: true); else entry.Delete();
                removed++;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return removed;
    }
}
