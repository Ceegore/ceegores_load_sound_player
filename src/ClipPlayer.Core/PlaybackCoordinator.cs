namespace ClipPlayer.Core;

/// <summary>
/// Coordinates selection and output. Loads run outside the command queue; completion is
/// accepted only when its generation is still current.
/// </summary>
public sealed class PlaybackCoordinator : IAsyncDisposable
{
    private readonly ITrackDecoder? _decoder;
    private readonly IAudioOutput _output;
    private readonly ITrackCache? _cache;
    private readonly IRecycleBin? _recycleBin;
    private readonly PlaybackCommandQueue _commands = new();
    private readonly SemaphoreSlim _decodeGate = new(1, 1);
    private Playlist _playlist = Playlist.Empty;
    private PlaybackSnapshot _snapshot = PlaybackSnapshot.Empty;
    private CancellationTokenSource _selectionCancellation = new();
    private bool _disposed;

    public PlaybackCoordinator(
        ITrackDecoder? decoder = null,
        IAudioOutput? output = null,
        ITrackCache? cache = null,
        IRecycleBin? recycleBin = null)
    {
        _decoder = decoder;
        _output = output ?? new NullAudioOutput();
        _cache = cache;
        _recycleBin = recycleBin;
    }

    public Playlist Playlist => _playlist;
    public PlaybackSnapshot Snapshot => _snapshot;
    public event EventHandler<PlaybackSnapshot>? SnapshotChanged;

    public ValueTask InitializeAsync(CancellationToken cancellationToken = default) =>
        _playlist.Count == 0 ? SetEmptyAsync(cancellationToken) : SelectAsync(0, cancellationToken);

    public async ValueTask ReplacePlaylistAsync(IEnumerable<Track> tracks, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(tracks);
        var replacement = new Playlist(tracks);
        await _commands.EnqueueAsync(() => ReplaceCoreAsync(replacement)).ConfigureAwait(false);
        if (replacement.Count > 0) await SelectAsync(0, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask SelectAsync(int index, CancellationToken cancellationToken = default)
    {
        var request = await _commands.EnqueueAsync(() => BeginSelectionAsync(index)).ConfigureAwait(false);
        DecodedAudio? audio = null;
        Exception? failure = null;
        try
        {
            audio = await LoadAsync(request.Track, request.CancellationToken, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (request.CancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception exception)
        {
            failure = exception;
        }

        var accepted = await _commands.EnqueueAsync(() => CompleteSelectionAsync(request, audio, failure)).ConfigureAwait(false);
        if (accepted && failure is null && audio is not null)
        {
            _ = PreloadAheadAsync(request);
        }
    }

    public async ValueTask PreviousAsync(CancellationToken cancellationToken = default) =>
        _ = await MoveAsync(previous: true, cancellationToken).ConfigureAwait(false);

    public async ValueTask NextAsync(CancellationToken cancellationToken = default) =>
        _ = await MoveAsync(previous: false, cancellationToken).ConfigureAwait(false);

    public async ValueTask TogglePauseAsync(CancellationToken cancellationToken = default)
    {
        var restartIndex = await _commands.EnqueueAsync(async () =>
        {
            switch (_snapshot.State)
            {
                case PlaybackState.Playing:
                    await _output.PauseAsync(cancellationToken).ConfigureAwait(false);
                    SetSnapshot(_snapshot with { State = PlaybackState.Paused });
                    return -1;
                case PlaybackState.Paused:
                    await _output.ResumeAsync(cancellationToken).ConfigureAwait(false);
                    SetSnapshot(_snapshot with { State = PlaybackState.Playing });
                    return -1;
                case PlaybackState.Stopped when _playlist.CurrentIndex >= 0:
                    return _playlist.CurrentIndex;
                default:
                    return -1;
            }
        }).ConfigureAwait(false);
        if (restartIndex >= 0) await SelectAsync(restartIndex, cancellationToken).ConfigureAwait(false);
    }

    public ValueTask StopAsync(CancellationToken cancellationToken = default) =>
        _commands.EnqueueAsync(async () =>
        {
            InvalidateActiveSelection();
            await _output.StopAsync(cancellationToken).ConfigureAwait(false);
            if (_playlist.CurrentIndex >= 0)
                SetSnapshot(_snapshot with { State = PlaybackState.Stopped, Position = TimeSpan.Zero, Error = null });
            else
                SetSnapshot(PlaybackSnapshot.Empty);
        });

    public async ValueTask NotifyTrackEndedAsync(CancellationToken cancellationToken = default)
    {
        var next = await _commands.EnqueueAsync(() =>
            new ValueTask<int>(_playlist.CanMoveNext ? _playlist.CurrentIndex + 1 : -1)).ConfigureAwait(false);
        if (next >= 0) await SelectAsync(next, cancellationToken).ConfigureAwait(false);
        else await StopAsync(cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DeleteCurrentAsync(CancellationToken cancellationToken = default)
    {
        if (_recycleBin is null) throw new InvalidOperationException("Kein Papierkorb-Port konfiguriert.");
        var target = await _commands.EnqueueAsync(async () =>
        {
            var track = _playlist.Current;
            if (track is null) return ((Track?)null, -1);
            InvalidateActiveSelection();
            await _output.StopAsync(cancellationToken).ConfigureAwait(false);
            SetSnapshot(_snapshot with { State = PlaybackState.Stopped, Position = TimeSpan.Zero });
            return (track, _playlist.CurrentIndex);
        }).ConfigureAwait(false);
        if (target.Item1 is null) return;

        try { await _recycleBin.MoveToRecycleBinAsync(target.Item1, cancellationToken).ConfigureAwait(false); }
        catch (Exception exception)
        {
            await SetFaultAsync(exception).ConfigureAwait(false);
            return;
        }

        var next = await _commands.EnqueueAsync(() =>
        {
            var index = _playlist.ToList().FindIndex(track => track == target.Item1);
            if (index < 0) return new ValueTask<int>(-1);
            _playlist = _playlist.RemoveAt(index, out var nextIndex);
            if (nextIndex < 0) SetSnapshot(PlaybackSnapshot.Empty);
            else SetSnapshot(_snapshot with { CurrentTrack = _playlist[nextIndex], CurrentIndex = nextIndex, State = PlaybackState.Stopped, Error = null });
            return new ValueTask<int>(nextIndex);
        }).ConfigureAwait(false);
        if (next >= 0) await SelectAsync(next, cancellationToken).ConfigureAwait(false);
    }

    private async ValueTask<int> MoveAsync(bool previous, CancellationToken cancellationToken)
    {
        var index = await _commands.EnqueueAsync(() => new ValueTask<int>(
            previous ? (_playlist.CanMovePrevious ? _playlist.CurrentIndex - 1 : -1) :
                       (_playlist.CanMoveNext ? _playlist.CurrentIndex + 1 : -1))).ConfigureAwait(false);
        if (index >= 0) await SelectAsync(index, cancellationToken).ConfigureAwait(false);
        return index;
    }

    private ValueTask SetEmptyAsync(CancellationToken cancellationToken) =>
        _commands.EnqueueAsync(async () =>
        {
            InvalidateActiveSelection();
            await _output.StopAsync(cancellationToken).ConfigureAwait(false);
            SetSnapshot(PlaybackSnapshot.Empty);
        });

    private async ValueTask ReplaceCoreAsync(Playlist replacement)
    {
        _playlist = replacement;
        InvalidateActiveSelection();
        if (replacement.Count == 0)
        {
            await _output.StopAsync(CancellationToken.None).ConfigureAwait(false);
            SetSnapshot(PlaybackSnapshot.Empty);
        }
    }

    private ValueTask<SelectionRequest> BeginSelectionAsync(int index)
    {
        if (index < 0 || index >= _playlist.Count) throw new ArgumentOutOfRangeException(nameof(index));
        InvalidateActiveSelection();
        _selectionCancellation = new CancellationTokenSource();
        var generation = _snapshot.SelectionGeneration;
        var track = _playlist.Select(index).Current!;
        _playlist = _playlist.Select(index);
        SetSnapshot(new PlaybackSnapshot(PlaybackState.Loading, track, index, generation, TimeSpan.Zero, null));
        return new ValueTask<SelectionRequest>(new SelectionRequest(track, generation, _selectionCancellation.Token));
    }

    private async ValueTask<DecodedAudio> LoadAsync(Track track, CancellationToken selectionToken, CancellationToken callerToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(selectionToken, callerToken);
        await _decodeGate.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            if (_cache is not null)
            {
                var cached = await _cache.TryGetAsync(track, linked.Token).ConfigureAwait(false);
                if (cached is not null) return cached;
            }

            if (_decoder is null) throw new InvalidOperationException("Kein Decoder-Port konfiguriert.");
            var decoded = await _decoder.DecodeAsync(track, linked.Token).ConfigureAwait(false);
            if (_cache is not null) await _cache.PutAsync(track, decoded, linked.Token).ConfigureAwait(false);
            return decoded;
        }
        finally { _decodeGate.Release(); }
    }

    private async ValueTask<bool> CompleteSelectionAsync(SelectionRequest request, DecodedAudio? audio, Exception? failure)
    {
        if (_snapshot.SelectionGeneration != request.Generation) return false;
        if (failure is not null)
        {
            SetSnapshot(_snapshot with { State = PlaybackState.Faulted, Error = failure.Message });
            return false;
        }

        try
        {
            await _output.PlayAsync(request.Track, audio!, TimeSpan.Zero, request.CancellationToken).ConfigureAwait(false);
            SetSnapshot(_snapshot with { State = PlaybackState.Playing, Position = TimeSpan.Zero, Error = null });
            return true;
        }
        catch (OperationCanceledException) when (request.CancellationToken.IsCancellationRequested) { return false; }
        catch (Exception exception)
        {
            SetSnapshot(_snapshot with { State = PlaybackState.Faulted, Error = exception.Message });
            return false;
        }
    }

    private async Task PreloadAheadAsync(SelectionRequest request)
    {
        try
        {
            for (var offset = 1; offset <= 3; offset++)
            {
                var index = request.Track == _playlist.Current ? _playlist.CurrentIndex + offset : -1;
                if (index < 0 || index >= _playlist.Count || request.CancellationToken.IsCancellationRequested) return;
                await LoadAsync(_playlist[index], request.CancellationToken, CancellationToken.None).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (request.CancellationToken.IsCancellationRequested) { }
        catch { /* Preload failures are surfaced when the track is selected. */ }
    }

    private void CancelActiveSelection()
    {
        try { _selectionCancellation.Cancel(); }
        catch (ObjectDisposedException) { /* An earlier generation already released its source. */ }
    }

    private void InvalidateActiveSelection()
    {
        CancelActiveSelection();
        _snapshot = _snapshot with { SelectionGeneration = _snapshot.SelectionGeneration.Next() };
    }

    private ValueTask SetFaultAsync(Exception exception) => _commands.EnqueueAsync(() =>
    {
        SetSnapshot(_snapshot with { State = PlaybackState.Faulted, Error = exception.Message });
        return ValueTask.CompletedTask;
    });

    private void SetSnapshot(PlaybackSnapshot snapshot)
    {
        _snapshot = snapshot;
        try { SnapshotChanged?.Invoke(this, snapshot); } catch { /* Observers must not break playback. */ }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        CancelActiveSelection();
        await _commands.DisposeAsync().ConfigureAwait(false);
        _decodeGate.Dispose();
    }

    private sealed record SelectionRequest(Track Track, SelectionGeneration Generation, CancellationToken CancellationToken);
}
