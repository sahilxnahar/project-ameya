using System.Buffers.Binary;
using System.Text;

namespace Ameya.Core.Files;

/// <summary>A TAR stream that breaks Ameya's strict rules. Messages match the Mac's wording.</summary>
public sealed class TarStreamException(string message) : IOException(message);

/// <summary>
/// A small, strict ustar writer and reader for handing several files between the app and the
/// worker over one stdin/stdout stream. Port of the Mac's TarStream.swift: only what Ameya itself
/// writes is accepted (flat names, regular files, an empty prefix field, verified checksums, no
/// duplicates, caps on entries and bytes). Sizes are octal, or GNU base-256 from 8 GiB up.
/// </summary>
public static class TarStream
{
    public const int BlockSize = 512;
    private const int ChunkSize = 4 << 20;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public sealed record Limits(int MaxEntries = 10_000, long MaxTotalBytes = 64L << 30);

    /// <summary>Whether a name may appear in a stream: flat, visible, printable, under 100 UTF-8 bytes.</summary>
    public static bool IsValidName(string name)
    {
        var bytes = Encoding.UTF8.GetBytes(name);
        if (bytes.Length == 0 || bytes.Length >= 100 || name.StartsWith('.') || name.Contains('/') || name.Contains('\\')) return false;
        return !bytes.Any(b => b < 0x20 || b == 0x7F);
    }

    /// <summary>Streams files into a TAR stream. Call <see cref="Finish"/> once at the end.</summary>
    public sealed class Writer(Stream output)
    {
        private readonly HashSet<string> _names = new(StringComparer.Ordinal);

        public long BytesWritten { get; private set; }

        public void Add(string name, string path)
        {
            Claim(name);
            using var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
            var size = reader.Length;
            Write(Header(name, size));
            var buffer = new byte[Math.Min(ChunkSize, Math.Max(size, 1))];
            var remaining = size;
            while (remaining > 0)
            {
                var read = reader.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                if (read == 0) throw new TarStreamException("The file bundle ended too early."); // the file shrank
                Write(buffer.AsSpan(0, read));
                remaining -= read;
            }
            Pad(size);
        }

        public void Add(string name, ReadOnlySpan<byte> data)
        {
            Claim(name);
            Write(Header(name, data.Length));
            Write(data);
            Pad(data.Length);
        }

        /// <summary>Writes the two zero blocks that end the stream.</summary>
        public void Finish() => Write(new byte[2 * BlockSize]);

        private void Claim(string name)
        {
            if (!IsValidName(name)) throw new TarStreamException($"A file name in the bundle isn't allowed: {name}");
            if (!_names.Add(name)) throw new TarStreamException($"The file bundle names {name} twice.");
        }

        private void Pad(long size)
        {
            var remainder = (int)(size % BlockSize);
            if (remainder != 0) Write(new byte[BlockSize - remainder]);
        }

        private void Write(ReadOnlySpan<byte> data)
        {
            output.Write(data);
            BytesWritten += data.Length;
        }
    }

    /// <summary>Writes files (name, path) and the end marker. Returns the bytes written.</summary>
    public static long Write(IEnumerable<(string Name, string Path)> files, Stream output)
    {
        var writer = new Writer(output);
        foreach (var (name, path) in files) writer.Add(name, path);
        writer.Finish();
        return writer.BytesWritten;
    }

    internal static byte[] Header(string name, long size)
    {
        var block = new byte[BlockSize];
        void Put(string text, int offset) => Encoding.UTF8.GetBytes(text).CopyTo(block, offset);
        Put(name, 0);
        Put("0000644", 100);
        Put("0000000", 108);
        Put("0000000", 116);
        EncodeSize(size).CopyTo(block, 124);
        Put("00000000000", 136); // mtime: 1970, so streams are reproducible
        block[156] = (byte)'0';
        Put("ustar", 257); // followed by NUL
        Put("00", 263);
        // Checksum: sum of all bytes with the checksum field counted as spaces.
        for (var i = 148; i < 156; i++) block[i] = 0x20;
        var sum = block.Sum(b => (int)b);
        Put(Convert.ToString(sum, 8).PadLeft(6, '0'), 148);
        block[154] = 0;
        block[155] = 0x20;
        return block;
    }

    /// <summary>The 12-byte size field: 11 octal digits and a NUL, or base-256 (high bit set) from 8 GiB up.</summary>
    public static byte[] EncodeSize(long size)
    {
        if (size < 0) throw new TarStreamException("The file bundle is too large.");
        if (size <= 0x1FFFFFFFF) // 0o77777777777
        {
            return [.. Encoding.ASCII.GetBytes(Convert.ToString(size, 8).PadLeft(11, '0')), 0];
        }
        var field = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(field.AsSpan(4), (ulong)size);
        field[0] = 0x80;
        return field;
    }

    /// <summary>Reads a size field written by <see cref="EncodeSize"/> (octal, or base-256).</summary>
    public static long DecodeSize(ReadOnlySpan<byte> field)
    {
        if (field.Length != 12) throw Bad("size field");
        if ((field[0] & 0x80) != 0)
        {
            if (field[0] != 0x80 || field[1] != 0 || field[2] != 0 || field[3] != 0) throw Bad("size out of range");
            var value = BinaryPrimitives.ReadUInt64BigEndian(field[4..]);
            if (value > long.MaxValue) throw Bad("size out of range");
            return (long)value;
        }
        return Octal(field, "size");
    }

    private static long Octal(ReadOnlySpan<byte> field, string what)
    {
        long value = 0;
        var digits = 0;
        var ended = false;
        foreach (var b in field)
        {
            if (b is 0 or 0x20)
            {
                if (digits > 0) ended = true;
                continue;
            }
            if (ended || b < (byte)'0' || b > (byte)'7') throw Bad($"{what} field");
            value = value * 8 + (b - (byte)'0');
            digits++;
        }
        if (digits == 0) throw Bad($"{what} field");
        return value;
    }

    private static TarStreamException Bad(string detail) => new($"The file bundle is damaged ({detail}).");

    /// <summary>Extracts every entry into an existing directory and returns the names in stream
    /// order. Files are created exclusively, so nothing already in the directory is replaced.</summary>
    public static IReadOnlyList<string> Extract(Stream input, string directory, Limits? limits = null)
    {
        limits ??= new Limits();
        var names = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); // Windows names ignore case
        long total = 0;
        var buffer = new byte[ChunkSize];
        while (true)
        {
            var block = ReadExactly(input, BlockSize);
            if (block.All(b => b == 0))
            {
                var second = ReadExactly(input, BlockSize);
                if (!second.All(b => b == 0)) throw Bad("end marker");
                return names;
            }
            var (name, size) = ParseHeader(block);
            if (!seen.Add(name)) throw new TarStreamException($"The file bundle names {name} twice.");
            if (names.Count >= limits.MaxEntries) throw new TarStreamException("The file bundle has too many files.");
            total += size;
            if (total > limits.MaxTotalBytes) throw new TarStreamException("The file bundle is too large.");
            if (!IsSafeWindowsName(name)) throw new TarStreamException($"A file name in the bundle isn't allowed: {name}");

            var path = Path.Combine(directory, name);
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                var remaining = size;
                while (remaining > 0)
                {
                    var count = (int)Math.Min(buffer.Length, remaining);
                    FillExactly(input, buffer, count);
                    output.Write(buffer, 0, count);
                    remaining -= count;
                }
            }
            var padding = (int)((BlockSize - size % BlockSize) % BlockSize);
            if (padding > 0) ReadExactly(input, padding);
            names.Add(name);
        }
    }

    /// <summary>Validates one header block and returns the entry's name and size.</summary>
    internal static (string Name, long Size) ParseHeader(byte[] block)
    {
        if (block.Length != BlockSize) throw new TarStreamException("The file bundle ended too early.");
        var stored = Octal(block.AsSpan(148, 8), "checksum");
        long sum = 0;
        for (var i = 0; i < block.Length; i++) sum += i is >= 148 and < 156 ? 0x20 : block[i];
        if (stored != sum) throw new TarStreamException("The file bundle is damaged (checksum mismatch).");
        if (!block.AsSpan(257, 6).SequenceEqual("ustar\0"u8) || !block.AsSpan(263, 2).SequenceEqual("00"u8))
        {
            throw Bad("not a POSIX ustar header");
        }
        var nameLength = Array.IndexOf(block, (byte)0, 0, 100);
        if (nameLength < 0) nameLength = 100;
        string name;
        try { name = StrictUtf8.GetString(block, 0, nameLength); }
        catch (DecoderFallbackException) { throw new TarStreamException("A file name in the bundle isn't allowed: (not UTF-8)"); }
        if (block.AsSpan(345, 155).ContainsAnyExcept((byte)0)) throw new TarStreamException($"A file name in the bundle isn't allowed: {name} (prefix)");
        if (!IsValidName(name)) throw new TarStreamException($"A file name in the bundle isn't allowed: {name}");
        var type = block[156];
        if (type != (byte)'0' && type != 0) throw new TarStreamException($"Only plain files are allowed in the bundle ({name}).");
        return (name, DecodeSize(block.AsSpan(124, 12)));
    }

    /// <summary>Extra rules on Windows, where some names are devices or can't be created:
    /// no reserved device names, no ':' (alternate data streams), no trailing dot or space.</summary>
    internal static bool IsSafeWindowsName(string name)
    {
        if (name.IndexOfAny([':', '*', '?', '"', '<', '>', '|']) >= 0) return false;
        if (name.EndsWith('.') || name.EndsWith(' ')) return false;
        var stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        string[] devices = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"];
        if (devices.Contains(stem)) return false;
        return !(stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal))
                 && char.IsAsciiDigit(stem[3]));
    }

    private static byte[] ReadExactly(Stream input, int count)
    {
        var bytes = new byte[count];
        FillExactly(input, bytes, count);
        return bytes;
    }

    private static void FillExactly(Stream input, byte[] buffer, int count)
    {
        var offset = 0;
        while (offset < count)
        {
            var read = input.Read(buffer, offset, count - offset);
            if (read == 0) throw new TarStreamException("The file bundle ended too early.");
            offset += read;
        }
    }
}
