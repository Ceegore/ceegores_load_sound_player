using System.Runtime.InteropServices;

namespace ClipPlayer.Audio.Windows;

/// <summary>Fully decoded interleaved IEEE-float PCM. The array is immutable by convention.</summary>
public sealed class PcmAudio
{
    private readonly float[] _samples;
    public PcmAudio(AudioFormat format, float[] samples)
    {
        if (!format.IsValid) throw new ArgumentOutOfRangeException(nameof(format));
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Length % format.Channels != 0) throw new ArgumentException("Sample count is not frame-aligned.", nameof(samples));
        Format = format;
        _samples = samples;
        Samples = _samples;
    }

    public PcmAudio(AudioFormat format, ReadOnlyMemory<float> samples)
    {
        if (!format.IsValid) throw new ArgumentOutOfRangeException(nameof(format));
        if (samples.Length % format.Channels != 0) throw new ArgumentException("Sample count is not frame-aligned.", nameof(samples));
        if (MemoryMarshal.TryGetArray(samples, out ArraySegment<float> segment) && segment.Offset == 0 && segment.Count == segment.Array!.Length)
            _samples = segment.Array;
        else
            _samples = samples.ToArray();
        Samples = _samples;
    }

    public AudioFormat Format { get; }
    public ReadOnlyMemory<float> Samples { get; }
    internal float[] RawSamples => _samples;
    public int FrameCount => Samples.Length / Format.Channels;
    public long ByteCount => (long)Samples.Length * sizeof(float);
    public TimeSpan Duration => TimeSpan.FromSeconds((double)FrameCount / Format.SampleRate);
}
