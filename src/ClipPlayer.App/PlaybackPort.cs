using System.Windows.Media;

namespace ClipPlayer.App;

/// <summary>Adapter seam for ClipPlayer.Audio.Windows/Core. UI code never touches a decoder.</summary>
public interface IPlaybackPort : IAsyncDisposable
{
    TimeSpan Position { get; }
    TimeSpan Duration { get; }
    bool IsPlaying { get; }
    double Volume { get; set; }
    Task PlayAsync(string path, CancellationToken cancellationToken);
    Task PauseAsync(CancellationToken cancellationToken);
    Task ResumeAsync(CancellationToken cancellationToken);
    Task StopAsync(CancellationToken cancellationToken);
    Task SeekAsync(TimeSpan position, CancellationToken cancellationToken);
    Task PreloadAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken);
}

/// <summary>
/// Small OS decoder fallback. The composition root can replace it with the Core/NAudio
/// adapter; it intentionally has no file access on the UI render path after Open completes.
/// </summary>
public sealed class WpfPlaybackPort : IPlaybackPort
{
    private readonly MediaPlayer _player = new();
    private readonly object _gate = new();
    private TaskCompletionSource<bool>? _opening;
    private bool _disposed;

    public WpfPlaybackPort()
    {
        _player.MediaOpened += (_, _) => _opening?.TrySetResult(true);
        _player.MediaFailed += (_, args) =>
            _opening?.TrySetException(new InvalidOperationException(args.ErrorException?.Message ?? "Audio konnte nicht geöffnet werden."));
    }

    public TimeSpan Position => _player.Position;
    public TimeSpan Duration => _player.NaturalDuration.HasTimeSpan ? _player.NaturalDuration.TimeSpan : TimeSpan.Zero;
    public bool IsPlaying { get; private set; }
    public double Volume { get => _player.Volume; set => _player.Volume = Math.Clamp(value, 0, 1); }

    public async Task PlayAsync(string path, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        Task opening;
        lock (_gate)
        {
            _player.Stop();
            _opening = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            opening = _opening.Task;
            _player.Open(new Uri(path, UriKind.Absolute));
        }
        await opening.WaitAsync(TimeSpan.FromSeconds(8), cancellationToken).ConfigureAwait(true);
        cancellationToken.ThrowIfCancellationRequested();
        _player.Play();
        IsPlaying = true;
    }

    public Task PauseAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _player.Pause();
        IsPlaying = false;
        return Task.CompletedTask;
    }

    public Task ResumeAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _player.Play();
        IsPlaying = true;
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _player.Stop();
        _player.Close();
        IsPlaying = false;
        return Task.CompletedTask;
    }

    public Task SeekAsync(TimeSpan position, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _player.Position = position < TimeSpan.Zero ? TimeSpan.Zero : position;
        return Task.CompletedTask;
    }

    public Task PreloadAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken)
    {
        // The production adapter implements bounded PCM preloading. MediaPlayer has no
        // safe public secondary-buffer API, so this fallback does not speculate on files.
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        _player.Close();
        return ValueTask.CompletedTask;
    }
}
