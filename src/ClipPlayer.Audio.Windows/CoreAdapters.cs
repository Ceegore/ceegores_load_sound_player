using ClipPlayer.Core;

namespace ClipPlayer.Audio.Windows;

/// <summary>Bridges the platform adapter to the dependency-free Core ports.</summary>
public sealed class WindowsTrackDecoder : ITrackDecoder
{
    private readonly DecoderRegistry _registry;
    private readonly AudioFormat? _mixFormat;

    public WindowsTrackDecoder(DecoderRegistry registry, AudioFormat? mixFormat = null)
    {
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _mixFormat = mixFormat;
    }

    public ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(track);
        var local = ToLocal(track);
        return DecodeCoreAsync(local, cancellationToken);
    }

    private async ValueTask<DecodedAudio> DecodeCoreAsync(AudioTrack track, CancellationToken cancellationToken)
    {
        var request = new AudioDecodeRequest(track, _mixFormat);
        try
        {
            var audio = await _registry.DecodeAsync(request, cancellationToken).ConfigureAwait(false);
            return new DecodedAudio(audio.Samples, audio.Format.SampleRate, audio.Format.Channels);
        }
        catch (PcmClipTooLargeException)
        {
            if (_registry.Resolve(track.FullPath) is not IStreamingAudioDecoder streaming) throw;
            IStreamingAudio? stream = null;
            try
            {
                stream = await streaming.OpenStreamingAsync(request, cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                return new DecodedAudio(ReadOnlyMemory<float>.Empty, stream.SampleRate, stream.Channels, stream);
            }
            catch
            {
                if (stream is not null) await stream.DisposeAsync().ConfigureAwait(false);
                throw;
            }
        }
    }

    private static AudioTrack ToLocal(Track track) =>
        new(track.Path, track.LengthBytes, track.LastWriteTimeUtc.UtcDateTime);
}

public sealed class WindowsPcmCache(PcmCache cache, AudioFormat mixFormat, DecoderRegistry registry) : ITrackPreloadCache
{
    private readonly DecoderRegistry _registry = registry ?? throw new ArgumentNullException(nameof(registry));
    public ValueTask<DecodedAudio?> TryGetAsync(Track track, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var key = CacheKey.For(ToLocal(track), mixFormat);
        var result = cache.TryGet(key, out var audio) && audio is not null
            ? new DecodedAudio(audio.Samples, audio.Format.SampleRate, audio.Format.Channels)
            : null;
        return ValueTask.FromResult<DecodedAudio?>(result);
    }

    public ValueTask PutAsync(Track track, DecodedAudio audio, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var format = new AudioFormat(audio.SampleRate, audio.Channels);
        if (format != mixFormat) throw new ArgumentException("PCM muss dem festen Mixformat entsprechen.", nameof(audio));
        var key = CacheKey.For(ToLocal(track), mixFormat);
        cache.Put(key, new PcmAudio(format, audio.Samples), [key]);
        return ValueTask.CompletedTask;
    }

    public ValueTask PreloadAsync(IReadOnlyList<Track> tracks, int currentIndex, long generation,
        Func<long, bool>? isCurrent = null, CancellationToken cancellationToken = default)
    {
        var local = tracks.Select(ToLocal).ToArray();
        return PreloadCoreAsync(local, currentIndex, generation, isCurrent, cancellationToken);
    }

    private async ValueTask PreloadCoreAsync(IReadOnlyList<AudioTrack> tracks, int currentIndex, long generation,
        Func<long, bool>? isCurrent, CancellationToken cancellationToken)
    {
        try
        {
            await cache.PreloadAsync(tracks, currentIndex, mixFormat, generation, isCurrent, _registry, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (PcmClipTooLargeException)
        {
            // Oversized clips deliberately use the streaming path and are never retained as PCM blobs.
        }
    }

    public void Clear() => cache.Clear();

    public ValueTask InvalidateAsync(Track track, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        cache.Invalidate(CacheKey.For(ToLocal(track), mixFormat));
        return ValueTask.CompletedTask;
    }

    private static AudioTrack ToLocal(Track track) =>
        new(track.Path, track.LengthBytes, track.LastWriteTimeUtc.UtcDateTime);
}

public sealed class CoreAudioOutputAdapter(IAudioOutput output) : ClipPlayer.Core.IAudioOutput
{
    public async ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (audio.Stream is { } stream)
        {
            if (output is not IStreamingAudioOutput streamingOutput)
                throw new NotSupportedException("Ausgabegerät unterstützt keinen Streaming-Pfad.");
            await streamingOutput.PlayStreamingAsync(track, stream, startAt, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            var format = new AudioFormat(audio.SampleRate, audio.Channels);
            if (output is WasapiPlaybackOutput wasapi) wasapi.StopPlayback();
            if (output is WasapiPlaybackOutput trackedOutput)
                trackedOutput.SwitchTo(track, new PcmAudio(format, audio.Samples), startAt);
            else
                output.SwitchTo(new PcmAudio(format, audio.Samples), startAt);
            output.Play();
        }
    }

    public ValueTask PauseAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); output.Pause(); return ValueTask.CompletedTask;
    }

    public ValueTask ResumeAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); output.Play(); return ValueTask.CompletedTask;
    }

    public ValueTask StopAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); output.StopPlayback(); return ValueTask.CompletedTask;
    }
}
