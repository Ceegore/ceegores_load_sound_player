namespace ClipPlayer.Core;

/// <summary>Immutable ordered selection of supported tracks.</summary>
public sealed class Playlist : IReadOnlyList<Track>
{
    private readonly Track[] _tracks;

    public Playlist(IEnumerable<Track> tracks, int currentIndex = -1)
    {
        ArgumentNullException.ThrowIfNull(tracks);
        _tracks = tracks.ToArray();
        if (currentIndex < -1 || currentIndex >= _tracks.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(currentIndex));
        }

        CurrentIndex = currentIndex;
    }

    public static Playlist Empty { get; } = new(Array.Empty<Track>());
    public int Count => _tracks.Length;
    public int CurrentIndex { get; }
    public Track? Current => CurrentIndex >= 0 ? _tracks[CurrentIndex] : null;
    public bool CanMovePrevious => CurrentIndex > 0;
    public bool CanMoveNext => CurrentIndex >= 0 && CurrentIndex < Count - 1;
    public Track this[int index] => _tracks[index];

    public IEnumerator<Track> GetEnumerator() => ((IEnumerable<Track>)_tracks).GetEnumerator();
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => _tracks.GetEnumerator();

    public Playlist Select(int index)
    {
        if (index < 0 || index >= Count) throw new ArgumentOutOfRangeException(nameof(index));
        return new Playlist(_tracks, index);
    }

    public Playlist MovePrevious() => CanMovePrevious ? Select(CurrentIndex - 1) : this;
    public Playlist MoveNext() => CanMoveNext ? Select(CurrentIndex + 1) : this;

    public Playlist RemoveAt(int index, out int nextIndex)
    {
        if (index < 0 || index >= Count) throw new ArgumentOutOfRangeException(nameof(index));
        var remaining = new Track[Count - 1];
        Array.Copy(_tracks, 0, remaining, 0, index);
        Array.Copy(_tracks, index + 1, remaining, index, Count - index - 1);
        nextIndex = remaining.Length == 0 ? -1 : Math.Min(index, remaining.Length - 1);
        return new Playlist(remaining, nextIndex);
    }

    public Playlist SortNaturally(int selectedIndex = -1)
    {
        var selected = selectedIndex >= 0 && selectedIndex < Count ? _tracks[selectedIndex] : Current;
        var sorted = _tracks.ToArray();
        Array.Sort(sorted, NaturalTrackComparer.Instance);
        var newIndex = selected is null ? -1 : Array.IndexOf(sorted, selected);
        return new Playlist(sorted, newIndex);
    }

    public static Playlist FromPaths(IEnumerable<string> paths, bool naturalSort = false)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var tracks = paths.Select(path => Track.Create(path));
        var playlist = new Playlist(tracks);
        return naturalSort ? playlist.SortNaturally() : playlist;
    }
}
