using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

/// <summary>Shared-mode, event-driven output. The device is initialized once per output lifetime.</summary>
public sealed class WasapiPlaybackOutput : IAudioOutput
{
    private readonly int _latencyMilliseconds;
    private readonly SwitchablePcmProvider _provider;
    private WasapiOut? _output;
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

    public void SwitchTo(PcmAudio? audio, TimeSpan startAt = default)
    {
        ThrowIfDisposed();
        _provider.SwitchTo(audio, startAt);
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
    }

    /// <summary>Recreates the shared output after a default-device or device-loss notification.</summary>
    public void ReinitializeAfterDeviceChange()
    {
        ThrowIfDisposed();
        _output?.Dispose();
        _output = null;
        EnsureInitialized();
    }

    private void EnsureInitialized()
    {
        if (_output is not null) return;
        _output = new WasapiOut(AudioClientShareMode.Shared, useEventSync: true, latency: _latencyMilliseconds);
        _output.Init(_provider);
    }

    private void ThrowIfDisposed() { ObjectDisposedException.ThrowIf(_disposed, this); }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _output?.Dispose();
        _provider.Dispose();
    }
}
