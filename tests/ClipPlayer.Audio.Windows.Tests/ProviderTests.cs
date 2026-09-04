using ClipPlayer.Audio.Windows;

namespace ClipPlayer.Audio.Windows.Tests;

public sealed class ProviderTests
{
    private static readonly float[] FirstSamples = { 1f, 2f };
    private static readonly float[] SecondSamples = { 9f };
    [Fact]
    public void SwitchResetsPositionAndDoesNotReadPreviousClip()
    {
        var format = new AudioFormat(8_000, 1);
        using var provider = new SwitchablePcmProvider(format);
        provider.SwitchTo(new PcmAudio(format, FirstSamples));
        var first = new byte[sizeof(float)];
        Assert.Equal(first.Length, provider.Read(first, 0, first.Length));
        Assert.Equal(1f, BitConverter.ToSingle(first));
        provider.SwitchTo(new PcmAudio(format, SecondSamples));
        Assert.Equal(TimeSpan.Zero, provider.Position);
        var second = new byte[sizeof(float)];
        provider.Read(second, 0, second.Length);
        Assert.Equal(9f, BitConverter.ToSingle(second));
    }

    [Fact]
    public void ProviderRejectsDifferentMixFormat()
    {
        var provider = new SwitchablePcmProvider(new AudioFormat(8_000, 1));
        Assert.Throws<ArgumentException>(() => provider.SwitchTo(new PcmAudio(new AudioFormat(16_000, 1), new float[1])));
        provider.Dispose();
    }

    [Fact]
    public void RingBufferIsBoundedAndWraps()
    {
        var ring = new PcmRingBuffer(new AudioFormat(8_000, 1), TimeSpan.FromSeconds(1));
        var input = Enumerable.Range(0, ring.CapacitySamples + 4).Select(i => (float)i).ToArray();
        Assert.Equal(ring.CapacitySamples, ring.Write(input));
        var output = new float[ring.CapacitySamples];
        Assert.Equal(output.Length, ring.Read(output));
        Assert.Equal(input[0], output[0]);
        Assert.Equal(0, ring.AvailableSamples);
        Assert.Equal(4, ring.Write(new[] { 3f, 4f, 5f, 6f }));
        Assert.Equal(4, ring.Read(output.AsSpan(0, 4)));
        Assert.Equal(3f, output[0]);
    }
}
