namespace ClipPlayer.Core;

/// <summary>PCM data produced by a platform decoder. Core intentionally knows no decoder library.</summary>
public sealed record DecodedAudio
{
    public DecodedAudio(ReadOnlyMemory<float> samples, int sampleRate, int channels, IStreamingAudio? stream = null)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(sampleRate);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(channels);
        Samples = samples;
        SampleRate = sampleRate;
        Channels = channels;
        Stream = stream;
    }

    public ReadOnlyMemory<float> Samples { get; }
    public int SampleRate { get; }
    public int Channels { get; }
    public IStreamingAudio? Stream { get; }
    public bool IsStreaming => Stream is not null;
}

public interface IStreamingAudio : IAsyncDisposable
{
    int SampleRate { get; }
    int Channels { get; }
    TimeSpan Duration { get; }
    TimeSpan Position { get; }
    bool IsCompleted { get; }
    ValueTask PrimeAsync(CancellationToken cancellationToken);
    int Read(Span<float> destination);
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

public interface IStreamingAudioOutput : IAudioOutput
{
    ValueTask PlayStreamingAsync(Track track, IStreamingAudio audio, TimeSpan startAt, CancellationToken cancellationToken);
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
