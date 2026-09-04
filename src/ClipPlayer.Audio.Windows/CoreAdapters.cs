using ClipPlayer.Core;

namespace ClipPlayer.Audio.Windows;

/// <summary>Bridges the platform adapter to the dependency-free Core ports.</summary>
public sealed class WindowsTrackDecoder(DecoderRegistry registry) : ITrackDecoder
{
    public ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(track);
        var local = ToLocal(track);
        return DecodeCoreAsync(local, cancellationToken);
    }

    private async ValueTask<DecodedAudio> DecodeCoreAsync(AudioTrack track, CancellationToken cancellationToken)
    {
        var audio = await registry.DecodeAsync(new AudioDecodeRequest(track), cancellationToken).ConfigureAwait(false);
        return new DecodedAudio(audio.Samples, audio.Format.SampleRate, audio.Format.Channels);
    }

    private static AudioTrack ToLocal(Track track) =>
        new(track.Path, track.LengthBytes, track.LastWriteTimeUtc.UtcDateTime);
}

public sealed class WindowsPcmCache(PcmCache cache, AudioFormat mixFormat) : ITrackCache
{
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
        cache.Put(CacheKey.For(ToLocal(track), format), new PcmAudio(format, audio.Samples.ToArray()));
        return ValueTask.CompletedTask;
    }

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
    public ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var format = new AudioFormat(audio.SampleRate, audio.Channels);
        output.SwitchTo(new PcmAudio(format, audio.Samples.ToArray()), startAt);
        output.Play();
        return ValueTask.CompletedTask;
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
