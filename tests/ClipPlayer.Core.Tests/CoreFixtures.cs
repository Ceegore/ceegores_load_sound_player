using ClipPlayer.Core;

namespace ClipPlayer.Core.Tests;

internal static class CoreFixtures
{
    public static Track Track(string name, long length = 1) =>
        ClipPlayer.Core.Track.Create(System.IO.Path.Combine(System.IO.Path.GetTempPath(), name + ".wav"), length);

    public static DecodedAudio Audio() => new(new float[] { 0, 0.25f, -0.25f }, 48_000, 1);
}

internal sealed class RecordingOutput : IAudioOutput
{
    public List<Track> Started { get; } = [];
    public int PauseCount { get; private set; }
    public int ResumeCount { get; private set; }
    public int StopCount { get; private set; }
    public ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
    {
        Started.Add(track);
        return ValueTask.CompletedTask;
    }
    public ValueTask PauseAsync(CancellationToken cancellationToken) { PauseCount++; return ValueTask.CompletedTask; }
    public ValueTask ResumeAsync(CancellationToken cancellationToken) { ResumeCount++; return ValueTask.CompletedTask; }
    public ValueTask StopAsync(CancellationToken cancellationToken) { StopCount++; return ValueTask.CompletedTask; }
}

internal sealed class RecordingDecoder : ITrackDecoder
{
    public List<Track> Requested { get; } = [];
    public Func<Track, DecodedAudio>? Factory { get; set; }
    public ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken)
    {
        Requested.Add(track);
        return new ValueTask<DecodedAudio>((Factory ?? (_ => CoreFixtures.Audio()))(track));
    }
}

internal sealed class ControlledDecoder : ITrackDecoder
{
    private readonly Dictionary<string, TaskCompletionSource<DecodedAudio>> _pending = new(StringComparer.OrdinalIgnoreCase);
    private int _count;
    public bool AutoComplete { get; set; }
    public TaskCompletionSource<Track> FirstStarted { get; private set; } = NewTrackSource();
    public TaskCompletionSource<Track> SecondStarted { get; private set; } = NewTrackSource();

    public ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken)
    {
        var source = new TaskCompletionSource<DecodedAudio>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[track.Path] = source;
        if (Interlocked.Increment(ref _count) == 1) FirstStarted.TrySetResult(track);
        else SecondStarted.TrySetResult(track);
        if (AutoComplete) source.TrySetResult(CoreFixtures.Audio());
        return new ValueTask<DecodedAudio>(source.Task);
    }

    public void Complete(Track track) => _pending[track.Path].TrySetResult(CoreFixtures.Audio());
    public void EnableManual()
    {
        AutoComplete = false;
        _pending.Clear();
        _count = 0;
        FirstStarted = NewTrackSource();
        SecondStarted = NewTrackSource();
    }
    private static TaskCompletionSource<Track> NewTrackSource() => new(TaskCreationOptions.RunContinuationsAsynchronously);
}

internal sealed class RecordingCache : ITrackCache
{
    private readonly Dictionary<string, DecodedAudio> _items = new(StringComparer.OrdinalIgnoreCase);
    public int PutCount { get; private set; }
    public ValueTask<DecodedAudio?> TryGetAsync(Track track, CancellationToken cancellationToken) =>
        new(_items.TryGetValue(track.Path, out var value) ? value : null);
    public ValueTask PutAsync(Track track, DecodedAudio audio, CancellationToken cancellationToken)
    {
        PutCount++;
        _items[track.Path] = audio;
        return ValueTask.CompletedTask;
    }
    public ValueTask InvalidateAsync(Track track, CancellationToken cancellationToken)
    {
        _items.Remove(track.Path);
        return ValueTask.CompletedTask;
    }
}

internal sealed class RecordingRecycleBin : IRecycleBin
{
    public List<Track> Moved { get; } = [];
    public ValueTask MoveToRecycleBinAsync(Track track, CancellationToken cancellationToken)
    {
        Moved.Add(track);
        return ValueTask.CompletedTask;
    }
}

internal sealed class ThrowingRecycleBin : IRecycleBin
{
    public ValueTask MoveToRecycleBinAsync(Track track, CancellationToken cancellationToken) =>
        ValueTask.FromException(new UnauthorizedAccessException("recycle denied"));
}
