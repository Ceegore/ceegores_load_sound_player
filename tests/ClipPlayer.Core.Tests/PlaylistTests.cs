using ClipPlayer.Core;

namespace ClipPlayer.Core.Tests;

public sealed class PlaylistTests
{
    [Fact]
    public void EmptyPlaylistHasNoSelectionOrNavigation()
    {
        var playlist = Playlist.Empty;
        Assert.Empty(playlist);
        Assert.Null(playlist.Current);
        Assert.False(playlist.CanMovePrevious);
        Assert.False(playlist.CanMoveNext);
    }

    [Fact]
    public void NavigationStaysAtBoundariesWithoutWrap()
    {
        var playlist = new Playlist([CoreFixtures.Track("a"), CoreFixtures.Track("b")]).Select(0);
        Assert.Same(playlist, playlist.MovePrevious());
        Assert.Equal("b.wav", playlist.MoveNext().Current!.FileName);
        Assert.Equal("b.wav", playlist.MoveNext().MoveNext().Current!.FileName);
    }

    [Fact]
    public void RemoveCurrentPrefersSameIndexThenPredecessor()
    {
        var playlist = new Playlist([CoreFixtures.Track("a"), CoreFixtures.Track("b"), CoreFixtures.Track("c")]).Select(1);
        var afterMiddle = playlist.RemoveAt(1, out var middleIndex);
        Assert.Equal(1, middleIndex);
        Assert.Equal("c.wav", afterMiddle.Current!.FileName);
        var afterLast = afterMiddle.RemoveAt(1, out var lastIndex);
        Assert.Equal(0, lastIndex);
        Assert.Equal("a.wav", afterLast.Current!.FileName);
    }

    [Fact]
    public void NaturalSortOrdersNumericFilenames()
    {
        var playlist = new Playlist([CoreFixtures.Track("clip10"), CoreFixtures.Track("clip2"), CoreFixtures.Track("clip1")]).SortNaturally();
        Assert.Equal(["clip1.wav", "clip2.wav", "clip10.wav"], playlist.Select(track => track.FileName));
    }

    [Fact]
    public void FromPathsRejectsUnknownExtensions()
    {
        Assert.Throws<NotSupportedException>(() => Playlist.FromPaths(["sound.ogg"]));
    }
}
