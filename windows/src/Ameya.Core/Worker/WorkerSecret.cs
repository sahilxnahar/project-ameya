using System.Buffers.Binary;
using System.Text;

namespace Ameya.Core.Worker;

/// <summary>
/// Keeps passwords off the worker's command line, where other processes of the same user could
/// read them. The runner sends the secret ahead of the file on the worker's stdin: a 4-byte
/// big-endian length, then UTF-8 bytes (the same framing as the Mac). Nothing touches the disk.
/// </summary>
public static class WorkerSecret
{
    /// <summary>Longest password accepted, in UTF-8 bytes.</summary>
    public const int MaxBytes = 4_096;

    private const string Malformed = "The converter couldn't read the password.";

    public static byte[] Header(string secret)
    {
        var bytes = Encoding.UTF8.GetBytes(secret);
        if (bytes.Length > MaxBytes) throw new InvalidDataException(Malformed);
        var header = new byte[4 + bytes.Length];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)bytes.Length);
        bytes.CopyTo(header, 4);
        return header;
    }

    /// <summary>Reads the header from the start of the worker's stdin, consuming exactly its bytes.</summary>
    public static string Receive(Stream input)
    {
        var length = (int)Math.Min(BinaryPrimitives.ReadUInt32BigEndian(ReadExactly(input, 4)), int.MaxValue);
        if (length > MaxBytes) throw new InvalidDataException(Malformed);
        try
        {
            return new UTF8Encoding(false, true).GetString(ReadExactly(input, length));
        }
        catch (DecoderFallbackException)
        {
            throw new InvalidDataException(Malformed);
        }
    }

    /// <summary>Writes the header and then the whole source to a pipe that feeds the worker.
    /// Stops quietly when the worker exits without reading everything.</summary>
    public static async Task FeedAsync(string secret, Stream source, Stream pipe)
    {
        try
        {
            await pipe.WriteAsync(Header(secret)).ConfigureAwait(false);
            await source.CopyToAsync(pipe, 1 << 20).ConfigureAwait(false);
        }
        catch (IOException)
        {
            // The worker closed its stdin (finished, failed or was stopped); nothing to report.
        }
        finally
        {
            await pipe.DisposeAsync().ConfigureAwait(false);
        }
    }

    private static byte[] ReadExactly(Stream input, int count)
    {
        var bytes = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var read = input.Read(bytes, offset, count - offset);
            if (read == 0) throw new InvalidDataException(Malformed);
            offset += read;
        }
        return bytes;
    }
}
