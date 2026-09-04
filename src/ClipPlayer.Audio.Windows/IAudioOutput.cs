namespace ClipPlayer.Audio.Windows;

public interface IAudioOutput : IDisposable
{
    AudioFormat Format { get; }
    bool IsPlaying { get; }
    void SwitchTo(PcmAudio? audio, TimeSpan startAt = default);
    void Play();
    void Pause();
    void StopPlayback();
}
