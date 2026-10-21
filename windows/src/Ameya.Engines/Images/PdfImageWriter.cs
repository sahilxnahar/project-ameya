using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace Ameya.Engines.Images;

/// <summary>
/// Writes pictures as PDF pages, one page per frame, sized from each picture's resolution
/// (the Mac's PDFWriter does the same through Core Graphics). Pixels are stored losslessly with
/// Flate compression; see-through pixels keep their transparency as a soft mask.
/// </summary>
internal static class PdfImageWriter
{
    public static void Write(IReadOnlyList<ImageFrame> frames, Stream output)
    {
        var offsets = new List<long>();
        var writer = new PdfOutput(output);
        writer.Text("%PDF-1.7\n%âãÏÓ\n");

        // Objects: 1 catalog, 2 page tree, then per page: page, contents, image, soft mask (if any).
        var pageObjects = new List<int>();
        var next = 3;
        var plans = frames.Select(frame =>
        {
            var transparent = PixelOps.HasTransparentPixels(frame);
            var plan = (Page: next, Contents: next + 1, Image: next + 2, Mask: transparent ? next + 3 : 0);
            next += transparent ? 4 : 3;
            pageObjects.Add(plan.Page);
            return plan;
        }).ToList();

        void Begin(int number)
        {
            while (offsets.Count < number) offsets.Add(0);
            offsets[number - 1] = writer.Position;
            writer.Text($"{number} 0 obj\n");
        }

        Begin(1);
        writer.Text("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        Begin(2);
        writer.Text($"<< /Type /Pages /Kids [{string.Join(' ', pageObjects.Select(p => $"{p} 0 R"))}] /Count {frames.Count} >>\nendobj\n");

        for (var i = 0; i < frames.Count; i++)
        {
            var frame = frames[i];
            var plan = plans[i];
            var width = Number(frame.Width * 72.0 / frame.DpiX);
            var height = Number(frame.Height * 72.0 / frame.DpiY);

            Begin(plan.Page);
            writer.Text($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] " +
                        $"/Resources << /XObject << /Im0 {plan.Image} 0 R >> >> /Contents {plan.Contents} 0 R >>\nendobj\n");

            Begin(plan.Contents);
            WriteStream(writer, "", Encoding.ASCII.GetBytes($"q {width} 0 0 {height} 0 0 cm /Im0 Do Q\n"), compress: false);

            Begin(plan.Image);
            var mask = plan.Mask != 0 ? $" /SMask {plan.Mask} 0 R" : "";
            WriteStream(writer,
                $"/Type /XObject /Subtype /Image /Width {frame.Width} /Height {frame.Height} /ColorSpace /DeviceRGB /BitsPerComponent 8{mask}",
                Channels(frame, alpha: false), compress: true);

            if (plan.Mask != 0)
            {
                Begin(plan.Mask);
                WriteStream(writer,
                    $"/Type /XObject /Subtype /Image /Width {frame.Width} /Height {frame.Height} /ColorSpace /DeviceGray /BitsPerComponent 8",
                    Channels(frame, alpha: true), compress: true);
            }
        }

        var xref = writer.Position;
        var builder = new StringBuilder();
        builder.Append(CultureInfo.InvariantCulture, $"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets) builder.Append(CultureInfo.InvariantCulture, $"{offset:D10} 00000 n \n");
        builder.Append(CultureInfo.InvariantCulture, $"trailer\n<< /Size {offsets.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        writer.Text(builder.ToString());
    }

    private static void WriteStream(PdfOutput writer, string dictionary, byte[] data, bool compress)
    {
        var body = data;
        var filter = "";
        if (compress)
        {
            using var compressed = new MemoryStream();
            using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(data);
            body = compressed.ToArray();
            filter = " /Filter /FlateDecode";
        }
        writer.Text($"<< {dictionary}{filter} /Length {body.Length} >>\nstream\n".Replace("<<  /", "<< /", StringComparison.Ordinal));
        writer.Bytes(body);
        writer.Text("\nendstream\nendobj\n");
    }

    /// <summary>RGB bytes (from BGRA), or the alpha channel alone.</summary>
    private static byte[] Channels(ImageFrame frame, bool alpha)
    {
        var pixels = frame.Pixels;
        var count = frame.Width * frame.Height;
        var result = new byte[alpha ? count : count * 3];
        for (var i = 0; i < count; i++)
        {
            if (alpha)
            {
                result[i] = pixels[i * 4 + 3];
            }
            else
            {
                result[i * 3] = pixels[i * 4 + 2];
                result[i * 3 + 1] = pixels[i * 4 + 1];
                result[i * 3 + 2] = pixels[i * 4];
            }
        }
        return result;
    }

    private static string Number(double value) => Math.Round(value, 3).ToString("0.###", CultureInfo.InvariantCulture);

    /// <summary>Tracks the byte position, which the cross-reference table needs.</summary>
    private sealed class PdfOutput(Stream stream)
    {
        public long Position { get; private set; }

        public void Text(string text) => Bytes(Encoding.Latin1.GetBytes(text));

        public void Bytes(byte[] bytes)
        {
            stream.Write(bytes);
            Position += bytes.Length;
        }
    }
}
