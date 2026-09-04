namespace ClipPlayer.Core;

/// <summary>An immutable file identity used by the playback layer.</summary>
public sealed record Track
{
    public string Path { get; }
    public AudioFormat Format { get; }
    public long LengthBytes { get; }
    public DateTimeOffset LastWriteTimeUtc { get; }
    public string FileName => System.IO.Path.GetFileName(Path);

    private Track(string path, AudioFormat format, long lengthBytes, DateTimeOffset lastWriteTimeUtc)
    {
        Path = path;
        Format = format;
        LengthBytes = lengthBytes;
        LastWriteTimeUtc = lastWriteTimeUtc;
    }

    public static Track Create(
        string path,
        long lengthBytes = 0,
        DateTimeOffset? lastWriteTimeUtc = null)
    {
        var normalized = NormalizePath(path);
        if (!AudioFormatExtensions.TryFromPath(normalized, out var format))
        {
            throw new NotSupportedException($"Nicht unterstütztes Audioformat: {System.IO.Path.GetExtension(normalized)}");
        }

        ArgumentOutOfRangeException.ThrowIfNegative(lengthBytes);

        return new Track(normalized, format, lengthBytes, lastWriteTimeUtc ?? DateTimeOffset.MinValue);
    }

    public static Track FromFile(string path)
    {
        var normalized = NormalizePath(path);
        var info = new FileInfo(normalized);
        if (!info.Exists)
        {
            throw new FileNotFoundException("Audiodatei nicht gefunden.", normalized);
        }

        return Create(normalized, info.Length, info.LastWriteTimeUtc);
    }

    public static bool TryCreate(string path, out Track? track)
    {
        track = null;
        try
        {
            track = Create(path);
            return true;
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    public static string NormalizePath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        try
        {
            return System.IO.Path.GetFullPath(path.Trim());
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new ArgumentException("Der Audiodateipfad ist ungültig.", nameof(path), exception);
        }
    }
}
