using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

/// <summary>Shared-mode, event-driven output. The device is initialized once per output lifetime.</summary>
public sealed class WasapiPlaybackOutput : IStreamingAudioOutput
{
    private readonly int _latencyMilliseconds;
    private readonly SwitchablePcmProvider _provider;
    private WasapiOut? _output;
    private float _volume = 1;
    private ClipPlayer.Core.IStreamingAudio? _activeStream;
    private bool _disposed;

    public WasapiPlaybackOutput(AudioFormat format, int latencyMilliseconds = 150)
    {
        if (!format.IsValid) throw new ArgumentOutOfRangeException(nameof(format));
        if (latencyMilliseconds is < 100 or > 200) throw new ArgumentOutOfRangeException(nameof(latencyMilliseconds));
        Format = format;
        _latencyMilliseconds = latencyMilliseconds;
        _provider = new SwitchablePcmProvider(format);
    }

    public AudioFormat Format { get; }
    public bool IsPlaying => _output?.PlaybackState == PlaybackState.Playing;
    public TimeSpan Position => _provider.Position;
    public TimeSpan Duration => _provider.Duration;
    public double Volume { get => _output?.Volume ?? _volume; set { _volume = (float)Math.Clamp(value, 0, 1); if (_output is not null) _output.Volume = _volume; } }
    public event EventHandler? TrackEnded;

    public void SwitchTo(PcmAudio? audio, TimeSpan startAt = default)
    {
        ThrowIfDisposed();
        DisposeActiveStream();
        _provider.SwitchTo(audio, startAt);
    }

    public async ValueTask PlayStreamingAsync(ClipPlayer.Core.Track track, ClipPlayer.Core.IStreamingAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(audio);
        cancellationToken.ThrowIfCancellationRequested();
        if (audio.SampleRate != Format.SampleRate || audio.Channels != Format.Channels)
            throw new ArgumentException("Streaming-Mixformat stimmt nicht mit der Ausgabe überein.", nameof(audio));
        await audio.PrimeAsync(cancellationToken).ConfigureAwait(false);
        var previous = Interlocked.Exchange(ref _activeStream, audio);
        if (previous is not null && !ReferenceEquals(previous, audio)) await previous.DisposeAsync().ConfigureAwait(false);
        _provider.SwitchToStreaming(audio, startAt);
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
        _output?.Stop();
        DisposeActiveStream();
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
        if (_provider.EndOfStream) TrackEnded?.Invoke(this, EventArgs.Empty);
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
        _provider.Dispose();
    }
}
