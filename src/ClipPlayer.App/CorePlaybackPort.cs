using ClipPlayer.Audio.Windows;
using ClipPlayer.Core;
using System.IO;

namespace ClipPlayer.App;

public interface IPlaylistPlaybackPort
{
    Task SetPlaylistAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken);
}

/// <summary>Composition root for the real Core + Windows audio pipeline.</summary>
public sealed class CorePlaybackPort : IPlaybackPort, IPlaylistPlaybackPort
{
    private static readonly ClipPlayer.Audio.Windows.AudioFormat MixFormat = new(48_000, 2);
    private readonly PcmCache _cache = new();
    private readonly WasapiPlaybackOutput _wasapi;
    private readonly PlaybackCoordinator _coordinator;
    private IReadOnlyList<Track> _tracks = [];
    private bool _disposed;

    public CorePlaybackPort()
    {
        var registry = new DecoderRegistry([new WavDecoder(), new MediaFoundationDecoder()]);
        _wasapi = new WasapiPlaybackOutput(MixFormat);
        _coordinator = new PlaybackCoordinator(
            new WindowsTrackDecoder(registry, MixFormat),
            new CoreAudioOutputAdapter(_wasapi),
            new WindowsPcmCache(_cache, MixFormat));
        _wasapi.TrackEnded += OnTrackEnded;
    }

    public TimeSpan Position => _wasapi.Position;
    public TimeSpan Duration => _wasapi.Duration;
    public bool IsPlaying => _wasapi.IsPlaying;
    public double Volume { get => _wasapi.Volume; set => _wasapi.Volume = value; }

    public async Task SetPlaylistAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        _tracks = paths.Select(Track.FromFile).ToArray();
        await _coordinator.ReplacePlaylistAsync(_tracks, cancellationToken).ConfigureAwait(false);
    }

    public async Task PlayAsync(string path, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var normalized = Path.GetFullPath(path);
        var index = _tracks.ToList().FindIndex(t => string.Equals(t.Path, normalized, StringComparison.OrdinalIgnoreCase));
        if (index < 0)
        {
            await SetPlaylistAsync([normalized], cancellationToken).ConfigureAwait(false);
            index = 0;
        }
        await _coordinator.SelectAsync(index, cancellationToken).ConfigureAwait(false);
    }

    public async Task PauseAsync(CancellationToken cancellationToken) => await _coordinator.TogglePauseAsync(cancellationToken);
    public async Task ResumeAsync(CancellationToken cancellationToken) => await _coordinator.TogglePauseAsync(cancellationToken);
    public async Task StopAsync(CancellationToken cancellationToken) => await _coordinator.StopAsync(cancellationToken);
    public Task SeekAsync(TimeSpan position, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _wasapi.Seek(position);
        return Task.CompletedTask;
    }

    public Task PreloadAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    public async Task HandleDeviceChangeAsync(CancellationToken cancellationToken)
    {
        await _coordinator.StopAsync(cancellationToken).ConfigureAwait(false);
        _wasapi.ReinitializeAfterDeviceChange();
        if (_coordinator.Playlist.CurrentIndex >= 0)
            await _coordinator.SelectAsync(_coordinator.Playlist.CurrentIndex, cancellationToken).ConfigureAwait(false);
    }

    private async void OnTrackEnded(object? sender, EventArgs e)
    {
        try { await _coordinator.NotifyTrackEndedAsync().ConfigureAwait(false); }
        catch (ObjectDisposedException) { }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _wasapi.TrackEnded -= OnTrackEnded;
        await _coordinator.DisposeAsync().ConfigureAwait(false);
        _wasapi.Dispose();
        _cache.Dispose();
    }
}
