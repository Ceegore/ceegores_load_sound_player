namespace ClipPlayer.Audio.Windows;

public interface IAudioDecoder
{
    bool CanDecode(string extension);
    ValueTask<PcmAudio> DecodeAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default);
}

public interface IStreamingAudioDecoder
{
    ValueTask<ClipPlayer.Core.IStreamingAudio> OpenStreamingAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default);
}

public sealed class DecoderRegistry(IEnumerable<IAudioDecoder> decoders) : IAudioDecoder
{
    private readonly IReadOnlyList<IAudioDecoder> _decoders = decoders.ToArray();

    public IAudioDecoder Resolve(string path)
    {
        var extension = Path.GetExtension(path);
        return _decoders.FirstOrDefault(d => d.CanDecode(extension))
            ?? throw new NotSupportedException($"Nicht unterstütztes Audioformat: {extension}");
    }

    public ValueTask<PcmAudio> DecodeAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default) =>
        Resolve(request.Track.FullPath).DecodeAsync(request, cancellationToken);

    public bool CanDecode(string extension) => _decoders.Any(decoder => decoder.CanDecode(extension));
}
