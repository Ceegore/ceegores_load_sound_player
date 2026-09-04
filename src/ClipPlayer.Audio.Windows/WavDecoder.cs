using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

public sealed class WavDecoder : IAudioDecoder
{
    public bool CanDecode(string extension) => string.Equals(extension, ".wav", StringComparison.OrdinalIgnoreCase);

    public ValueTask<PcmAudio> DecodeAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        return DecodeCoreAsync(request, cancellationToken);
    }

    private static async ValueTask<PcmAudio> DecodeCoreAsync(AudioDecodeRequest request, CancellationToken cancellationToken)
    {
        using var reader = new WaveFileReader(request.Track.FullPath);
        var encoding = reader.WaveFormat.Encoding;
        if (encoding is not (WaveFormatEncoding.Pcm or WaveFormatEncoding.IeeeFloat))
            throw new NotSupportedException("WAV muss PCM oder IEEE Float enthalten.");
        if (reader.WaveFormat.BitsPerSample is not (8 or 16 or 24 or 32))
            throw new NotSupportedException("WAV-Bittiefe wird nicht unterstützt.");
        return await DecoderSupport.ReadSamplesAsync(reader, reader.ToSampleProvider(), request, cancellationToken);
    }
}
