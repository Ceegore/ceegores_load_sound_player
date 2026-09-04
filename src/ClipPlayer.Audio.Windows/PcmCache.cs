namespace ClipPlayer.Audio.Windows;

public readonly record struct CacheKey(string Path, long Length, long LastWriteTicks, AudioFormat Format)
{
    public static CacheKey For(AudioTrack track, AudioFormat format) =>
        new(track.FullPath, track.Length, track.LastWriteTimeUtc.Ticks, format);
}

public sealed record PcmCacheOptions
{
    public long MemoryBudgetBytes { get; init; } = 256L * 1024 * 1024;
    public long MaxClipBytes { get; init; } = 128L * 1024 * 1024;
}

public sealed class PcmCache : IDisposable
{
    private sealed class Entry(CacheKey key, PcmAudio audio)
    {
        public CacheKey Key { get; } = key;
        public PcmAudio Audio { get; } = audio;
    }

    private readonly object _gate = new();
    private readonly Dictionary<CacheKey, LinkedListNode<Entry>> _entries = new();
    private readonly LinkedList<Entry> _lru = new();
    private readonly HashSet<CacheKey> _protected = new();
    private CacheKey? _anchor;
    private readonly SemaphoreSlim _decoderWorker = new(1, 1);
    private readonly PcmCacheOptions _options;
    private long _bytes;
    private bool _disposed;

    public PcmCache(PcmCacheOptions? options = null)
    {
        _options = options ?? new PcmCacheOptions();
        if (_options.MemoryBudgetBytes <= 0 || _options.MaxClipBytes <= 0 || _options.MaxClipBytes > _options.MemoryBudgetBytes)
            throw new ArgumentOutOfRangeException(nameof(options), "Cachegrenzen müssen positiv und konsistent sein.");
    }

    public long CurrentBytes { get { lock (_gate) return _bytes; } }
    public int Count { get { lock (_gate) return _entries.Count; } }

    public bool TryGet(CacheKey key, out PcmAudio? audio)
    {
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out var node)) { audio = null; return false; }
            _lru.Remove(node);
            _lru.AddFirst(node);
            audio = node.Value.Audio;
            return true;
        }
    }

    public void Protect(IEnumerable<CacheKey> keys)
    {
        ArgumentNullException.ThrowIfNull(keys);
        lock (_gate)
        {
            _protected.Clear();
            foreach (var key in keys) _protected.Add(key);
            _anchor = keys.FirstOrDefault();
            EvictIfNeeded();
        }
    }

    public bool Put(CacheKey key, PcmAudio audio)
    {
        ArgumentNullException.ThrowIfNull(audio);
        if (audio.ByteCount > _options.MaxClipBytes) return false;
        lock (_gate)
        {
            ThrowIfDisposed();
            RemoveCore(key);
            var node = _lru.AddFirst(new Entry(key, audio));
            _entries[key] = node;
            _bytes += audio.ByteCount;
            EvictIfNeeded();
            return _entries.ContainsKey(key);
        }
    }

    public void Invalidate(CacheKey key)
    {
        lock (_gate) RemoveCore(key);
    }

    public void Clear()
    {
        lock (_gate) { _entries.Clear(); _lru.Clear(); _protected.Clear(); _bytes = 0; }
    }

    /// <summary>Serializes decoder work and loads current plus up to three successors.</summary>
    public async ValueTask PreloadAsync(IReadOnlyList<AudioTrack> tracks, int currentIndex,
        AudioFormat format, long generation, Func<long, bool>? isCurrent = null,
        IAudioDecoder? decoder = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(tracks);
        if (currentIndex < 0 || currentIndex >= tracks.Count) return;
        ArgumentNullException.ThrowIfNull(decoder);
        await _decoderWorker.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var keys = Enumerable.Range(currentIndex, Math.Min(4, tracks.Count - currentIndex))
                .Select(i => CacheKey.For(tracks[i], format)).ToArray();
            Protect(keys);
            foreach (var index in Enumerable.Range(currentIndex, keys.Length))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (isCurrent is not null && !isCurrent(generation)) return;
                var key = keys[index - currentIndex];
                if (TryGet(key, out _)) continue;
                try
                {
                    var audio = await decoder.DecodeAsync(new AudioDecodeRequest(tracks[index], format), cancellationToken)
                        .ConfigureAwait(false);
                    if (audio.Format == format && (isCurrent is null || isCurrent(generation))) Put(key, audio);
                }
                catch (PcmClipTooLargeException)
                {
                    // A large successor is intentionally serviced by the streaming decoder
                    // when selected; continue warming the remaining bounded window.
                }
            }
        }
        finally { _decoderWorker.Release(); }
    }

    private void EvictIfNeeded()
    {
        while (_bytes > _options.MemoryBudgetBytes)
        {
            var node = _lru.Last;
            while (node is not null && _protected.Contains(node.Value.Key)) node = node.Previous;
            if (node is null)
            {
                node = _lru.Last;
                while (node is not null && node.Value.Key.Equals(_anchor)) node = node.Previous;
            }
            if (node is null) break;
            RemoveCore(node.Value.Key);
        }
    }

    private void RemoveCore(CacheKey key)
    {
        if (!_entries.Remove(key, out var node)) return;
        _lru.Remove(node);
        _bytes -= node.Value.Audio.ByteCount;
    }

    private void ThrowIfDisposed() { ObjectDisposedException.ThrowIf(_disposed, this); }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Clear();
        _decoderWorker.Dispose();
    }
}
