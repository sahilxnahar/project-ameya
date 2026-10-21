using Ameya.Core.Formats;

namespace Ameya.Core.Files;

/// <summary>
/// Chooses where a converted file goes. Never picks a name that already exists, so an original or
/// an earlier result can never be overwritten. Port of the Mac's OutputPlanner.swift.
/// </summary>
public static class OutputPlanner
{
    /// <summary>The folder results go to by default: Downloads\Ameya.</summary>
    public static string DefaultOutputFolder()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(profile, "Downloads", "Ameya");
    }

    /// <param name="isTaken">Whether a candidate path is used (on disk or reserved by a queued job).</param>
    /// <param name="suffix">Added after the name, e.g. "(rotated)" gives "photo (rotated).jpg".</param>
    public static string Destination(string source, FileFormat target, string directory, Func<string, bool> isTaken, string? suffix = null)
    {
        var (stem, ext) = NameParts(source, target);
        var baseName = Suffixed(stem, suffix);
        string Name(string counter) => ext.Length == 0 ? baseName + counter : $"{baseName}{counter}.{ext}";
        var candidate = Path.Combine(directory, Name(""));
        for (var counter = 2; isTaken(candidate); counter++)
        {
            candidate = Path.Combine(directory, Name($" {counter}"));
        }
        return candidate;
    }

    /// <summary>Convenience that checks the file system (files and folders, case-insensitively as Windows does).</summary>
    public static string Destination(string source, FileFormat target, string directory, string? suffix = null) =>
        Destination(source, target, directory, Exists, suffix);

    /// <summary>A new folder for a job that produces several files, e.g. "report (pages)".</summary>
    public static string FolderDestination(string source, string suffix, string directory, Func<string, bool> isTaken)
    {
        var baseName = Suffixed(BaseName(source), suffix);
        var candidate = Path.Combine(directory, baseName);
        for (var counter = 2; isTaken(candidate); counter++)
        {
            candidate = Path.Combine(directory, $"{baseName} {counter}");
        }
        return candidate;
    }

    public static string FolderDestination(string source, string suffix, string directory) =>
        FolderDestination(source, suffix, directory, Exists);

    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    private static string Suffixed(string baseName, string? suffix)
    {
        var trimmed = suffix?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return baseName;
        // Characters Windows doesn't allow in names become "-", like "/" does on the Mac.
        var safe = string.Concat(trimmed.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c));
        return $"{baseName} {safe}";
    }

    /// <summary>Foundation's deletingPathExtension on a file name.</summary>
    private static string WithoutExtension(string name)
    {
        var ext = FormatDetection.PathExtension(name);
        return ext.Length == 0 ? name : name[..(name.Length - ext.Length - 1)];
    }

    /// <summary>The file name without its extension, without leading dots, "Converted" when empty.
    /// Compound archive extensions are removed whole: "photos.tar.gz" → "photos".</summary>
    internal static string BaseName(string source)
    {
        var trimmed = WithoutExtension(Path.GetFileName(source));
        if (FormatDetection.PathExtension(trimmed).Equals("tar", StringComparison.OrdinalIgnoreCase)) trimmed = WithoutExtension(trimmed);
        var name = trimmed.TrimStart('.');
        return name.Length == 0 ? "Converted" : name;
    }

    /// <summary>Compressing keeps the whole name ("report.pdf" → "report.pdf.gz"); decompressing gives it
    /// back, falling back to the name stored in a gzip header when the name has no inner extension.</summary>
    internal static (string Stem, string Extension) NameParts(string source, FileFormat target)
    {
        var fileName = Path.GetFileName(source);
        if (target.IsCompression)
        {
            var name = fileName.TrimStart('.');
            var inner = FormatDetection.PathExtension(name);
            var stem = inner.Length == 0 ? name : WithoutExtension(name);
            if (stem.Length == 0) return ("Converted", target.PreferredExtension);
            return (stem, inner.Length == 0 ? target.PreferredExtension : $"{inner}.{target.PreferredExtension}");
        }
        if (target.Id == "decompressed")
        {
            var inner = fileName;
            if (FormatDetection.PathExtension(fileName).ToLowerInvariant() is "gz" or "gzip" or "bz2" or "xz")
            {
                inner = WithoutExtension(fileName);
            }
            if (FormatDetection.PathExtension(inner).Length == 0 && File.Exists(source))
            {
                var original = FormatDetection.GzipOriginalName(FormatDetection.ReadHeader(source, 4096));
                if (original is not null) inner = original;
            }
            inner = inner.TrimStart('.');
            var ext = FormatDetection.PathExtension(inner);
            var stem = ext.Length == 0 ? inner : WithoutExtension(inner);
            return stem.Length == 0 ? ("Decompressed", ext) : (stem, ext);
        }
        return (BaseName(source), target.PreferredExtension);
    }
}
