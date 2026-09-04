namespace ClipPlayer.Audio.Windows;

public enum SampleEncoding
{
    IeeeFloat
}

public readonly record struct AudioFormat(int SampleRate, int Channels,
    SampleEncoding Encoding = SampleEncoding.IeeeFloat)
{
    public const int BytesPerSample = 4;
    public int BlockAlign => checked(Channels * BytesPerSample);
    public bool IsValid => SampleRate is > 0 and <= 384_000 && Channels is > 0 and <= 32;
    public override string ToString() => $"{SampleRate} Hz, {Channels} ch, {Encoding}";
}

public sealed record AudioTrack(string FullPath, long Length, DateTime LastWriteTimeUtc)
{
    public static AudioTrack FromPath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var full = Path.GetFullPath(path);
        var info = new FileInfo(full);
        return new AudioTrack(full, info.Length, info.LastWriteTimeUtc);
    }
}

public sealed record AudioDecodeRequest(AudioTrack Track, AudioFormat? TargetFormat = null);
