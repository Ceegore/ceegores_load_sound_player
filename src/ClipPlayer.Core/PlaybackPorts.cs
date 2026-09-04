namespace ClipPlayer.Core;

/// <summary>PCM data produced by a platform decoder. Core intentionally knows no decoder library.</summary>
public sealed record DecodedAudio
{
    public DecodedAudio(ReadOnlyMemory<float> samples, int sampleRate, int channels)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(sampleRate);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(channels);
        Samples = samples;
        SampleRate = sampleRate;
        Channels = channels;
    }

    public ReadOnlyMemory<float> Samples { get; }
    public int SampleRate { get; }
    public int Channels { get; }
}

public interface ITrackDecoder
{
    ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken);
}

public interface ITrackCache
{
    ValueTask<DecodedAudio?> TryGetAsync(Track track, CancellationToken cancellationToken);
    ValueTask PutAsync(Track track, DecodedAudio audio, CancellationToken cancellationToken);
    ValueTask InvalidateAsync(Track track, CancellationToken cancellationToken);
}

public interface IAudioOutput
{
    ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken);
    ValueTask PauseAsync(CancellationToken cancellationToken);
    ValueTask ResumeAsync(CancellationToken cancellationToken);
    ValueTask StopAsync(CancellationToken cancellationToken);
}

public interface IRecycleBin
{
    ValueTask MoveToRecycleBinAsync(Track track, CancellationToken cancellationToken);
}

public interface IUiDispatcher
{
    ValueTask InvokeAsync(Action update, CancellationToken cancellationToken);
}

public sealed class NullAudioOutput : IAudioOutput
{
    public ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken) => ValueTask.CompletedTask;
    public ValueTask PauseAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
    public ValueTask ResumeAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
    public ValueTask StopAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
}
