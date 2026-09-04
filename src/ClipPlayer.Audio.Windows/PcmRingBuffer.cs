using NAudio.Wave;
using System.Buffers;

namespace ClipPlayer.Audio.Windows;

/// <summary>Bounded single-producer/single-consumer float ring for clips too large to cache.</summary>
public sealed class PcmRingBuffer
{
    private readonly float[] _buffer;
    private int _read;
    private int _write;

    public PcmRingBuffer(AudioFormat format, TimeSpan capacity)
    {
        if (!format.IsValid || capacity <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(capacity));
        Format = format;
        var frames = Math.Max(1, (int)Math.Ceiling(capacity.TotalSeconds * format.SampleRate));
        _buffer = new float[checked(frames * format.Channels)];
    }

    public AudioFormat Format { get; }
    public int CapacitySamples => _buffer.Length;
    public int AvailableSamples => Math.Max(0, Volatile.Read(ref _write) - Volatile.Read(ref _read));

    public int Write(ReadOnlySpan<float> samples)
    {
        var write = Volatile.Read(ref _write);
        var read = Volatile.Read(ref _read);
        var count = Math.Min(samples.Length, _buffer.Length - Math.Max(0, write - read));
        CopyIn(samples[..count], write);
        Volatile.Write(ref _write, write + count);
        return count;
    }

    public int Read(Span<float> destination)
    {
        var read = Volatile.Read(ref _read);
        var write = Volatile.Read(ref _write);
        var count = Math.Min(destination.Length, Math.Max(0, write - read));
        CopyOut(destination[..count], read);
        Volatile.Write(ref _read, read + count);
        return count;
    }

    private void CopyIn(ReadOnlySpan<float> source, int position)
    {
        var start = position % _buffer.Length;
        var first = Math.Min(source.Length, _buffer.Length - start);
        source[..first].CopyTo(_buffer.AsSpan(start, first));
        source[first..].CopyTo(_buffer.AsSpan(0, source.Length - first));
    }

    private void CopyOut(Span<float> destination, int position)
    {
        var start = position % _buffer.Length;
        var first = Math.Min(destination.Length, _buffer.Length - start);
        _buffer.AsSpan(start, first).CopyTo(destination[..first]);
        _buffer.AsSpan(0, destination.Length - first).CopyTo(destination[first..]);
    }
}

public sealed class StreamingPcmProvider : IWaveProvider
{
    private readonly PcmRingBuffer _ring;
    private bool _disposed;

    public StreamingPcmProvider(PcmRingBuffer ring)
    {
        _ring = ring ?? throw new ArgumentNullException(nameof(ring));
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(ring.Format.SampleRate, ring.Format.Channels);
    }

    public WaveFormat WaveFormat { get; }

    public int Read(byte[] buffer, int offset, int count)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(buffer);
        if ((uint)offset > (uint)buffer.Length || count < 0 || buffer.Length - offset < count)
            throw new ArgumentOutOfRangeException(nameof(count));
        if (count <= 0) return 0;
        var samples = ArrayPool<float>.Shared.Rent(count / sizeof(float));
        try
        {
            var read = _ring.Read(samples.AsSpan(0, count / sizeof(float)));
            Buffer.BlockCopy(samples, 0, buffer, offset, read * sizeof(float));
            return read * sizeof(float);
        }
        finally { ArrayPool<float>.Shared.Return(samples); }
    }

    public void Dispose() => _disposed = true;
}
