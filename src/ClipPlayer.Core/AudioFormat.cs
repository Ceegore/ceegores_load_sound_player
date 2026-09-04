namespace ClipPlayer.Core;

/// <summary>Audio containers supported by version one.</summary>
public enum AudioFormat
{
    Unknown = 0,
    Wav = 1,
    Mp3 = 2,
    Flac = 3
}

public static class AudioFormatExtensions
{
    public static bool TryFromPath(string path, out AudioFormat format)
    {
        ArgumentNullException.ThrowIfNull(path);
        format = Path.GetExtension(path).ToUpperInvariant() switch
        {
            ".WAV" => AudioFormat.Wav,
            ".MP3" => AudioFormat.Mp3,
            ".FLAC" => AudioFormat.Flac,
            _ => AudioFormat.Unknown
        };
        return format != AudioFormat.Unknown;
    }

    public static bool IsSupported(this AudioFormat format) =>
        format is AudioFormat.Wav or AudioFormat.Mp3 or AudioFormat.Flac;
}
