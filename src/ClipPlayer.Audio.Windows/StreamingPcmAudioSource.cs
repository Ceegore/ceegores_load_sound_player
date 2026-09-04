using System.Buffers;
using ClipPlayer.Core;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ClipPlayer.Audio.Windows;

/// <summary>Background decoder feeding a bounded five-second SPSC PCM ring.</summary>
public sealed class StreamingPcmAudioSource : IStreamingAudio
{
    private readonly WaveStream _reader;
    private readonly ISampleProvider _samples;
    private readonly PcmRingBuffer _ring;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly TaskCompletionSource<bool> _primed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _startGate = new();
    private Task? _worker;
    private int _consumedSamples;
    private volatile bool _completed;
    private bool _disposed;

    private StreamingPcmAudioSource(WaveStream reader, ISampleProvider samples)
    {
        _reader = reader;
        _samples = samples;
        var format = new AudioFormat(samples.WaveFormat.SampleRate, samples.WaveFormat.Channels);
        if (!format.IsValid) throw new InvalidDataException("Ungültiges Audioformat.");
        Format = format;
        Duration = reader.TotalTime;
        _ring = new PcmRingBuffer(format, TimeSpan.FromSeconds(5));
    }

    public AudioFormat Format { get; }
    public int SampleRate => Format.SampleRate;
    public int Channels => Format.Channels;
    public TimeSpan Duration { get; }
    public TimeSpan Position => TimeSpan.FromSeconds((double)Volatile.Read(ref _consumedSamples) / Channels / SampleRate);
    public bool IsCompleted => _completed && _ring.AvailableSamples == 0;

    public static StreamingPcmAudioSource OpenWave(AudioDecodeRequest request)
    {
        var reader = new WaveFileReader(request.Track.FullPath);
        try
        {
            if (reader.WaveFormat.Encoding is not (WaveFormatEncoding.Pcm or WaveFormatEncoding.IeeeFloat))
                throw new NotSupportedException("WAV muss PCM oder IEEE Float enthalten.");
            return new StreamingPcmAudioSource(reader, ConvertProvider(reader.ToSampleProvider(), request.TargetFormat));
        }
        catch { reader.Dispose(); throw; }
    }

    public static StreamingPcmAudioSource OpenMediaFoundation(AudioDecodeRequest request)
    {
        var reader = new MediaFoundationReader(request.Track.FullPath);
        try
        {
            return new StreamingPcmAudioSource(reader, ConvertProvider(reader.ToSampleProvider(), request.TargetFormat));
        }
        catch { reader.Dispose(); throw; }
    }

    public ValueTask PrimeAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        lock (_startGate) _worker ??= Task.Run(DecodeLoopAsync, CancellationToken.None);
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.CompletedTask;
    }

    public int Read(Span<float> destination)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var read = _ring.Read(destination);
        if (read > 0) Interlocked.Add(ref _consumedSamples, read);
        if (read == destination.Length || IsCompleted) return read;
        destination[read..].Clear();
        return destination.Length;
    }

    private async Task DecodeLoopAsync()
    {
        var rented = ArrayPool<float>.Shared.Rent(32_768);
        try
        {
            while (!_cancellation.IsCancellationRequested)
            {
                var read = _samples.Read(rented, 0, rented.Length);
                if (read == 0) break;
                var written = 0;
                while (written < read && !_cancellation.IsCancellationRequested)
                {
                    written += _ring.Write(rented.AsSpan(written, read - written));
                    if (written < read) await Task.Delay(1, _cancellation.Token).ConfigureAwait(false);
                    if (!_primed.Task.IsCompleted) _primed.TrySetResult(true);
                }
            }
            _completed = true;
            if (!_primed.Task.IsCompleted) _primed.TrySetResult(true);
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested) { _primed.TrySetCanceled(_cancellation.Token); }
        catch (Exception exception) { _completed = true; _primed.TrySetException(exception); }
        finally { ArrayPool<float>.Shared.Return(rented); }
    }

    private static ISampleProvider ConvertProvider(ISampleProvider source, AudioFormat? target)
    {
        if (target is not { } desired) return source;
        var sourceFormat = new AudioFormat(source.WaveFormat.SampleRate, source.WaveFormat.Channels);
        if (!desired.IsValid) throw new ArgumentOutOfRangeException(nameof(target));
        if (sourceFormat.Channels == 1 && desired.Channels == 2) source = new MonoToStereoSampleProvider(source);
        else if (sourceFormat.Channels == 2 && desired.Channels == 1) source = new StereoToMonoSampleProvider(source);
        else if (sourceFormat.Channels != desired.Channels) throw new NotSupportedException("Streaming-Kanalzahl wird nicht unterstützt.");
        if (source.WaveFormat.SampleRate != desired.SampleRate)
            source = new WdlResamplingSampleProvider(source, desired.SampleRate);
        return source;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _cancellation.Cancel();
        if (_worker is not null)
        {
            try { await _worker.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _reader.Dispose();
        _cancellation.Dispose();
    }
}
