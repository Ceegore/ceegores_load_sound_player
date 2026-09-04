using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

internal sealed class PcmClipTooLargeException : Exception
{
    public PcmClipTooLargeException() : base("Audio clip überschreitet 128 MiB PCM-Limit.") { }
}

internal static class DecoderSupport
{
    public static async ValueTask<PcmAudio> ReadSamplesAsync(
        WaveStream source, ISampleProvider samples, AudioDecodeRequest request,
        CancellationToken cancellationToken)
    {
        var format = new AudioFormat(samples.WaveFormat.SampleRate, samples.WaveFormat.Channels);
        if (!format.IsValid) throw new InvalidDataException("Ungültiges Audioformat.");
        var target = request.TargetFormat ?? format;
        if (!target.IsValid) throw new ArgumentOutOfRangeException(nameof(request));
        const long maxBytes = 128L * 1024 * 1024;
        var maxSamples = maxBytes / sizeof(float);
        var sourceBytes = EstimatePcmBytes(source.TotalTime, format);
        var targetBytes = EstimatePcmBytes(source.TotalTime, target);
        // Decide before allocating/decoding. This also covers a small mono source
        // whose fixed 48 kHz stereo mix would cross the PCM budget after conversion.
        if (sourceBytes > maxBytes || targetBytes > maxBytes) throw new PcmClipTooLargeException();
        var buffer = new float[Math.Min(32_768, maxSamples)];
        var output = new List<float>(Math.Min(buffer.Length, 262_144));
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = samples.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            if (output.Count + read > maxSamples) throw new PcmClipTooLargeException();
            output.AddRange(buffer.AsSpan(0, read).ToArray());
            await Task.Yield();
        }
        var decoded = new PcmAudio(format, output.ToArray());
        return request.TargetFormat is { } targetFormat && targetFormat != format
            ? ConvertFormat(decoded, targetFormat, maxBytes)
            : decoded;
    }

    private static PcmAudio ConvertFormat(PcmAudio source, AudioFormat target, long maxBytes)
    {
        if (!target.IsValid) throw new ArgumentOutOfRangeException(nameof(target));
        if (source.FrameCount == 0) return new PcmAudio(target, Array.Empty<float>());
        var frames = (long)Math.Ceiling(source.FrameCount * (double)target.SampleRate / source.Format.SampleRate);
        var samples = checked(frames * target.Channels);
        if (samples * sizeof(float) > maxBytes) throw new PcmClipTooLargeException();
        var result = new float[samples];
        for (var frame = 0L; frame < frames; frame++)
        {
            var sourcePosition = frame * (double)source.Format.SampleRate / target.SampleRate;
            var left = Math.Min((int)sourcePosition, source.FrameCount - 1);
            var right = Math.Min(left + 1, source.FrameCount - 1);
            var fraction = sourcePosition - left;
            for (var channel = 0; channel < target.Channels; channel++)
            {
                var value = 0d;
                if (source.Format.Channels == 1) value = Lerp(source.Samples.Span[left], source.Samples.Span[right], fraction);
                else if (target.Channels == 1)
                    for (var sourceChannel = 0; sourceChannel < source.Format.Channels; sourceChannel++)
                        value += Lerp(source.Samples.Span[left * source.Format.Channels + sourceChannel], source.Samples.Span[right * source.Format.Channels + sourceChannel], fraction) / source.Format.Channels;
                else if (channel < source.Format.Channels)
                    value = Lerp(source.Samples.Span[left * source.Format.Channels + channel], source.Samples.Span[right * source.Format.Channels + channel], fraction);
                result[frame * target.Channels + channel] = (float)value;
            }
        }
        return new PcmAudio(target, result);
    }

    private static double EstimatePcmBytes(TimeSpan duration, AudioFormat format) =>
        duration.TotalSeconds * format.SampleRate * format.Channels * AudioFormat.BytesPerSample;

    private static double Lerp(float left, float right, double fraction) => left + (right - left) * fraction;
}
