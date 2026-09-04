using ClipPlayer.Audio.Windows;
using ClipPlayer.Core;

namespace ClipPlayer.Audio.Windows.Tests;

public sealed class ProviderTests
{
    private static readonly float[] FirstSamples = { 1f, 2f };
    private static readonly float[] SecondSamples = { 9f };
    private static readonly float[] RolloverSamples = { 1f, 2f, 3f, 4f };
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

    [Fact]
    public void RingBufferRemainsValidBeyondThirtyTwoBitSampleCounters()
    {
        var ring = new PcmRingBuffer(new AudioFormat(8_000, 1), TimeSpan.FromSeconds(1));
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var start = (long)int.MaxValue + 100;
        typeof(PcmRingBuffer).GetField("_read", flags)!.SetValue(ring, start);
        typeof(PcmRingBuffer).GetField("_write", flags)!.SetValue(ring, start);

        Assert.Equal(4, ring.Write(RolloverSamples));
        var output = new float[4];
        Assert.Equal(4, ring.Read(output));
        Assert.Equal(RolloverSamples, output);
    }

    [Fact]
    public async Task ConcurrentSeekAndReadNeverExceedPcmBounds()
    {
        var format = new AudioFormat(8_000, 1);
        using var provider = new SwitchablePcmProvider(format);
        provider.SwitchTo(new PcmAudio(format, new float[1_024]));
        var buffer = new byte[128 * sizeof(float)];

        var reads = Task.Run(() =>
        {
            for (var i = 0; i < 20_000; i++)
            {
                if (provider.Read(buffer, 0, buffer.Length) == 0) provider.Seek(TimeSpan.Zero);
            }
        });
        var seeks = Task.Run(() =>
        {
            for (var i = 0; i < 20_000; i++)
                provider.Seek(i % 2 == 0 ? TimeSpan.Zero : TimeSpan.FromSeconds(1_000d / format.SampleRate));
        });

        await Task.WhenAll(reads, seeks);
    }

    [Fact]
    public void StreamingFailureIsNotReportedAsSilenceOrEndOfTrack()
    {
        var provider = new SwitchablePcmProvider(new AudioFormat(8_000, 1));
        provider.SwitchToStreaming(new FailedStream());
        Assert.False(provider.EndOfStream);
        Assert.Throws<InvalidDataException>(() => provider.Read(new byte[sizeof(float)], 0, sizeof(float)));
        provider.Dispose();
    }

    private sealed class FailedStream : IStreamingAudio
    {
        public int SampleRate => 8_000;
        public int Channels => 1;
        public TimeSpan Duration => TimeSpan.FromMinutes(1);
        public TimeSpan Position => TimeSpan.Zero;
        public bool IsCompleted => true;
        public Exception? Failure => new IOException("decoder read failed");
        public ValueTask PrimeAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
        public int Read(Span<float> destination) => 0;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
