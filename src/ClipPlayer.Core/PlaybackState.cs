namespace ClipPlayer.Core;

public enum PlaybackState
{
    Empty,
    Loading,
    Playing,
    Paused,
    Stopped,
    Faulted
}

public sealed record PlaybackSnapshot(
    PlaybackState State,
    Track? CurrentTrack,
    int CurrentIndex,
    SelectionGeneration SelectionGeneration,
    TimeSpan Position,
    string? Error)
{
    public static PlaybackSnapshot Empty { get; } =
        new(PlaybackState.Empty, null, -1, SelectionGeneration.Initial, TimeSpan.Zero, null);
}

public readonly record struct SelectionGeneration(long Value)
{
    public static SelectionGeneration Initial => new(0);
    public SelectionGeneration Next() => new(checked(Value + 1));
    public bool IsNewerThan(SelectionGeneration other) => Value > other.Value;
}
