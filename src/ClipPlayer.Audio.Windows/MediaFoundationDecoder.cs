using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

/// <summary>Uses Windows Media Foundation for MP3/FLAC; no codec binaries are redistributed.</summary>
public sealed class MediaFoundationDecoder : IAudioDecoder, IStreamingAudioDecoder
{
    public bool CanDecode(string extension) => extension.Equals(".mp3", StringComparison.OrdinalIgnoreCase)
        || extension.Equals(".flac", StringComparison.OrdinalIgnoreCase);

    public ValueTask<PcmAudio> DecodeAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        return DecodeCoreAsync(request, cancellationToken);
    }

    private static async ValueTask<PcmAudio> DecodeCoreAsync(AudioDecodeRequest request, CancellationToken cancellationToken)
    {
        using var reader = new MediaFoundationReader(request.Track.FullPath);
        return await DecoderSupport.ReadSamplesAsync(reader, reader.ToSampleProvider(), request, cancellationToken);
    }

    public ValueTask<ClipPlayer.Core.IStreamingAudio> OpenStreamingAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult<ClipPlayer.Core.IStreamingAudio>(StreamingPcmAudioSource.OpenMediaFoundation(request));
    }
}
