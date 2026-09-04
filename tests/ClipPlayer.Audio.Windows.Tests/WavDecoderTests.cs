using ClipPlayer.Audio.Windows;
using NAudio.Wave;

namespace ClipPlayer.Audio.Windows.Tests;

public sealed class WavDecoderTests
{
    [Fact]
    public async Task DecodesPcmAndReleasesSourceHandle()
    {
        var path = Path.Combine(Path.GetTempPath(), $"clipplayer-{Guid.NewGuid():N}.wav");
        try
        {
            var format = new WaveFormat(8_000, 16, 1);
            using (var writer = new WaveFileWriter(path, format))
            {
                var bytes = new byte[format.AverageBytesPerSecond / 10];
                writer.Write(bytes, 0, bytes.Length);
            }

            var track = AudioTrack.FromPath(path);
            var target = new AudioFormat(16_000, 2);
            var decoded = await new WavDecoder().DecodeAsync(new AudioDecodeRequest(track, target));
            Assert.Equal(target, decoded.Format);
            Assert.Equal(1_600, decoded.FrameCount);
            Assert.NotEmpty(decoded.Samples.ToArray());

            File.Delete(path);
            Assert.False(File.Exists(path));
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public async Task CancellationIsHonoredBeforeOpeningFile()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var request = new AudioDecodeRequest(new AudioTrack("missing.wav", 0, DateTime.UtcNow));
        await Assert.ThrowsAsync<OperationCanceledException>(async () => await new WavDecoder().DecodeAsync(request, cancellation.Token));
    }

    [Fact]
    public async Task OversizedWaveUsesFiveSecondStreamingSource()
    {
        var path = Path.Combine(Path.GetTempPath(), $"clipplayer-large-{Guid.NewGuid():N}.wav");
        try
        {
            WriteSparsePcmWave(path, 129 * 1024 * 1024);
            var registry = new DecoderRegistry([new WavDecoder()]);
            var decoder = new WindowsTrackDecoder(registry, new AudioFormat(8_000, 1));
            var decoded = await decoder.DecodeAsync(ClipPlayer.Core.Track.Create(path, new FileInfo(path).Length, File.GetLastWriteTimeUtc(path)), CancellationToken.None);

            Assert.True(decoded.IsStreaming);
            await decoded.Stream!.PrimeAsync(CancellationToken.None);
            var samples = new float[128];
            Assert.Equal(samples.Length, decoded.Stream.Read(samples));
            await decoded.Stream.DisposeAsync();
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public async Task TargetMixFormatOversizeUsesStreamingBeforeResample()
    {
        var path = Path.Combine(Path.GetTempPath(), $"clipplayer-target-large-{Guid.NewGuid():N}.wav");
        try
        {
            WriteSparsePcmWave(path, 129 * 1024 * 1024, 44_100, 1);
            var target = new AudioFormat(48_000, 2);
            var decoder = new WindowsTrackDecoder(new DecoderRegistry([new WavDecoder()]), target);
            var track = ClipPlayer.Core.Track.Create(path, new FileInfo(path).Length, File.GetLastWriteTimeUtc(path));
            var decoded = await decoder.DecodeAsync(track, CancellationToken.None);
            Assert.True(decoded.IsStreaming);
            await decoded.Stream!.DisposeAsync();
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public async Task ModerateSourceCanSelectStreamingAfterTargetMixExpansion()
    {
        var path = Path.Combine(Path.GetTempPath(), $"clipplayer-target-moderate-{Guid.NewGuid():N}.wav");
        try
        {
            const int sourceBytes = 50 * 1024 * 1024;
            WriteSparsePcmWave(path, sourceBytes, 44_100, 1);
            var target = new AudioFormat(48_000, 2);
            var decoder = new WindowsTrackDecoder(new DecoderRegistry([new WavDecoder()]), target);
            var track = ClipPlayer.Core.Track.Create(path, new FileInfo(path).Length, File.GetLastWriteTimeUtc(path));

            var durationSeconds = sourceBytes / (double)(44_100 * 2);
            Assert.InRange(durationSeconds * 44_100 * 1 * sizeof(float), 0, 128d * 1024 * 1024);
            Assert.True(durationSeconds * target.SampleRate * target.Channels * sizeof(float) > 128d * 1024 * 1024);

            var decoded = await decoder.DecodeAsync(track, CancellationToken.None);

            Assert.True(decoded.IsStreaming);
            await decoded.Stream!.DisposeAsync();
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private static void WriteSparsePcmWave(string path, int dataBytes, int sampleRate = 8_000, short channels = 1)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        using var writer = new BinaryWriter(stream);
        writer.Write(0x46464952); // RIFF
        writer.Write(36 + dataBytes);
        writer.Write(0x45564157); // WAVE
        writer.Write(0x20746D66); // fmt 
        writer.Write(16);
        writer.Write((short)1);
        writer.Write(channels);
        writer.Write(sampleRate);
        writer.Write(sampleRate * channels * 2);
        writer.Write((short)(channels * 2));
        writer.Write((short)16);
        writer.Write(0x61746164); // data
        writer.Write(dataBytes);
        stream.SetLength(44L + dataBytes);
    }
}
