using System.Diagnostics;
using ClipPlayer.Audio.Windows;
using ClipPlayer.Core;
using CoreOutput = ClipPlayer.Core.IAudioOutput;
using PcmFormat = ClipPlayer.Audio.Windows.AudioFormat;

namespace ClipPlayer.Performance.Tests;

public sealed class RapidSwitchPerformanceTests
{
    [Fact]
    [Trait("Category", "Performance")]
    public async Task OneThousandSelectionsUseCacheAndRemainResponsive()
    {
        var switchCount = int.TryParse(Environment.GetEnvironmentVariable("CLIPPLAYER_PERF_SWITCHES"), out var configured)
            ? Math.Clamp(configured, 1, 10_000) : 1_000;
        var tracks = Enumerable.Range(0, 32).Select(i => Track.Create($"C:\\perf\\clip-{i:D3}.wav", 100 + i)).ToArray();
        var decoder = new CountingDecoder();
        var cache = new DictionaryCache();
        var output = new RecordingOutput();
        await using var coordinator = new PlaybackCoordinator(decoder, output, cache);
        await coordinator.ReplacePlaylistAsync(tracks);

        var samples = new long[switchCount];
        var random = new Random(0xC11F);
        for (var i = 0; i < switchCount; i++)
        {
            var index = random.Next(tracks.Length);
            var timer = Stopwatch.StartNew();
            await coordinator.SelectAsync(index);
            samples[i] = timer.ElapsedTicks;
        }

        Array.Sort(samples);
        var p95 = TimeSpan.FromSeconds((double)samples[(int)(switchCount * .95) - 1] / Stopwatch.Frequency);
        Assert.Equal(switchCount + 1, output.Started.Count);
        Assert.True(cache.Hits + cache.Misses >= switchCount);
        Assert.InRange(decoder.DecodeCount, 1, cache.Misses);
        Assert.True(cache.Hits > switchCount / 2);
        Assert.InRange(p95, TimeSpan.Zero, TimeSpan.FromMilliseconds(100));
    }

    [Fact]
    [Trait("Category", "Performance")]
    public async Task PcmCacheKeepsPreloadWindowBoundedAcrossOneThousandRequests()
    {
        const int requestCount = 1_000;
        var format = new PcmFormat(48_000, 1);
        var tracks = Enumerable.Range(0, 64)
            .Select(i => new AudioTrack($"C:\\perf\\cache-{i:D3}.wav", i + 1, DateTime.UnixEpoch.AddSeconds(i)))
            .ToArray();
        using var cache = new PcmCache(new PcmCacheOptions { MemoryBudgetBytes = 8 * 1024, MaxClipBytes = 4 * 1024 });
        var decoder = new PcmDecoder();
        var timer = Stopwatch.StartNew();
        for (var i = 0; i < requestCount; i++)
            await cache.PreloadAsync(tracks, i % (tracks.Length - 3), format, i, _ => true, decoder);

        Assert.InRange(cache.Count, 1, 8);
        Assert.InRange(cache.CurrentBytes, 0, 8 * 1024);
        Assert.InRange(decoder.DecodeCount, 1, requestCount + tracks.Length);
        Assert.InRange(timer.Elapsed, TimeSpan.Zero, TimeSpan.FromSeconds(10));
    }

    private sealed class CountingDecoder : ITrackDecoder
    {
        public int DecodeCount { get; private set; }
        public ValueTask<DecodedAudio> DecodeAsync(Track track, CancellationToken cancellationToken)
        {
            DecodeCount++;
            return new ValueTask<DecodedAudio>(new DecodedAudio(new float[] { 0, .25f, -.25f }, 48_000, 1));
        }
    }

    private sealed class DictionaryCache : ITrackCache
    {
        private readonly Dictionary<string, DecodedAudio> _items = new(StringComparer.OrdinalIgnoreCase);
        public int Hits { get; private set; }
        public int Misses { get; private set; }
        public ValueTask<DecodedAudio?> TryGetAsync(Track track, CancellationToken cancellationToken)
        {
            if (_items.TryGetValue(track.Path, out var audio)) { Hits++; return new(audio); }
            Misses++;
            return new((DecodedAudio?)null);
        }
        public ValueTask PutAsync(Track track, DecodedAudio audio, CancellationToken cancellationToken)
        {
            _items[track.Path] = audio;
            return ValueTask.CompletedTask;
        }
        public ValueTask InvalidateAsync(Track track, CancellationToken cancellationToken)
        {
            _items.Remove(track.Path);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class RecordingOutput : CoreOutput
    {
        public List<Track> Started { get; } = [];
        public ValueTask PlayAsync(Track track, DecodedAudio audio, TimeSpan startAt, CancellationToken cancellationToken)
        {
            Started.Add(track);
            return ValueTask.CompletedTask;
        }
        public ValueTask PauseAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
        public ValueTask ResumeAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
        public ValueTask StopAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
    }

    private sealed class PcmDecoder : IAudioDecoder
    {
        public int DecodeCount { get; private set; }
        public bool CanDecode(string extension) => true;
        public ValueTask<PcmAudio> DecodeAsync(AudioDecodeRequest request, CancellationToken cancellationToken = default)
        {
            DecodeCount++;
            return new ValueTask<PcmAudio>(new PcmAudio(request.TargetFormat ?? new PcmFormat(48_000, 1), new float[256]));
        }
    }
}
