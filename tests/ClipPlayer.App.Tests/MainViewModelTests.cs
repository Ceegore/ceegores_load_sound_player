using ClipPlayer.App;

namespace ClipPlayer.App.Tests;

public sealed class MainViewModelTests
{
    [Fact]
    public async Task SelectionAutoplaysAndNextPreloadsThreeItems()
    {
        using var files = new TempFiles("one.wav", "two.mp3", "three.flac", "four.wav", "ignored.txt");
        var player = new FakePlaybackPort();
        await using var model = new MainViewModel(player);

        await model.SetItemsAsync(files.Paths, 0);

        Assert.Equal("one.wav", model.SelectedItem!.Name);
        Assert.Equal(files.Paths[0], player.CurrentPath);
        await Task.Delay(20);
        Assert.Equal(3, player.Preloaded.Count);
    }

    [Fact]
    public async Task RelativeSelectionAutoplaysTargetAndPausePreservesPosition()
    {
        using var files = new TempFiles("a.wav", "b.wav", "c.wav");
        var player = new FakePlaybackPort { Position = TimeSpan.FromSeconds(4), Duration = TimeSpan.FromSeconds(12) };
        await using var model = new MainViewModel(player);
        await model.SetItemsAsync(files.Paths);

        await model.SelectRelativeAsync(1);
        Assert.Equal("b.wav", model.SelectedItem!.Name);
        await model.TogglePauseForTestAsync();
        Assert.True(model.IsPaused);
        Assert.Equal(TimeSpan.FromSeconds(4), player.Position);
    }

    [Fact]
    public async Task DeleteRemovesCurrentItemAfterConfirmation()
    {
        using var files = new TempFiles("a.wav", "b.wav");
        var recycle = new FakeRecycleBin();
        await using var model = new MainViewModel(new FakePlaybackPort(), recycleBin: recycle, confirmation: new AlwaysConfirm());
        await model.SetItemsAsync(files.Paths, 0);

        await model.DeleteForTestAsync();

        Assert.Single(model.Items);
        Assert.Equal(files.Paths[0], recycle.LastPath);
        Assert.Equal("b.wav", model.SelectedItem!.Name);
    }

    [Fact]
    public void DiscoveryFiltersSupportedExtensionsAndSortsNames()
    {
        using var files = new TempFiles("clip10.wav", "clip2.mp3", "clip1.flac", "clip.txt");
        var found = AudioFileDiscovery.ScanFolder(files.Paths[0]);
        Assert.Equal(ExpectedNames, found.Select(Path.GetFileName));
        Assert.False(AudioFileRules.IsSupported("track.ogg"));
    }

    [Fact]
    public async Task RealPortBuildsCorePlaylistWithoutOpeningDeviceUntilPlayback()
    {
        using var files = new TempFiles("one.wav", "two.wav");
        await using var port = new CorePlaybackPort();
        await port.SetPlaylistAsync(files.Paths, CancellationToken.None);
        Assert.False(port.IsPlaying);
        Assert.Equal(TimeSpan.Zero, port.Position);
    }

    private static readonly string[] ExpectedNames = ["clip1.flac", "clip2.mp3", "clip10.wav"];

    private sealed class TempFiles : IDisposable
    {
        private readonly string _folder;
        public string[] Paths { get; }
        public TempFiles(params string[] names)
        {
            _folder = Directory.CreateTempSubdirectory("clipplayer-tests-").FullName;
            Paths = names.Select(name => Path.Combine(_folder, name)).ToArray();
            foreach (var path in Paths) File.WriteAllBytes(path, [0]);
        }
        public void Dispose() => Directory.Delete(_folder, true);
    }

    private sealed class FakePlaybackPort : IPlaybackPort
    {
        public string? CurrentPath { get; private set; }
        public List<string> Preloaded { get; } = [];
        public TimeSpan Position { get; set; }
        public TimeSpan Duration { get; set; } = TimeSpan.FromSeconds(10);
        public bool IsPlaying { get; private set; }
        public double Volume { get; set; } = 1;
        public Task PlayAsync(string path, CancellationToken cancellationToken) { CurrentPath = path; IsPlaying = true; return Task.CompletedTask; }
        public Task PauseAsync(CancellationToken cancellationToken) { IsPlaying = false; return Task.CompletedTask; }
        public Task ResumeAsync(CancellationToken cancellationToken) { IsPlaying = true; return Task.CompletedTask; }
        public Task StopAsync(CancellationToken cancellationToken) { IsPlaying = false; return Task.CompletedTask; }
        public Task SeekAsync(TimeSpan position, CancellationToken cancellationToken) { Position = position; return Task.CompletedTask; }
        public Task PreloadAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken) { Preloaded.AddRange(paths); return Task.CompletedTask; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeRecycleBin : IRecycleBin { public string? LastPath { get; private set; } public void SendToRecycleBin(string path) => LastPath = path; }
    private sealed class AlwaysConfirm : IConfirmation { public bool Confirm(string title, string message) => true; }
}

internal static class MainViewModelTestExtensions
{
    public static Task TogglePauseForTestAsync(this MainViewModel model) => ((AsyncCommand)model.TogglePauseCommand).RunForTestsAsync();
    public static Task DeleteForTestAsync(this MainViewModel model) => ((AsyncCommand)model.DeleteCommand).RunForTestsAsync();
}
