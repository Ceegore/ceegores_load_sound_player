using NAudio.Wave;
using ClipPlayer.Core;

namespace ClipPlayer.Audio.Windows;

/// <summary>Atomic PCM source swap. Read never touches disk or a decoder.</summary>
public sealed class SwitchablePcmProvider : IWaveProvider, IDisposable
{
    private sealed class Slot
    {
        public PcmAudio? Audio { get; }
        public IStreamingAudio? Stream { get; }
        public int Position;
        public ClipPlayer.Core.Track? Track { get; }
        public long Revision { get; }
        public long SelectionGeneration { get; }
        public Slot(PcmAudio audio, ClipPlayer.Core.Track? track, long revision, long selectionGeneration)
        { Audio = audio; Track = track; Revision = revision; SelectionGeneration = selectionGeneration; }
        public Slot(IStreamingAudio stream, ClipPlayer.Core.Track? track, long revision, long selectionGeneration)
        { Stream = stream; Track = track; Revision = revision; SelectionGeneration = selectionGeneration; }
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
    public bool CanSeek => Volatile.Read(ref _slot)?.Audio is not null;
    public ClipPlayer.Core.Track? CurrentTrack => Volatile.Read(ref _slot)?.Track;
    public long CurrentRevision => Volatile.Read(ref _slot)?.Revision ?? 0;
    public long CurrentSelectionGeneration => Volatile.Read(ref _slot)?.SelectionGeneration ?? 0;
    public Exception? Failure => Volatile.Read(ref _slot)?.Stream?.Failure;
    public TimeSpan Position => Volatile.Read(ref _slot) is { } slot && slot.Stream is { } stream
        ? stream.Position
        : Volatile.Read(ref _slot) is { } pcm
            ? TimeSpan.FromSeconds((double)Volatile.Read(ref pcm.Position) / _format.Channels / _format.SampleRate)
            : TimeSpan.Zero;
    public TimeSpan Duration => Volatile.Read(ref _slot) is { } slot && slot.Stream is { } stream ? stream.Duration : Volatile.Read(ref _slot)?.Audio?.Duration ?? TimeSpan.Zero;
    public bool EndOfStream => Volatile.Read(ref _slot) is { } slot && slot.Stream?.Failure is null &&
        (slot.Stream?.IsCompleted ?? (Volatile.Read(ref slot.Position) >= slot.Audio!.Samples.Length));

    public void SwitchTo(PcmAudio? audio, TimeSpan startAt = default)
        => SwitchTo(null, audio, startAt, 0, 0);

    public void SwitchTo(ClipPlayer.Core.Track? track, PcmAudio? audio, TimeSpan startAt = default,
        long revision = 0, long selectionGeneration = 0)
    {
        ThrowIfDisposed();
        if (audio is not null && audio.Format != _format) throw new ArgumentException("PCM-Mixformat stimmt nicht überein.", nameof(audio));
        var slot = audio is null ? null : new Slot(audio, track, revision, selectionGeneration);
        if (slot is not null)
        {
            var frame = Math.Clamp((long)(startAt.TotalSeconds * _format.SampleRate), 0, audio!.FrameCount);
            slot.Position = checked((int)(frame * _format.Channels));
        }
        Interlocked.Exchange(ref _slot, slot);
    }

    public void SwitchToStreaming(IStreamingAudio stream, TimeSpan startAt = default)
        => SwitchToStreaming(null, stream, startAt, 0, 0);

    public void SwitchToStreaming(ClipPlayer.Core.Track? track, IStreamingAudio stream, TimeSpan startAt = default,
        long revision = 0, long selectionGeneration = 0)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ThrowIfDisposed();
        if (stream.SampleRate != _format.SampleRate || stream.Channels != _format.Channels)
            throw new ArgumentException("Streaming-Mixformat stimmt nicht überein.", nameof(stream));
        Interlocked.Exchange(ref _slot, new Slot(stream, track, revision, selectionGeneration));
        if (startAt > TimeSpan.Zero) throw new NotSupportedException("Seek beim Streaming-Start ist nicht unterstützt.");
    }

    public void Seek(TimeSpan position)
    {
        ThrowIfDisposed();
        var slot = Volatile.Read(ref _slot);
        if (slot?.Audio is not { } audio) return;
        var frame = Math.Clamp((long)(position.TotalSeconds * _format.SampleRate), 0, audio.FrameCount);
        Volatile.Write(ref slot.Position, checked((int)(frame * _format.Channels)));
    }

    public int Read(byte[] buffer, int offset, int count)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(buffer);
        if ((uint)offset > (uint)buffer.Length || count < 0 || buffer.Length - offset < count)
            throw new ArgumentOutOfRangeException(nameof(count));
        var slot = Volatile.Read(ref _slot);
        if (slot is null || count == 0) return 0;
        if (slot.Stream is { } stream)
        {
            if (stream.Failure is { } failure) throw new InvalidDataException("Streaming-Wiedergabe fehlgeschlagen.", failure);
            var samples = Math.Min(count / sizeof(float), 32_768);
            var read = stream.Read(_streamScratch.AsSpan(0, samples));
            if (read == 0) return 0;
            Buffer.BlockCopy(_streamScratch, 0, buffer, offset, read * sizeof(float));
            return read * sizeof(float);
        }
        var audio = slot.Audio!;
        var sampleCount = Math.Min(count / sizeof(float), audio.Samples.Length - Volatile.Read(ref slot.Position));
        if (sampleCount <= 0) return 0;
        var start = Interlocked.Add(ref slot.Position, sampleCount) - sampleCount;
        Buffer.BlockCopy(audio.RawSamples, start * sizeof(float), buffer, offset, sampleCount * sizeof(float));
        return sampleCount * sizeof(float);
    }

    private readonly float[] _streamScratch = new float[32_768];

    private void ThrowIfDisposed() { ObjectDisposedException.ThrowIf(_disposed, this); }
    public void Dispose() { _disposed = true; Interlocked.Exchange(ref _slot, null); }
}
