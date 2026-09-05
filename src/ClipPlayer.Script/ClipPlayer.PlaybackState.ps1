function Reset-PlaybackCompletion {
    param([AllowNull()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $script:completedPlayback.Clear(); return }
    $null = $script:completedPlayback.Remove($Path)
}

function Set-PlaybackCompleted {
    param([string] $Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $script:completedPlayback[$Path] = $true }
}

function Test-PlaybackCompleted {
    param([string] $Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and $script:completedPlayback.ContainsKey($Path)
}

function Close-Player {
    param([string] $Path)
    if ($script:players.ContainsKey($Path)) {
        $player = $script:players[$Path]
        $null = $script:players.Remove($Path)
        # Keep the delegates so Close can detach them before closing.  Close
        # stops the native player, but it does not retract callbacks already
        # queued on the dispatcher; Invoke-MediaEvent's ReferenceEquals guard
        # handles those callbacks after the replacement is installed.
        if ($script:playerHandlers.ContainsKey($Path)) {
            $handlers = $script:playerHandlers[$Path]
            try { $player.remove_MediaFailed($handlers.Failed) } catch { }
            try { $player.remove_MediaOpened($handlers.Opened) } catch { }
            try { $player.remove_MediaEnded($handlers.Ended) } catch { }
            $null = $script:playerHandlers.Remove($Path)
        }
        try { $player.Close() } catch { }
    }
    $null = $script:playerFailures.Remove($Path)
    $null = $script:pendingPlayback.Remove($Path)
    Reset-PlaybackCompletion $Path
}

function Invoke-MediaEvent {
    param([string] $Kind, [string] $Path, $Player, $EventArgs)
    if (-not $script:players.ContainsKey($Path) -or
        -not ([object]::ReferenceEquals($script:players[$Path], $Player))) { return }
    $isCurrent = $script:currentIndex -ge 0 -and $script:playlist[$script:currentIndex] -eq $Path
    switch ($Kind) {
        'Failed' {
            Reset-PlaybackCompletion $Path
            # Open failure is terminal for this playback intent.  Retaining
            # the queued position would make an invalid preload look like a
            # live pending playback forever and would also poison subsequent
            # quiescent resource baselines.
            $null = $script:pendingPlayback.Remove($Path)
            $message = if ($null -ne $EventArgs -and $null -ne $EventArgs.ErrorException) { $EventArgs.ErrorException.Message }
                else { 'Audio could not be opened.' }
            $script:playerFailures[$Path] = $message
            if ($isCurrent) {
                $script:isPaused = $true; Reset-PositionDisplay
                Set-Status ("Playback error: " + $message); Publish-Diagnostics
            }
        }
        'Opened' {
            Reset-PlaybackCompletion $Path
            $null = $script:playerFailures.Remove($Path)
            $pending = $null
            if ($script:pendingPlayback.ContainsKey($Path)) {
                $pending = $script:pendingPlayback[$Path]
                # MediaOpened must consume an intent even when the user
                # paused before asynchronous Open completed.  Leaving it in
                # the map permanently makes every later resource baseline
                # report a leaked pending playback.
                $null = $script:pendingPlayback.Remove($Path)
            }
            # MediaOpened is the first reliable point at which a queued seek
            # can be applied.  Apply it even when Pause won the race with
            # asynchronous Open; otherwise the next Resume silently restarts
            # at zero instead of the requested position.
            if ($isCurrent -and $null -ne $pending) {
                $Player.Position = $pending
                if ($script:raceFixtureExpectedPosition -gt 0 -and
                    [Math]::Abs($pending.TotalMilliseconds - $script:raceFixtureExpectedPosition) -le 1) {
                    $script:raceFixtureAppliedPosition = [Math]::Round($Player.Position.TotalMilliseconds)
                }
            }
            if ($isCurrent -and -not $script:isPaused) {
                $Player.Play(); Set-Status ([IO.Path]::GetFileName($Path)); Publish-Diagnostics
            }
        }
        'Ended' {
            # A MediaEnded callback can already be queued when the user
            # pauses a very short WAV.  A paused player must never advance
            # the playlist behind the user's back.
            if (-not $isCurrent -or $script:isPaused) { return }
            if ($script:currentIndex -lt ($script:playlist.Count - 1)) { Select-Track ($script:currentIndex + 1) }
            else {
                Set-PlaybackCompleted $Path
                $Player.Position = [TimeSpan]::Zero; $script:isPaused = $true
                Set-Status ("Finished: " + [IO.Path]::GetFileName($Path)); Publish-Diagnostics
            }
        }
    }
}

function Get-Player {
    param([string] $Path)
    if ($script:players.ContainsKey($Path)) { return $script:players[$Path] }

    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Volume = [double]$script:volumeSlider.Value
    $eventPath = $Path
    $eventPlayer = $player
    $eventCallback = ${function:Invoke-MediaEvent}
    $failedHandler = ({ param($sender, $failureArgs); & $eventCallback 'Failed' $eventPath $eventPlayer $failureArgs }).GetNewClosure()
    $openedHandler = ({ & $eventCallback 'Opened' $eventPath $eventPlayer $null }).GetNewClosure()
    $endedHandler = ({ & $eventCallback 'Ended' $eventPath $eventPlayer $null }).GetNewClosure()
    $player.add_MediaFailed($failedHandler)
    $player.add_MediaOpened($openedHandler)
    $player.add_MediaEnded($endedHandler)
    $script:playerHandlers[$Path] = [PSCustomObject]@{
        Failed = $failedHandler; Opened = $openedHandler; Ended = $endedHandler
    }
    $script:players[$Path] = $player
    try { $player.Open((New-Object Uri($Path, [UriKind]::Absolute))) }
    catch { Close-Player $Path; throw }
    return $player
}

function Start-PlayerPlayback {
    param([string] $Path, [TimeSpan] $Position = [TimeSpan]::Zero)
    # Open is asynchronous.  Keep the intended position until MediaOpened;
    # this also avoids setting Position on a player whose duration is unknown.
    $script:pendingPlayback[$Path] = $Position
    $player = Get-Player $Path
    $player.Volume = [double]$script:volumeSlider.Value
    if ($player.NaturalDuration.HasTimeSpan) {
        # Hashtable.Remove returns a Boolean.  Suppress it so callers always
        # receive exactly the MediaPlayer rather than a two-element array.
        $null = $script:pendingPlayback.Remove($Path)
        $player.Position = $Position
        $player.Play()
    }
    return $player
}

function Invoke-PausedEndedResumeRaceTestFixture {
    param([switch] $BackgroundTest)
    if (-not $BackgroundTest) { throw 'Test command is disabled.' }
    if ($script:currentIndex -lt 0) { throw 'Paused-ended fixture requires a current track.' }
    $path = $script:playlist[$script:currentIndex]
    if (-not $script:players.ContainsKey($path)) { throw 'Paused-ended fixture requires an open player.' }
    $oldPlayer = $script:players[$path]
    if (-not $oldPlayer.NaturalDuration.HasTimeSpan) { throw 'Paused-ended fixture requires a known duration.' }
    $duration = $oldPlayer.NaturalDuration.TimeSpan
    # Enter the same narrow danger zone in which a MediaEnded callback can
    # already be queued while Pause is processed.
    $nearEnd = [Math]::Max(0, $duration.TotalMilliseconds - 100)
    $oldPlayer.Position = [TimeSpan]::FromMilliseconds($nearEnd)
    if (-not $script:isPaused) { Toggle-Pause }
    if (-not $script:isPaused) { throw 'Paused-ended fixture did not pause.' }
    Toggle-Pause
    $newPlayer = $script:players[$path]
    if ([object]::ReferenceEquals($oldPlayer, $newPlayer) -or $script:isPaused) {
        throw 'Paused-ended fixture did not replace the player.'
    }
    # Give the replacement runway before releasing the deliberately queued old
    # callback. This keeps repeated repros deterministic without weakening the
    # production near-end replacement boundary.
    $safePosition = [TimeSpan]::FromMilliseconds([Math]::Min(1000, $duration.TotalMilliseconds / 4))
    $script:raceFixtureExpectedPosition = [Math]::Round($safePosition.TotalMilliseconds)
    $script:raceFixtureAppliedPosition = 0
    if ($script:pendingPlayback.ContainsKey($path)) { $script:pendingPlayback[$path] = $safePosition }
    else {
        $newPlayer.Position = $safePosition
        $script:raceFixtureAppliedPosition = [Math]::Round($newPlayer.Position.TotalMilliseconds)
    }
    # Simulate MediaEnded already queued by the old instance.  The callback
    # must be ignored while the replacement is still opening asynchronously.
    Invoke-MediaEvent 'Ended' $path $oldPlayer $null
    if ($script:isPaused -or (Test-PlaybackCompleted $path)) {
        throw 'A queued Ended event changed resumed playback.'
    }
}

function Toggle-Pause {
    if ($script:currentIndex -lt 0) { return }
    $path = $script:playlist[$script:currentIndex]
    if ($script:isPaused) {
        $restartCompleted = Test-PlaybackCompleted $path
        $retryFailure = $script:playerFailures.ContainsKey($path)
        $resumePosition = [TimeSpan]::Zero
        if (-not $restartCompleted -and $script:pendingPlayback.ContainsKey($path)) {
            # A second toggle can arrive before MediaOpened.  In that case
            # the player has not applied its position yet; preserve the
            # queued intent instead of observing Position == 0.
            $resumePosition = $script:pendingPlayback[$path]
        } elseif (-not $restartCompleted -and $script:players.ContainsKey($path)) {
            $resumePosition = $script:players[$path].Position
            if ($resumePosition -lt [TimeSpan]::Zero) { $resumePosition = [TimeSpan]::Zero }
        }
        $replacePlayer = $restartCompleted -or $retryFailure
        if (-not $replacePlayer -and $script:players.ContainsKey($path)) {
            $pausedPlayer = $script:players[$path]
            if ($pausedPlayer.NaturalDuration.HasTimeSpan) {
                $remaining = $pausedPlayer.NaturalDuration.TimeSpan - $resumePosition
                # Only this narrow boundary can have a pre-pause Ended event
                # queued. Normal pause/resume reuses the native player so its
                # handles remain bounded during long sessions.
                $replacePlayer = $remaining -le [TimeSpan]::FromSeconds(1)
            }
        }
        if ($replacePlayer) { Close-Player $path }
        Reset-PlaybackCompletion $path
        if ($replacePlayer -or -not $script:players.ContainsKey($path)) {
            $player = Start-PlayerPlayback $path $resumePosition
        } else {
            $player = $script:players[$path]
            if ($player.NaturalDuration.HasTimeSpan) {
                $null = $script:pendingPlayback.Remove($path)
                $player.Position = $resumePosition
                $player.Play()
            } else { $script:pendingPlayback[$path] = $resumePosition }
        }
        $script:isPaused = $false
        Set-Status $(if ($player.NaturalDuration.HasTimeSpan) { [IO.Path]::GetFileName($path) }
            else { "Opening: " + [IO.Path]::GetFileName($path) })
    } else {
        $player = Get-Player $path
        if (-not $script:pendingPlayback.ContainsKey($path)) { $player.Pause() }
        $script:isPaused = $true
        Set-Status ("Paused: " + [IO.Path]::GetFileName($path))
    }
    Publish-Diagnostics
}

function Invoke-EndedRestartRaceTestFixture {
    param([switch] $BackgroundTest)
    if (-not $BackgroundTest) { throw 'Test command is disabled.' }
    if ($script:currentIndex -lt 0 -or $script:currentIndex -ne ($script:playlist.Count - 1)) {
        throw 'Ended restart fixture requires the final playlist track.'
    }
    $path = $script:playlist[$script:currentIndex]
    $oldPlayer = $script:players[$path]
    Invoke-MediaEvent 'Ended' $path $oldPlayer $null
    if (-not $script:isPaused -or -not (Test-PlaybackCompleted $path)) { throw 'Ended fixture did not settle completion.' }
    Toggle-Pause
    $newPlayer = $script:players[$path]
    if ([object]::ReferenceEquals($oldPlayer, $newPlayer) -or $script:isPaused) {
        throw 'Completed-track restart did not replace the player.'
    }
    Invoke-MediaEvent 'Ended' $path $oldPlayer $null
    if ($script:isPaused) { throw 'A delayed old Ended event changed restarted playback.' }
    if (Test-PlaybackCompleted $path) {
        throw 'A delayed old Ended event restored stale completion state.'
    }
}

function Invoke-StaleFailedEventTestFixture {
    param([switch] $BackgroundTest)
    if (-not $BackgroundTest) { throw 'Test command is disabled.' }
    $stalePlayer = New-Object System.Windows.Media.MediaPlayer
    try {
        $stalePath = Get-CurrentPlaybackPath
        if ([string]::IsNullOrWhiteSpace($stalePath)) {
            $stalePath = Join-Path ([IO.Path]::GetTempPath()) 'clipplayer-stale-fixture.wav'
        }
        $staleArgs = [PSCustomObject]@{
            ErrorException = [InvalidOperationException]::new('stale fixture')
        }
        Invoke-MediaEvent 'Failed' $stalePath $stalePlayer $staleArgs
    } finally { $stalePlayer.Close() }
}

function Restore-PlaybackSnapshot {
    param($Snapshot)
    foreach ($cachedPath in @($script:players.Keys)) {
        $isWanted = @($Snapshot.CachedPaths | Where-Object {
            [string]::Equals($_, $cachedPath, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (-not $isWanted) { Close-Player $cachedPath }
    }
    $script:playlist = @($Snapshot.Playlist)
    $script:currentIndex = $Snapshot.Index
    $script:isPaused = [bool]$Snapshot.Paused
    Set-PlaylistDisplay $script:playlist
    foreach ($cachedPath in $Snapshot.CachedPaths) { $null = Get-Player $cachedPath }
    $script:playerFailures = @{}
    foreach ($failurePath in $Snapshot.Failures.Keys) {
        $script:playerFailures[$failurePath] = $Snapshot.Failures[$failurePath]
    }
    $script:internalSelection = $true
    $script:playlistControl.SelectedIndex = $Snapshot.SelectionIndex
    $script:internalSelection = $false
    if ($null -ne $Snapshot.FolderSelectionPath) {
        Sync-FolderSelection $Snapshot.FolderSelectionPath
    }
    if ($Snapshot.Path -and $script:players.ContainsKey($Snapshot.Path)) {
        $restoredPlayer = $script:players[$Snapshot.Path]
        $restoredPlayer.Position = $Snapshot.Position
        if ($Snapshot.Paused) { $restoredPlayer.Pause() } else { $restoredPlayer.Play() }
    }
    Update-Controls
    Publish-Diagnostics
}
