using System.IO;
using ClipPlayer.Audio.Windows;
using ClipPlayer.Core;

namespace ClipPlayer.App;

public interface IPlaylistPlaybackPort
{
    bool HandlesSelectionAtomically => false;
    Task SetPlaylistAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken);
    Task SetPlaylistAsync(IReadOnlyList<string> paths, int selectedIndex, CancellationToken cancellationToken)
        => SetPlaylistAsync(paths, cancellationToken);
}

/// <summary>Composition root for the real Core + Windows audio pipeline.</summary>
public sealed class CorePlaybackPort : IPlaybackPort, IPlaylistPlaybackPort, IPlaybackStateSource
{
    private static readonly ClipPlayer.Audio.Windows.AudioFormat MixFormat = new(48_000, 2);
    private readonly PcmCache _cache = new();
    private readonly WasapiPlaybackOutput _wasapi;
    private readonly PlaybackCoordinator _coordinator;
    private readonly WindowsPcmCache _windowsCache;
    private readonly object _deviceGate = new();
    private Task _deviceChangeTask = Task.CompletedTask;
    private IReadOnlyList<Track> _tracks = [];
    private bool _disposed;

    public CorePlaybackPort()
    {
        var registry = new DecoderRegistry([new WavDecoder(), new MediaFoundationDecoder()]);
        _wasapi = new WasapiPlaybackOutput(MixFormat);
        _windowsCache = new WindowsPcmCache(_cache, MixFormat, registry);
        _coordinator = new PlaybackCoordinator(
            new WindowsTrackDecoder(registry, MixFormat),
            new CoreAudioOutputAdapter(_wasapi),
            _windowsCache);
        _wasapi.TrackEnded += OnTrackEnded;
        _wasapi.PlaybackFaulted += OnPlaybackFaulted;
        _wasapi.DeviceChanged += OnDeviceChanged;
        _coordinator.SnapshotChanged += OnSnapshotChanged;
    }

    public TimeSpan Position => _wasapi.Position;
    public bool HandlesSelectionAtomically => true;
    public TimeSpan Duration => _wasapi.Duration;
    public bool IsPlaying => _wasapi.IsPlaying;
    public bool CanSeek => _wasapi.CanSeek;
    public event EventHandler<PlaybackSnapshot>? PlaybackChanged;
    public double Volume { get => _wasapi.Volume; set => _wasapi.Volume = value; }

    public async Task SetPlaylistAsync(IReadOnlyList<string> paths, int selectedIndex, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        _tracks = paths.Select(Track.FromFile).ToArray();
        await _coordinator.ReplacePlaylistAsync(_tracks, selectedIndex, cancellationToken).ConfigureAwait(false);
    }

    public Task SetPlaylistAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken) =>
        SetPlaylistAsync(paths, 0, cancellationToken);

    public async Task PlayAsync(string path, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var normalized = Path.GetFullPath(path);
        var index = _tracks.ToList().FindIndex(t => string.Equals(t.Path, normalized, StringComparison.OrdinalIgnoreCase));
        if (index < 0)
        {
            await SetPlaylistAsync([normalized], 0, cancellationToken).ConfigureAwait(false);
            return;
        }
        await _coordinator.SelectAsync(index, cancellationToken).ConfigureAwait(false);
    }

    public async Task PauseAsync(CancellationToken cancellationToken) => await _coordinator.TogglePauseAsync(cancellationToken);
    public async Task ResumeAsync(CancellationToken cancellationToken) => await _coordinator.TogglePauseAsync(cancellationToken);
    public async Task StopAsync(CancellationToken cancellationToken) => await _coordinator.StopAsync(cancellationToken);
    public Task SeekAsync(TimeSpan position, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CanSeek) throw new NotSupportedException("Seek ist während des Streaming-Wiedergabepfads nicht verfügbar.");
        _wasapi.Seek(position);
        return Task.CompletedTask;
    }

    public Task PreloadAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        if (paths.Count == 0) return Task.CompletedTask;
        var following = paths.Select(Track.FromFile).ToArray();
        var current = _coordinator.Playlist.Current;
        var tracks = current is null ? following : new[] { current }.Concat(following).ToArray();
        return _windowsCache.PreloadAsync(tracks, 0, _coordinator.Snapshot.SelectionGeneration.Value,
            _ => true, cancellationToken).AsTask();
    }

    public async Task HandleDeviceChangeAsync(CancellationToken cancellationToken)
    {
        _windowsCache.Clear();
        await _coordinator.StopAsync(cancellationToken).ConfigureAwait(false);
        _wasapi.ReinitializeAfterDeviceChange();
        if (_coordinator.Playlist.CurrentIndex >= 0)
            await _coordinator.SelectAsync(_coordinator.Playlist.CurrentIndex, cancellationToken).ConfigureAwait(false);
    }

    private async void OnTrackEnded(object? sender, PlaybackEndedEventArgs e)
    {
        try
        {
            var track = e.Track;
            await _coordinator.NotifyTrackEndedAsync(track, e.Revision,
                e.SelectionGeneration == 0 ? null : new SelectionGeneration(e.SelectionGeneration)).ConfigureAwait(false);
        }
        catch (ObjectDisposedException) { }
        catch (Exception exception)
        {
            try { await _coordinator.NotifyPlaybackFaultAsync(exception).ConfigureAwait(false); }
            catch (ObjectDisposedException) { }
        }
    }

    private void OnDeviceChanged(object? sender, EventArgs e)
    {
        if (_disposed) return;
        lock (_deviceGate)
        {
            _deviceChangeTask = _deviceChangeTask.ContinueWith(_ => HandleDeviceChangeSafelyAsync(),
                CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default).Unwrap();
        }
    }

    private async Task HandleDeviceChangeSafelyAsync()
    {
        try { await HandleDeviceChangeAsync(CancellationToken.None).ConfigureAwait(false); }
        catch (ObjectDisposedException) { }
        catch (Exception exception) { await _coordinator.NotifyPlaybackFaultAsync(exception).ConfigureAwait(false); }
    }

    private void OnPlaybackFaulted(object? sender, PlaybackFaultEventArgs e) =>
        _ = ReportPlaybackFaultAsync(e.Error);

    private async Task ReportPlaybackFaultAsync(Exception exception)
    {
        try { await _coordinator.NotifyPlaybackFaultAsync(exception).ConfigureAwait(false); }
        catch (ObjectDisposedException) { }
    }

    private void OnSnapshotChanged(object? sender, PlaybackSnapshot snapshot)
    {
        if (snapshot.State == PlaybackState.Loading)
            _wasapi.SetPlaybackIdentity(_coordinator.PlaylistRevision, snapshot.SelectionGeneration.Value);
        PlaybackChanged?.Invoke(this, snapshot);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _wasapi.TrackEnded -= OnTrackEnded;
        _wasapi.PlaybackFaulted -= OnPlaybackFaulted;
        _wasapi.DeviceChanged -= OnDeviceChanged;
        _coordinator.SnapshotChanged -= OnSnapshotChanged;
        Task deviceTask;
        lock (_deviceGate) deviceTask = _deviceChangeTask;
        await deviceTask.ConfigureAwait(false);
        await _coordinator.DisposeAsync().ConfigureAwait(false);
        _wasapi.Dispose();
        _cache.Dispose();
    }
}
