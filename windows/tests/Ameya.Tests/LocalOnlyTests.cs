using System.Xml.Linq;
using Xunit;

namespace Ameya.Tests;

/// <summary>
/// Ameya promises that everything stays on the PC. These checks fail the build if network access
/// creeps in through package capabilities, networking APIs or a package that brings them.
/// </summary>
public class LocalOnlyTests
{
    private static string Source => Path.Combine(TestPaths.WindowsRoot, "src");

    [Fact]
    public void ThePackageAsksForNoNetworkCapability()
    {
        var manifest = Path.Combine(Source, "Ameya.App", "Package.appxmanifest");
        var document = XDocument.Load(manifest);
        var capabilities = document.Descendants().Where(e => e.Name.LocalName is "Capability" or "DeviceCapability")
            .Select(e => (string?)e.Attribute("Name") ?? "").ToList();
        string[] forbidden = ["internetClient", "internetClientServer", "privateNetworkClientServer"];
        Assert.Empty(capabilities.Intersect(forbidden, StringComparer.OrdinalIgnoreCase));
        // Only what a desktop app needs to run at all.
        Assert.All(capabilities, capability => Assert.Equal("runFullTrust", capability));
    }

    [Fact]
    public void NoNetworkingApisInOurCode()
    {
        string[] forbidden =
        [
            "HttpClient", "WebClient", "WebRequest", "HttpWebRequest", "HttpListener", "System.Net.Sockets", "TcpClient",
            "TcpListener", "UdpClient", "ClientWebSocket", "Windows.Web.Http", "Windows.Networking", "WebView2",
            "System.Net.Http", "Socket(", "Dns.", "BackgroundDownloader",
        ];
        var files = Directory.EnumerateFiles(Source, "*.*", SearchOption.AllDirectories)
            .Where(path => path.EndsWith(".cs", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase))
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)
                        && !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .ToList();
        Assert.NotEmpty(files);
        var offenders = files.SelectMany(file =>
        {
            var text = File.ReadAllText(file);
            return forbidden.Where(api => text.Contains(api, StringComparison.Ordinal)).Select(api => $"{Path.GetFileName(file)}: {api}");
        }).ToList();
        Assert.True(offenders.Count == 0, "networking APIs found: " + string.Join(", ", offenders));
    }

    [Fact]
    public void NoPackageBringsNetworking()
    {
        var projects = Directory.EnumerateFiles(Source, "*.csproj", SearchOption.AllDirectories).ToList();
        Assert.NotEmpty(projects);
        foreach (var project in projects)
        {
            var packages = XDocument.Load(project).Descendants("PackageReference").Select(e => (string?)e.Attribute("Include") ?? "");
            Assert.DoesNotContain(packages, name => name.Contains("Http", StringComparison.OrdinalIgnoreCase) ||
                                                    name.Contains("WebView", StringComparison.OrdinalIgnoreCase));
        }
    }
}
