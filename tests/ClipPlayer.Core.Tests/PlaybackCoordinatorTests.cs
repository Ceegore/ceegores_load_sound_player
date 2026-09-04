using ClipPlayer.Core;

namespace ClipPlayer.Core.Tests;

public sealed class PlaybackCoordinatorTests
{
    [Fact]
    public async Task InitializeAutoplaysFirstTrack()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one"), CoreFixtures.Track("two")]);
        Assert.Equal(PlaybackState.Playing, coordinator.Snapshot.State);
        Assert.Equal("one.wav", output.Started.Single().FileName);
    }

    [Fact]
    public async Task ReplacePlaylistStartsRequestedInitialTrackExactlyOnce()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one"), CoreFixtures.Track("two")], 1);
        Assert.Single(output.Started);
        Assert.Equal("two.wav", output.Started[0].FileName);
        Assert.Equal(1, coordinator.Snapshot.CurrentIndex);
    }

    [Fact]
    public async Task PreviousAndNextAutoplayAndDoNotWrap()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one"), CoreFixtures.Track("two")]);
        await coordinator.PreviousAsync();
        Assert.Single(output.Started);
        await coordinator.NextAsync();
        Assert.Equal("two.wav", output.Started[^1].FileName);
        await coordinator.NextAsync();
        Assert.Equal(2, output.Started.Count);
    }

    [Fact]
    public async Task PauseResumePreservesStateAndStoppedSpaceRestarts()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one")]);
        await coordinator.TogglePauseAsync();
        Assert.Equal(PlaybackState.Paused, coordinator.Snapshot.State);
        await coordinator.TogglePauseAsync();
        Assert.Equal(PlaybackState.Playing, coordinator.Snapshot.State);
        await coordinator.StopAsync();
        await coordinator.TogglePauseAsync();
        Assert.Equal(2, output.Started.Count);
        Assert.Equal(1, output.PauseCount);
        Assert.Equal(1, output.ResumeCount);
    }

    [Fact]
    public async Task TrackEndAdvancesAndStopsAtEnd()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one"), CoreFixtures.Track("two")]);
        await coordinator.NotifyTrackEndedAsync();
        Assert.Equal("two.wav", coordinator.Snapshot.CurrentTrack!.FileName);
        await coordinator.NotifyTrackEndedAsync();
        Assert.Equal(PlaybackState.Stopped, coordinator.Snapshot.State);
    }

    [Fact]
    public async Task StaleTrackEndedEventCannotAdvanceAReplacedPlaylist()
    {
        var output = new RecordingOutput();
        var old = CoreFixtures.Track("old");
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([old, CoreFixtures.Track("old-next")]);
        var oldRevision = coordinator.PlaylistRevision;
        var oldSelection = coordinator.Snapshot.SelectionGeneration;
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("new"), CoreFixtures.Track("new-next")]);

        await coordinator.NotifyTrackEndedAsync(old, oldRevision, oldSelection);

        Assert.Equal("new.wav", coordinator.Snapshot.CurrentTrack!.FileName);
        Assert.Equal(PlaybackState.Playing, coordinator.Snapshot.State);
        Assert.Equal(2, output.Started.Count);
    }

    [Fact]
    public async Task PlaybackFaultIsVisibleAndStopsOutput()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one")]);
        await coordinator.NotifyPlaybackFaultAsync(new IOException("device lost"));
        Assert.Equal(PlaybackState.Faulted, coordinator.Snapshot.State);
        Assert.Contains("device lost", coordinator.Snapshot.Error);
        Assert.Equal(2, output.StopCount);
    }

    [Fact]
    public async Task PreloadRequestsUpToThreeFollowingTracks()
    {
        var decoder = new RecordingDecoder();
        await using var coordinator = new PlaybackCoordinator(decoder, new RecordingOutput(), new RecordingCache());
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("0"), CoreFixtures.Track("1"), CoreFixtures.Track("2"), CoreFixtures.Track("3"), CoreFixtures.Track("4")]);
        for (var attempt = 0; attempt < 50 && decoder.Requested.Count < 4; attempt++) await Task.Delay(2);
        Assert.Equal(["0.wav", "1.wav", "2.wav", "3.wav"], decoder.Requested.Take(4).Select(track => track.FileName));
    }

    [Fact]
    public async Task DeleteMovesToRecycleBinAndSelectsSameIndex()
    {
        var recycle = new RecordingRecycleBin();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), new RecordingOutput(), recycleBin: recycle);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one"), CoreFixtures.Track("two"), CoreFixtures.Track("three")]);
        await coordinator.NextAsync();
        await coordinator.DeleteCurrentAsync();
        Assert.Equal("two.wav", recycle.Moved.Single().FileName);
        Assert.Equal("three.wav", coordinator.Snapshot.CurrentTrack!.FileName);
        Assert.DoesNotContain(coordinator.Playlist, track => track.FileName == "two.wav");
    }

    [Fact]
    public async Task FailedDeleteKeepsTrackAndRestartsPlayback()
    {
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(new RecordingDecoder(), output,
            recycleBin: new ThrowingRecycleBin());
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("one"), CoreFixtures.Track("two")]);

        var error = await Assert.ThrowsAsync<IOException>(() => coordinator.DeleteCurrentAsync().AsTask());

        Assert.Contains("Papierkorb", error.Message);
        Assert.Equal(2, coordinator.Playlist.Count);
        Assert.Equal("one.wav", coordinator.Snapshot.CurrentTrack!.FileName);
        Assert.Equal(PlaybackState.Playing, coordinator.Snapshot.State);
        Assert.Equal(2, output.Started.Count);
    }

    [Fact]
    public async Task GenericPreloadDisposesUncacheableStreamingSources()
    {
        var sources = new List<StreamingSource>();
        var decoder = new RecordingDecoder
        {
            Factory = _ =>
            {
                var source = new StreamingSource();
                sources.Add(source);
                return new DecodedAudio(ReadOnlyMemory<float>.Empty, 8_000, 1, source);
            }
        };
        await using var coordinator = new PlaybackCoordinator(decoder, new RecordingOutput(), new RecordingCache());
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("zero"), CoreFixtures.Track("one"), CoreFixtures.Track("two")]);
        for (var attempt = 0; attempt < 100 && sources.Count < 3; attempt++) await Task.Delay(2);

        Assert.Equal(3, sources.Count);
        Assert.All(sources.Skip(1), source => Assert.True(source.Disposed));
        await sources[0].DisposeAsync();
    }

    [Fact]
    public async Task EmptyPlaylistIsEmptyAndMissingDecoderIsVisible()
    {
        await using var empty = new PlaybackCoordinator();
        await empty.InitializeAsync();
        Assert.Equal(PlaybackState.Empty, empty.Snapshot.State);
        await empty.ReplacePlaylistAsync([CoreFixtures.Track("one")]);
        Assert.Equal(PlaybackState.Faulted, empty.Snapshot.State);
        Assert.Contains("Decoder", empty.Snapshot.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task StaleLoadCompletionNeverStartsOldTrack()
    {
        var first = CoreFixtures.Track("first");
        var second = CoreFixtures.Track("second");
        var decoder = new ControlledDecoder { AutoComplete = true };
        var output = new RecordingOutput();
        var cache = new RecordingCache();
        await using var coordinator = new PlaybackCoordinator(decoder, output, cache);
        await coordinator.ReplacePlaylistAsync([first, second]);
        for (var attempt = 0; attempt < 100 && cache.PutCount < 2; attempt++) await Task.Delay(2);
        decoder.EnableManual();
        await cache.InvalidateAsync(first, CancellationToken.None);
        await cache.InvalidateAsync(second, CancellationToken.None);
        output.Started.Clear();
        var oldSelection = coordinator.SelectAsync(0).AsTask();
        await decoder.FirstStarted.Task;
        var newSelection = coordinator.SelectAsync(1).AsTask();
        decoder.Complete(first);
        await decoder.SecondStarted.Task;
        decoder.Complete(second);
        await Task.WhenAll(oldSelection, newSelection);
        Assert.Equal([second], output.Started);
        Assert.Equal(second, coordinator.Snapshot.CurrentTrack);
    }

    [Fact]
    public async Task CanceledStreamingSelectionDisposesItsSource()
    {
        var decoder = new StreamingDecoder();
        var output = new StreamingOutput();
        await using var coordinator = new PlaybackCoordinator(decoder, output);
        await coordinator.ReplacePlaylistAsync([CoreFixtures.Track("first"), CoreFixtures.Track("second")]);
        var first = coordinator.SelectAsync(0).AsTask();
        await decoder.FirstPrimeStarted.Task;
        var second = coordinator.SelectAsync(1).AsTask();
        await Task.WhenAll(first, second);

        Assert.True(decoder.FirstSource.Disposed);
        Assert.Equal("second.wav", coordinator.Snapshot.CurrentTrack!.FileName);
    }

    private sealed class StreamingDecoder : ITrackDecoder
    {
        public TaskCompletionSource<bool> FirstPrimeStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public StreamingSource FirstSource { get; }
        private int _calls;
        public StreamingDecoder() => FirstSource = new(false, () => FirstPrimeStarted.TrySetResult(true));
        public ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken)
        {
            var call = Interlocked.Increment(ref _calls);
            var source = track.FileName == "first.wav" && call > 1 ? FirstSource : new StreamingSource();
            return ValueTask.FromResult(new DecodedAudio(ReadOnlyMemory<float>.Empty, 8_000, 1, source));
        }
    }

    private sealed class StreamingOutput : IStreamingAudioOutput
    {
        private IStreamingAudio? _active;
        public async ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
        {
            if (audio.Stream is { } stream)
            {
                if (_active is not null && !ReferenceEquals(_active, stream)) await _active.DisposeAsync();
                _active = stream;
                await stream.PrimeAsync(cancellationToken);
            }
        }
        public async ValueTask PlayStreamingAsync(Track track, IStreamingAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
        {
            await audio.PrimeAsync(cancellationToken);
        }
        public ValueTask PauseAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
        public ValueTask ResumeAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
        public ValueTask StopAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
    }

    private sealed class StreamingSource : IStreamingAudio
    {
        private readonly TaskCompletionSource<bool> _prime = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly bool _waitForPrime;
        private readonly Action? _started;
        public StreamingSource(bool waitForPrime = false, Action? started = null) { _waitForPrime = waitForPrime; _started = started; }
        public bool Disposed { get; private set; }
        public int SampleRate => 8_000;
        public int Channels => 1;
        public TimeSpan Duration => TimeSpan.FromSeconds(1);
        public TimeSpan Position => TimeSpan.Zero;
        public bool IsCompleted => false;
        public Exception? Failure => null;
        public ValueTask PrimeAsync(CancellationToken cancellationToken)
        {
            _started?.Invoke();
            if (!_waitForPrime) return ValueTask.CompletedTask;
            return new(_prime.Task.WaitAsync(cancellationToken));
        }
        public int Read(Span<float> destination) => 0;
        public ValueTask DisposeAsync() { Disposed = true; _prime.TrySetCanceled(); return ValueTask.CompletedTask; }
    }
}
