using ClipPlayer.Audio.Windows;

namespace ClipPlayer.Audio.Windows.Tests;

public sealed class PcmCacheTests
{
    [Fact]
    public void LruEvictsOldestUnprotectedEntryAndKeepsBudget()
    {
        using var cache = new PcmCache(new PcmCacheOptions { MemoryBudgetBytes = 16, MaxClipBytes = 16 });
        var format = new AudioFormat(8_000, 1);
        var tracks = Enumerable.Range(0, 3).Select(_ => NewTrack()).ToArray();
        var keys = tracks.Select(t => CacheKey.For(t, format)).ToArray();
        cache.Put(keys[0], Audio(format, 2));
        cache.Put(keys[1], Audio(format, 2));
        cache.TryGet(keys[0], out _);
        cache.Put(keys[2], Audio(format, 2));

        Assert.True(cache.TryGet(keys[0], out _));
        Assert.False(cache.TryGet(keys[1], out _));
        Assert.True(cache.TryGet(keys[2], out _));
        Assert.InRange(cache.CurrentBytes, 0, 16);
    }

    [Fact]
    public async Task PreloadLoadsCurrentAndThreeSuccessorsOnce()
    {
        using var cache = new PcmCache();
        var tracks = Enumerable.Range(0, 6).Select(_ => NewTrack()).ToArray();
        var decoder = new FakeDecoder();
        await cache.PreloadAsync(tracks, 1, new AudioFormat(8_000, 1), 4, g => g == 4, decoder);

        Assert.Equal(4, decoder.Paths.Count);
        Assert.Equal(4, cache.Count);
        await cache.PreloadAsync(tracks, 1, new AudioFormat(8_000, 1), 4, g => g == 4, decoder);
        Assert.Equal(4, decoder.Paths.Count);
    }

    [Fact]
    public async Task StaleGenerationDoesNotCommitDecodedAudio()
    {
        using var cache = new PcmCache();
        var track = NewTrack();
        var decoder = new FakeDecoder { Delay = TimeSpan.FromMilliseconds(10) };
        await cache.PreloadAsync(new[] { track }, 0, new AudioFormat(8_000, 1), 2, _ => false, decoder);
        Assert.Equal(0, cache.Count);
    }

    private static PcmAudio Audio(AudioFormat format, int samples) => new(format, new float[samples]);
    private static AudioTrack NewTrack() => new(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".wav"), 12, DateTime.UtcNow);

    private sealed class FakeDecoder : IAudioDecoder
    {
        public List<string> Paths { get; } = new();
        public TimeSpan Delay { get; init; }
        public bool CanDecode(string extension) => true;
        public async ValueTask<PcmAudio> DecodeAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default)
        {
            Paths.Add(request.Track.FullPath);
            if (Delay > TimeSpan.Zero) await Task.Delay(Delay, cancellationToken);
            return Audio(request.TargetFormat ?? new AudioFormat(8_000, 1), 2);
        }
    }
}
