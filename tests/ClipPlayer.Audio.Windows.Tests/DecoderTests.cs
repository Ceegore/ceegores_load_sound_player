using ClipPlayer.Audio.Windows;

namespace ClipPlayer.Audio.Windows.Tests;

public sealed class DecoderTests
{
    [Theory]
    [InlineData(".wav", true)]
    [InlineData(".WAV", true)]
    [InlineData(".mp3", false)]
    [InlineData(".flac", false)]
    public void DecoderRegistryUsesCaseInsensitiveExtension(string extension, bool wav)
    {
        var registry = new DecoderRegistry(new IAudioDecoder[] { new WavDecoder(), new MediaFoundationDecoder() });
        var decoder = registry.Resolve("clip" + extension);
        Assert.Equal(wav, decoder is WavDecoder);
    }

    [Fact]
    public void UnknownExtensionIsExplicitlyRejected()
    {
        var registry = new DecoderRegistry(new[] { new WavDecoder() });
        Assert.Throws<NotSupportedException>(() => registry.Resolve("clip.ogg"));
    }
}
