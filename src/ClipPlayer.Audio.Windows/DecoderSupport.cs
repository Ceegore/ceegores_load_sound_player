using NAudio.Wave;

namespace ClipPlayer.Audio.Windows;

internal static class DecoderSupport
{
    public static async ValueTask<PcmAudio> ReadSamplesAsync(
        WaveStream source, ISampleProvider samples, AudioDecodeRequest request,
        CancellationToken cancellationToken)
    {
        var format = new AudioFormat(samples.WaveFormat.SampleRate, samples.WaveFormat.Channels);
        if (!format.IsValid) throw new InvalidDataException("Ungültiges Audioformat.");
        const long maxBytes = 128L * 1024 * 1024;
        var maxSamples = maxBytes / sizeof(float);
        var buffer = new float[Math.Min(32_768, maxSamples)];
        var output = new List<float>(Math.Min(buffer.Length, 262_144));
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = samples.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            if (output.Count + read > maxSamples) throw new InvalidDataException("Audio clip überschreitet 128 MiB PCM-Limit.");
            output.AddRange(buffer.AsSpan(0, read).ToArray());
            await Task.Yield();
        }
        var decoded = new PcmAudio(format, output.ToArray());
        return request.TargetFormat is { } target && target != format
            ? ConvertFormat(decoded, target, maxBytes)
            : decoded;
    }

    private static PcmAudio ConvertFormat(PcmAudio source, AudioFormat target, long maxBytes)
    {
        if (!target.IsValid) throw new ArgumentOutOfRangeException(nameof(target));
        if (source.FrameCount == 0) return new PcmAudio(target, Array.Empty<float>());
        var frames = (long)Math.Ceiling(source.FrameCount * (double)target.SampleRate / source.Format.SampleRate);
        var samples = checked(frames * target.Channels);
        if (samples * sizeof(float) > maxBytes) throw new InvalidDataException("Konvertierter Clip überschreitet 128 MiB PCM-Limit.");
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

    private static double Lerp(float left, float right, double fraction) => left + (right - left) * fraction;
}
