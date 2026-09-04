using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

/// <summary>Atomic PCM source swap. Read never touches disk or a decoder.</summary>
public sealed class SwitchablePcmProvider : IWaveProvider, IDisposable
{
    private sealed class Slot(PcmAudio audio)
    {
        public PcmAudio Audio { get; } = audio;
        public int Position;
    }

    private readonly AudioFormat _format;
    private Slot? _slot;
    private bool _disposed;

    public SwitchablePcmProvider(AudioFormat format)
    {
        if (!format.IsValid) throw new ArgumentOutOfRangeException(nameof(format));
        _format = format;
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(format.SampleRate, format.Channels);
    }

    public WaveFormat WaveFormat { get; }
    public AudioFormat Format => _format;
    public bool HasAudio => Volatile.Read(ref _slot) is not null;
    public TimeSpan Position => Volatile.Read(ref _slot) is { } slot
        ? TimeSpan.FromSeconds((double)Volatile.Read(ref slot.Position) / _format.Channels / _format.SampleRate)
        : TimeSpan.Zero;

    public void SwitchTo(PcmAudio? audio, TimeSpan startAt = default)
    {
        ThrowIfDisposed();
        if (audio is not null && audio.Format != _format) throw new ArgumentException("PCM-Mixformat stimmt nicht überein.", nameof(audio));
        var slot = audio is null ? null : new Slot(audio);
        if (slot is not null)
        {
            var frame = Math.Clamp((long)(startAt.TotalSeconds * _format.SampleRate), 0, audio!.FrameCount);
            slot.Position = checked((int)(frame * _format.Channels));
        }
        Interlocked.Exchange(ref _slot, slot);
    }

    public int Read(byte[] buffer, int offset, int count)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(buffer);
        if ((uint)offset > (uint)buffer.Length || count < 0 || buffer.Length - offset < count)
            throw new ArgumentOutOfRangeException(nameof(count));
        var slot = Volatile.Read(ref _slot);
        if (slot is null || count == 0) return 0;
        var sampleCount = Math.Min(count / sizeof(float), slot.Audio.Samples.Length - Volatile.Read(ref slot.Position));
        if (sampleCount <= 0) return 0;
        var start = Interlocked.Add(ref slot.Position, sampleCount) - sampleCount;
        Buffer.BlockCopy(slot.Audio.RawSamples, start * sizeof(float), buffer, offset, sampleCount * sizeof(float));
        return sampleCount * sizeof(float);
    }

    private void ThrowIfDisposed() { ObjectDisposedException.ThrowIf(_disposed, this); }
    public void Dispose() { _disposed = true; Interlocked.Exchange(ref _slot, null); }
}
