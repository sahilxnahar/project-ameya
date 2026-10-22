using Ameya.Core.Conversion;
using Ameya.Core.Formats;
using Ameya.Engines.Images;

namespace Ameya.Engines;

/// <summary>Picks the engine for a request. Runs only inside the worker process.</summary>
public static class Engine
{
    /// <returns>The output files (in scratch) and the result to report.</returns>
    public static async Task<(IReadOnlyList<string> Outputs, ConversionResult Result)> RunAsync(
        IReadOnlyList<string> inputs, ConversionRequest request, string scratch, Action<double> progress)
    {
        var catalog = FormatCatalog.Shared;
        var target = catalog.Find(request.Target) ?? throw new ConversionException("The converter received an unknown target format.");
        var source = catalog.Find(request.Source);
        if (inputs.Count != 1) throw new ConversionException("Ameya for Windows converts one file at a time so far.");
        if (source is not null && !ConversionMatrix.CanConvert(catalog, source, target, ffmpeg: false))
        {
            throw new ConversionException($"{source.DisplayName} can't be converted to {target.DisplayName}.");
        }

        var output = Path.Combine(scratch, $"output.{target.PreferredExtension}");
        if ((source is null || source.IsImage) && (target.IsImage || target.Id == "pdf"))
        {
            var result = await ImageConverter.ConvertAsync(inputs[0], output, request, progress);
            return ([output], result);
        }
        throw new ConversionException($"Ameya for Windows can't convert {source?.DisplayName ?? "this file"} to {target.DisplayName} yet.");
    }
}
