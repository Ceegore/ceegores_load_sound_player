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
}
