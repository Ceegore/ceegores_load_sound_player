using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

/// <summary>Shared-mode, event-driven output. The device is initialized once per output lifetime.</summary>
public sealed class WasapiPlaybackOutput : IStreamingAudioOutput
{
    private readonly int _latencyMilliseconds;
    private readonly SwitchablePcmProvider _provider;
    private readonly MMDeviceEnumerator _deviceEnumerator;
    private readonly IMMNotificationClient _notificationClient;
    private WasapiOut? _output;
    private float _volume = 1;
    private ClipPlayer.Core.IStreamingAudio? _activeStream;
    private int _ignoreStopped;
    private int _trackEndedRaised;
    private bool _disposed;
    private long _pendingRevision;
    private long _pendingSelectionGeneration;

    public WasapiPlaybackOutput(AudioFormat format, int latencyMilliseconds = 150)
    {
        if (!format.IsValid) throw new ArgumentOutOfRangeException(nameof(format));
        if (latencyMilliseconds is < 100 or > 200) throw new ArgumentOutOfRangeException(nameof(latencyMilliseconds));
        Format = format;
        _latencyMilliseconds = latencyMilliseconds;
        _provider = new SwitchablePcmProvider(format);
        _deviceEnumerator = new MMDeviceEnumerator();
        _notificationClient = new DefaultDeviceNotification(this);
        _deviceEnumerator.RegisterEndpointNotificationCallback(_notificationClient);
    }

    public AudioFormat Format { get; }
    public bool IsPlaying => _output?.PlaybackState == PlaybackState.Playing;
    public bool CanSeek => _provider.CanSeek;
    public TimeSpan Position => _provider.Position;
    public TimeSpan Duration => _provider.Duration;
    public double Volume { get => _output?.Volume ?? _volume; set { _volume = (float)Math.Clamp(value, 0, 1); if (_output is not null) _output.Volume = _volume; } }
    public event EventHandler<PlaybackEndedEventArgs>? TrackEnded;
    public event EventHandler<PlaybackFaultEventArgs>? PlaybackFaulted;
    public event EventHandler? DeviceChanged;

    public void SetPlaybackIdentity(long revision, long selectionGeneration)
    {
        Volatile.Write(ref _pendingRevision, revision);
        Volatile.Write(ref _pendingSelectionGeneration, selectionGeneration);
    }

    public void SwitchTo(PcmAudio? audio, TimeSpan startAt = default)
        => SwitchTo(null, audio, startAt);

    public void SwitchTo(ClipPlayer.Core.Track? track, PcmAudio? audio, TimeSpan startAt = default)
    {
        ThrowIfDisposed();
        DisposeActiveStream();
        Volatile.Write(ref _ignoreStopped, 0);
        Volatile.Write(ref _trackEndedRaised, 0);
        _provider.SwitchTo(track, audio, startAt, Volatile.Read(ref _pendingRevision),
            Volatile.Read(ref _pendingSelectionGeneration));
    }

    public async ValueTask PlayStreamingAsync(ClipPlayer.Core.Track track, ClipPlayer.Core.IStreamingAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(audio);
        cancellationToken.ThrowIfCancellationRequested();
        if (audio.SampleRate != Format.SampleRate || audio.Channels != Format.Channels)
            throw new ArgumentException("Streaming-Mixformat stimmt nicht mit der Ausgabe überein.", nameof(audio));
        StopPlayback();
        await audio.PrimeAsync(cancellationToken).ConfigureAwait(false);
        var previous = Interlocked.Exchange(ref _activeStream, audio);
        if (previous is not null && !ReferenceEquals(previous, audio)) await previous.DisposeAsync().ConfigureAwait(false);
        _provider.SwitchToStreaming(track, audio, startAt, Volatile.Read(ref _pendingRevision),
            Volatile.Read(ref _pendingSelectionGeneration));
        Volatile.Write(ref _ignoreStopped, 0);
        Volatile.Write(ref _trackEndedRaised, 0);
        Play();
    }

    public void Play()
    {
        ThrowIfDisposed();
        EnsureInitialized();
        _output!.Play();
    }

    public void Pause()
    {
        ThrowIfDisposed();
        _output?.Pause();
    }

    public void StopPlayback()
    {
        ThrowIfDisposed();
        Interlocked.Exchange(ref _ignoreStopped, 1);
        try { _output?.Stop(); }
        finally { DisposeActiveStream(); }
    }

    public void Seek(TimeSpan position)
    {
        ThrowIfDisposed();
        _provider.Seek(position);
    }

    /// <summary>Recreates the shared output after a default-device or device-loss notification.</summary>
    public void ReinitializeAfterDeviceChange()
    {
        ThrowIfDisposed();
        if (_output is not null) _output.PlaybackStopped -= OnPlaybackStopped;
        _output?.Dispose();
        _output = null;
        EnsureInitialized();
    }

    private void EnsureInitialized()
    {
        if (_output is not null) return;
        _output = new WasapiOut(AudioClientShareMode.Shared, useEventSync: true, latency: _latencyMilliseconds);
        _output.Init(_provider);
        _output.Volume = _volume;
        _output.PlaybackStopped += OnPlaybackStopped;
    }

    private void OnPlaybackStopped(object? sender, StoppedEventArgs e)
    {
        var failure = e.Exception ?? _provider.Failure;
        if (failure is not null)
        {
            PlaybackFaulted?.Invoke(this, new PlaybackFaultEventArgs(failure));
            return;
        }
        if (Volatile.Read(ref _ignoreStopped) == 0 && _provider.EndOfStream &&
            Interlocked.Exchange(ref _trackEndedRaised, 1) == 0)
            TrackEnded?.Invoke(this, new PlaybackEndedEventArgs(_provider.CurrentTrack,
                _provider.CurrentRevision, _provider.CurrentSelectionGeneration));
    }

    private sealed class DefaultDeviceNotification(WasapiPlaybackOutput owner) : IMMNotificationClient
    {
        public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            if (flow == DataFlow.Render) owner.DeviceChanged?.Invoke(owner, EventArgs.Empty);
        }
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }

    private void ThrowIfDisposed() { ObjectDisposedException.ThrowIf(_disposed, this); }

    private void DisposeActiveStream()
    {
        var stream = Interlocked.Exchange(ref _activeStream, null);
        if (stream is null) return;
        try { stream.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        DisposeActiveStream();
        if (_output is not null) _output.PlaybackStopped -= OnPlaybackStopped;
        _output?.Dispose();
        _deviceEnumerator.UnregisterEndpointNotificationCallback(_notificationClient);
        _deviceEnumerator.Dispose();
        _provider.Dispose();
    }
}

public sealed class PlaybackEndedEventArgs(ClipPlayer.Core.Track? track, long revision,
    long selectionGeneration) : EventArgs
{
    public ClipPlayer.Core.Track? Track { get; } = track;
    public long Revision { get; } = revision;
    public long SelectionGeneration { get; } = selectionGeneration;
}

public sealed class PlaybackFaultEventArgs(Exception error) : EventArgs
{
    public Exception Error { get; } = error;
}
