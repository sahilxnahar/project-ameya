using System.Text.Json;

namespace Ameya.Worker;

/// <summary>
/// A test hook (Debug builds only): describes the sandbox the worker is really in, so the tests can
/// prove isolation instead of assuming it. It tries to write where a Low integrity process must not.
/// </summary>
internal static class SandboxReport
{
    public static byte[] Create()
    {
        NativeMethods.IsProcessInJob(NativeMethods.GetCurrentProcess(), IntPtr.Zero, out var inJob);
        var report = new Dictionary<string, object>
        {
            ["integrityLevel"] = NativeMethods.IntegrityLevel(),
            ["inJob"] = inJob,
            ["canWriteTemp"] = CanWrite(Path.GetTempPath()),
            ["canWriteDocuments"] = CanWrite(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments)),
            ["canWriteProfile"] = CanWrite(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
            ["canWriteLocalLow"] = NativeMethods.LocalLowFolder() is { } low && CanWrite(low),
        };
        return JsonSerializer.SerializeToUtf8Bytes(report);
    }

    private static bool CanWrite(string folder)
    {
        if (string.IsNullOrEmpty(folder)) return false;
        var probe = Path.Combine(folder, $"ameya-sandbox-probe-{Guid.NewGuid():N}.txt");
        try
        {
            using (File.Create(probe)) { }
            File.Delete(probe);
            return true;
        }
        catch (UnauthorizedAccessException) { return false; }
        catch (IOException) { return false; }
    }
}
