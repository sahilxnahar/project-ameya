using Ameya.Core.Conversion;
using Ameya.Core.Formats;

namespace Ameya.Engines.Images;

/// <summary>
/// Picture to picture or PDF. Follows the Mac's ImageConverter: decide which frames survive,
/// flatten onto white only where the target can't hold transparency, and report only what
/// really happened (a "filled with white" note needs at least one see-through pixel).
/// </summary>
internal static class ImageConverter
{
    public static async Task<ConversionResult> ConvertAsync(string input, string output, ConversionRequest request, Action<double> progress)
    {
        var target = FormatCatalog.Shared.Get(request.Target);
        var decoded = await WicDecoder.DecodeAsync(input, request.Source, request.Options);
        progress(0.4);

        var notes = new List<string>();
        var frames = decoded.Frames.ToList();
        // WIC writes animation only as GIF (not APNG or animated WebP).
        var keepsAnimation = target.Id == "gif";
        if (frames.Count > 1)
        {
            switch (decoded.Kind)
            {
                case ImageKind.Animated when keepsAnimation:
                    break;
                case ImageKind.Animated when target.SupportsPages:
                    notes.Add(NoteIds.AnimationBecamePages);
                    break;
                case ImageKind.Paged when target.SupportsPages:
                    break;
                case ImageKind.Animated:
                    frames = [frames[0]];
                    notes.Add(NoteIds.OnlyFirstFrameKept);
                    break;
                default:
                    frames = [frames[0]];
                    notes.Add(NoteIds.OnlyFirstPageKept);
                    break;
            }
        }

        // WIC's GIF encoder drops alpha, so GIF is flattened too (and says so when it matters).
        if (!target.SupportsAlpha || target.Id == "gif")
        {
            var transparent = frames.Any(PixelOps.HasTransparentPixels);
            frames = frames.Select(PixelOps.FlattenOnWhite).ToList();
            if (transparent) notes.Add(NoteIds.TransparencyFilledWhite);
        }

        await using (var stream = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            if (target.IsIcon)
            {
                var squares = IcoWriter.Sizes(frames[0]).Select(side => PixelOps.SquareIcon(frames[0], side)).ToList();
                await IcoWriter.WriteAsync(squares, stream);
                frames = squares;
                notes = [NoteIds.MadeSquareIcon];
            }
            else if (target.Id == "pdf")
            {
                PdfImageWriter.Write(frames, stream);
            }
            else if (WicEncoder.CanEncode(target.Id))
            {
                var animated = decoded.Kind == ImageKind.Animated && keepsAnimation && frames.Count > 1;
                if (!animated && target.Id != "tiff") frames = [frames[0]];
                await WicEncoder.EncodeAsync(frames, target.Id, animated, decoded.LoopCount, request.Options.Quality, stream);
            }
            else
            {
                throw new ConversionException($"Ameya for Windows can't write {target.DisplayName} pictures yet.");
            }
        }
        progress(1);
        return new ConversionResult { OutputBytes = new FileInfo(output).Length, Frames = frames.Count, Notes = notes };
    }
}
