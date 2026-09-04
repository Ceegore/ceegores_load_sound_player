namespace ClipPlayer.Audio.Windows;

using ClipPlayer.Core;

public interface IAudioOutput : IDisposable
{
    AudioFormat Format { get; }
    bool IsPlaying { get; }
    void SwitchTo(PcmAudio? audio, TimeSpan startAt = default);
    void Play();
    void Pause();
    void StopPlayback();
}

public interface IStreamingAudioOutput : IAudioOutput
{
    ValueTask PlayStreamingAsync(Track track, IStreamingAudio audio, TimeSpan startAt, CancellationToken cancellationToken);
}
