using NAudio.Wave;
using ClipPlayer.Audio.Windows;

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
}
