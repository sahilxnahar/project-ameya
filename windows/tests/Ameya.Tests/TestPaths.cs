using System.Reflection;

namespace Ameya.Tests;

internal static class TestPaths
{
    /// <summary>The repository's windows/ folder (recorded at build time).</summary>
    public static string WindowsRoot { get; } = typeof(TestPaths).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .First(attribute => attribute.Key == "WindowsRoot").Value!;

    public static string Spec(string name) => Path.Combine(AppContext.BaseDirectory, "spec", name);

    public static string Worker
    {
        get
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Ameya.Worker.exe");
            if (!File.Exists(path)) throw new FileNotFoundException("The worker wasn't copied next to the tests.", path);
            return path;
        }
    }

    /// <summary>A fresh folder for one test, removed when disposed.</summary>
    public sealed class TempFolder : IDisposable
    {
        public TempFolder()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"ameya-tests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public string File(string name, byte[] bytes)
        {
            var path = System.IO.Path.Combine(Path, name);
            System.IO.File.WriteAllBytes(path, bytes);
            return path;
        }

        public string Combine(string name) => System.IO.Path.Combine(Path, name);

        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
