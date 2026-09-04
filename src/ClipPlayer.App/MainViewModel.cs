using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using System.Windows;
using ClipPlayer.Core;

namespace ClipPlayer.App;

public sealed class MainViewModel : INotifyPropertyChanged, IAsyncDisposable
{
    private readonly IPlaybackPort _player;
    private readonly IFilePicker _picker;
    private readonly IRecycleBin _recycleBin;
    private readonly IConfirmation _confirmation;
    private readonly SemaphoreSlim _selectionGate = new(1, 1);
    private CancellationTokenSource _selectionCancellation = new();
    private int _selectionGeneration;
    private int _selectedIndex = -1;
    private string _status = "Keine Datei geöffnet";
    private bool _isBusy;
    private bool _isPaused;
    private double _volume = 1;
    private TimeSpan _position;
    private TimeSpan _duration;

    public MainViewModel(IPlaybackPort player, IFilePicker? picker = null, IRecycleBin? recycleBin = null, IConfirmation? confirmation = null)
    {
        _player = player;
        _picker = picker ?? new WpfFilePicker();
        _recycleBin = recycleBin ?? new WindowsRecycleBin();
        _confirmation = confirmation ?? new MessageBoxConfirmation();
        OpenCommand = new AsyncCommand(OpenAsync);
        PreviousCommand = new AsyncCommand(() => SelectRelativeAsync(-1), () => SelectedIndex > 0);
        NextCommand = new AsyncCommand(() => SelectRelativeAsync(1), () => SelectedIndex >= 0 && SelectedIndex < Items.Count - 1);
        TogglePauseCommand = new AsyncCommand(TogglePauseAsync);
        DeleteCommand = new AsyncCommand(DeleteAsync);
        _player.Volume = _volume;
        if (_player is IPlaybackStateSource stateSource)
            stateSource.PlaybackChanged += OnPlaybackChanged;
    }

    public ObservableCollection<ClipItem> Items { get; } = [];
    public ClipItem? SelectedItem => _selectedIndex >= 0 && _selectedIndex < Items.Count ? Items[_selectedIndex] : null;
    public int SelectedIndex { get => _selectedIndex; private set { if (Set(ref _selectedIndex, value)) { OnPropertyChanged(nameof(SelectedItem)); RefreshNavigationCommands(); } } }
    public string Status { get => _status; private set => Set(ref _status, value); }
    public bool IsBusy { get => _isBusy; private set { if (Set(ref _isBusy, value)) RefreshNavigationCommands(); } }
    public bool IsPaused { get => _isPaused; private set => Set(ref _isPaused, value); }
    public double Volume { get => _volume; set { if (Set(ref _volume, Math.Clamp(value, 0, 1))) _player.Volume = _volume; } }
    public TimeSpan Position { get => _position; private set => Set(ref _position, value); }
    public TimeSpan Duration { get => _duration; private set => Set(ref _duration, value); }
    public bool CanSeek => _player.CanSeek;
    public double PositionRatio => Duration > TimeSpan.Zero ? Math.Clamp(Position.TotalSeconds / Duration.TotalSeconds, 0, 1) : 0;
    public string PositionText => FormatTime(Position);
    public string DurationText => FormatTime(Duration);
    public ICommand OpenCommand { get; }
    public ICommand PreviousCommand { get; }
    public ICommand NextCommand { get; }
    public ICommand TogglePauseCommand { get; }
    public ICommand DeleteCommand { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public async Task InitializeAsync(string[] args)
    {
        try
        {
            var argument = args.FirstOrDefault(x => AudioFileRules.IsSupported(x) && File.Exists(x));
            if (argument is null) return;
            var files = AudioFileDiscovery.ScanFolder(argument);
            await SetItemsAsync(files, Array.IndexOf(files.ToArray(), Path.GetFullPath(argument))).ConfigureAwait(true);
        }
        catch (Exception ex) { Status = $"Dateien konnten nicht geladen werden: {ex.Message}"; }
    }

    public async Task SetItemsAsync(IEnumerable<string> paths, int selectedIndex = 0)
    {
        var valid = paths.Where(AudioFileRules.IsSupported).Where(File.Exists).Select(x => new ClipItem(x)).ToArray();
        Items.Clear();
        foreach (var item in valid) Items.Add(item);
        OnPropertyChanged(nameof(CanSeek));
        RefreshNavigationCommands();
        if (Items.Count == 0) { SelectedIndex = -1; Status = "Keine unterstützten Dateien"; return; }
        var targetIndex = Math.Clamp(selectedIndex, 0, Items.Count - 1);
        if (_player is IPlaylistPlaybackPort playlist)
        {
            SelectedIndex = targetIndex;
            await playlist.SetPlaylistAsync(Items.Select(item => item.Path).ToArray(), targetIndex,
                CancellationToken.None).ConfigureAwait(true);
            if (playlist.HandlesSelectionAtomically)
            {
                Duration = _player.Duration;
                Position = _player.Position;
                OnPropertyChanged(nameof(CanSeek));
                Status = SelectedItem?.Name ?? "";
                return;
            }
        }
        await SelectAsync(targetIndex).ConfigureAwait(true);
    }

    public async Task SelectRelativeAsync(int offset)
    {
        if (Items.Count == 0) return;
        var target = Math.Clamp(SelectedIndex + offset, 0, Items.Count - 1);
        if (target != SelectedIndex) await SelectAsync(target).ConfigureAwait(true);
    }

    public Task SelectFromUiAsync(int index) => index >= 0 && index < Items.Count ? SelectAsync(index) : Task.CompletedTask;

    public async Task SeekToRatioAsync(double ratio)
    {
        if (Duration <= TimeSpan.Zero || SelectedItem is null) return;
        if (!_player.CanSeek)
        {
            Status = "Seek ist für sehr große Streaming-Dateien nicht verfügbar.";
            return;
        }
        try
        {
            await _player.SeekAsync(TimeSpan.FromSeconds(Math.Clamp(ratio, 0, 1) * Duration.TotalSeconds), CancellationToken.None).ConfigureAwait(true);
            RefreshPosition();
        }
        catch (Exception ex) { Status = $"Seek fehlgeschlagen: {ex.Message}"; }
    }

    private async Task SelectAsync(int index)
    {
        var generation = Interlocked.Increment(ref _selectionGeneration);
        _selectionCancellation.Cancel();
        _selectionCancellation.Dispose();
        _selectionCancellation = new CancellationTokenSource();
        var token = _selectionCancellation.Token;
        await _selectionGate.WaitAsync().ConfigureAwait(true);
        try
        {
            SelectedIndex = index;
            var item = SelectedItem!;
            IsBusy = true;
            IsPaused = false;
            Status = $"Öffne {item.Name} …";
            await _player.PlayAsync(item.Path, token).ConfigureAwait(true);
            if (generation != _selectionGeneration) return;
            Duration = _player.Duration;
            Position = _player.Position;
            OnPropertyChanged(nameof(PositionText));
            OnPropertyChanged(nameof(DurationText));
            OnPropertyChanged(nameof(CanSeek));
            OnPropertyChanged(nameof(PositionRatio));
            Status = item.Name;
            _ = PreloadNextAsync(generation, token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception ex)
        {
            if (generation == _selectionGeneration) Status = $"Fehler: {ex.Message}";
        }
        finally { IsBusy = false; _selectionGate.Release(); }
    }

    private async Task PreloadNextAsync(int generation, CancellationToken token)
    {
        var paths = Items.Skip(SelectedIndex + 1).Take(3).Select(x => x.Path).ToArray();
        try { await _player.PreloadAsync(paths, token).ConfigureAwait(true); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { /* Preload failure must never interrupt current playback. */ }
        if (generation != _selectionGeneration) return;
    }

    private async Task OpenAsync()
    {
        var files = _picker.PickFiles();
        if (files.Count > 0) await SetItemsAsync(files, 0).ConfigureAwait(true);
    }

    private async Task TogglePauseAsync()
    {
        if (SelectedItem is null || IsBusy) return;
        try
        {
            if (IsPaused) { await _player.ResumeAsync(CancellationToken.None); IsPaused = false; Status = SelectedItem.Name; }
            else { await _player.PauseAsync(CancellationToken.None); IsPaused = !_player.IsPlaying; Status = IsPaused ? $"Pausiert: {SelectedItem.Name}" : SelectedItem.Name; }
        }
        catch (Exception ex) { Status = $"Fehler: {ex.Message}"; }
    }

    private async Task DeleteAsync()
    {
        var item = SelectedItem;
        if (item is null || !_confirmation.Confirm("In den Papierkorb verschieben?", $"Soll „{item.Name}“ in den Papierkorb verschoben werden?")) return;
        try
        {
            await _player.StopAsync(CancellationToken.None).ConfigureAwait(true);
            var oldIndex = SelectedIndex;
            _recycleBin.SendToRecycleBin(item.Path);
            Items.RemoveAt(oldIndex);
            if (Items.Count == 0) { SelectedIndex = -1; Status = "Keine Datei geöffnet"; return; }
            var targetIndex = Math.Min(oldIndex, Items.Count - 1);
            if (_player is IPlaylistPlaybackPort playlist)
            {
                SelectedIndex = targetIndex;
                await playlist.SetPlaylistAsync(Items.Select(current => current.Path).ToArray(), targetIndex,
                    CancellationToken.None).ConfigureAwait(true);
                if (playlist.HandlesSelectionAtomically)
                {
                    OnPropertyChanged(nameof(CanSeek));
                    Status = SelectedItem?.Name ?? "";
                    return;
                }
            }
            await SelectAsync(targetIndex).ConfigureAwait(true);
        }
        catch (Exception ex) { Status = $"Löschen fehlgeschlagen: {ex.Message}"; }
    }

    public void RefreshPosition()
    {
        if (SelectedItem is null) return;
        Position = _player.Position;
        Duration = _player.Duration;
        OnPropertyChanged(nameof(PositionRatio));
        OnPropertyChanged(nameof(PositionText));
        OnPropertyChanged(nameof(DurationText));
    }

    public async ValueTask DisposeAsync()
    {
        _selectionCancellation.Cancel();
        if (_player is IPlaybackStateSource stateSource)
            stateSource.PlaybackChanged -= OnPlaybackChanged;
        await _player.DisposeAsync().ConfigureAwait(false);
        _selectionGate.Dispose();
        _selectionCancellation.Dispose();
    }

    private void OnPlaybackChanged(object? sender, PlaybackSnapshot snapshot)
    {
        void Apply()
        {
            if (snapshot.CurrentIndex >= 0 && snapshot.CurrentIndex < Items.Count)
                SelectedIndex = snapshot.CurrentIndex;
            IsPaused = snapshot.State == PlaybackState.Paused;
            Position = snapshot.Position;
            Duration = _player.Duration;
            OnPropertyChanged(nameof(PositionRatio));
            OnPropertyChanged(nameof(PositionText));
            OnPropertyChanged(nameof(DurationText));
            Status = snapshot.State switch
            {
                PlaybackState.Faulted => $"Fehler: {snapshot.Error ?? "Unbekannter Fehler"}",
                PlaybackState.Paused when SelectedItem is not null => $"Pausiert: {SelectedItem.Name}",
                PlaybackState.Stopped when SelectedItem is not null => $"Beendet: {SelectedItem.Name}",
                PlaybackState.Playing when SelectedItem is not null => SelectedItem.Name,
                PlaybackState.Empty => "Keine Datei geöffnet",
                _ => Status
            };
        }

        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess()) dispatcher.BeginInvoke(Apply);
        else Apply();
    }

    private static string FormatTime(TimeSpan value) => value.TotalHours >= 1 ? value.ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture) : value.ToString(@"m\:ss", CultureInfo.InvariantCulture);
    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null) { if (EqualityComparer<T>.Default.Equals(field, value)) return false; field = value; OnPropertyChanged(name); return true; }
    private void OnPropertyChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    private void RefreshNavigationCommands()
    {
        (PreviousCommand as AsyncCommand)?.RaiseCanExecuteChanged();
        (NextCommand as AsyncCommand)?.RaiseCanExecuteChanged();
    }
}

public sealed class AsyncCommand(Func<Task> action, Func<bool>? canExecute = null) : ICommand
{
    private readonly Func<bool> _canExecute = canExecute ?? (() => true);
    private readonly object _gate = new();
    private int _running;
    private int _pending;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => Volatile.Read(ref _running) == 0 && _canExecute();
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    public void Execute(object? parameter)
    {
        lock (_gate)
        {
            if (_running == 0 && !_canExecute()) return;
            _pending++;
            if (_running != 0) return;
            _running = 1;
        }
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        _ = DrainAsync();
    }

    private async Task DrainAsync()
    {
        try
        {
            while (true)
            {
                lock (_gate)
                {
                    if (_pending == 0) { _running = 0; break; }
                    _pending--;
                }
                try { await action(); }
                catch { /* one stale navigation must not discard later key presses */ }
            }
        }
        finally
        {
            CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }
    }
    internal Task RunForTestsAsync() => action();
}
