function Read-State {
    param([int] $TimeoutMilliseconds = 3000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            if (Test-Path -LiteralPath $diagnostics) {
                $stream = [IO.File]::Open($diagnostics, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                    [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $json = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
                if (-not [string]::IsNullOrWhiteSpace($json)) {
                    $state = $json | ConvertFrom-Json
                    if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'CurrentIndex') { return $state }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw 'Timed out reading player diagnostics.'
}

function Read-CommandFileEvidence {
    if ([string]::IsNullOrWhiteSpace($commandPath) -or -not [IO.File]::Exists($commandPath)) {
        return '<missing>'
    }
    try {
        $stream = [IO.File]::Open($commandPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { return ([IO.StreamReader]::new($stream).ReadToEnd()).Trim() }
        finally { $stream.Dispose() }
    } catch {
        return "<unavailable: $($_.Exception.Message)>"
    }
}

function Format-StateEvidence {
    param($State)
    if ($null -eq $State) { return '<unavailable>' }
    try {
        $summary = [ordered]@{}
        foreach ($name in @(
            'CurrentIndex', 'CurrentPath', 'PlaylistCount', 'IsPaused', 'Status',
            'LastAutomationCommandId', 'LastAutomationCommandName',
            'LastAutomationCommandBeforeIndex', 'LastAutomationCommandBeforePath',
            'LastAutomationCommandBeforeIsPaused', 'LastAutomationCommandAfterIndex',
            'LastAutomationCommandAfterPath', 'LastAutomationCommandAfterIsPaused')) {
            $property = $State.PSObject.Properties[$name]
            $summary[$name] = if ($null -eq $property) { $null } else { $property.Value }
        }
        return ($summary | ConvertTo-Json -Compress -Depth 3)
    } catch {
        return "<unavailable: $($_.Exception.Message)>"
    }
}

function Get-WaitEvidence {
    param(
        [long] $ExpectedCommandId = -1,
        [AllowNull()] $BeforeState,
        [AllowNull()][string] $ExpectedCommand,
        [AllowNull()] $LastState
    )
    if ($null -eq $LastState) { try { $LastState = Read-State 250 } catch { } }
    $expectedId = if ($ExpectedCommandId -ge 0) { $ExpectedCommandId } else {
        if ($null -eq $script:lastSentCommandId) { '<unknown>' } else { $script:lastSentCommandId }
    }
    $expectedName = if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) { $ExpectedCommand } else {
        if ([string]::IsNullOrWhiteSpace($script:lastSentCommand)) { '<unknown>' } else { $script:lastSentCommand }
    }
    $evidenceBefore = $BeforeState
    if ($null -eq $evidenceBefore) {
        try { $evidenceBefore = $script:lastSentCommandBeforeState } catch { }
    }
    return "ExpectedCommandId=$expectedId ExpectedCommand=$expectedName Before=$(Format-StateEvidence $evidenceBefore) LastState=$(Format-StateEvidence $LastState) CommandFile=$(Read-CommandFileEvidence)"
}

function Test-CommandAcknowledgement {
    param($State, [long] $CommandId, [string] $CommandName)
    if ($null -eq $State) { return $false }
    $id = $State.PSObject.Properties['LastAutomationCommandId']
    $name = $State.PSObject.Properties['LastAutomationCommandName']
    return $null -ne $id -and $null -ne $name -and [long]$id.Value -eq $CommandId -and
        [string]::Equals([string]$name.Value, $CommandName, [StringComparison]::Ordinal)
}

function Test-TrackSwitchInvariant {
    param($State, [int] $Direction, [long] $CommandId = -1)
    # The dispatcher records the command boundary.  A MediaEnded callback may
    # advance the track between the harness' Read-State and command ingestion,
    # so a target derived from the harness snapshot is not authoritative.
    if ($null -eq $State -or ($Direction -ne -1 -and $Direction -ne 1)) { return $false }
    $nameProperty = $State.PSObject.Properties['LastAutomationCommandName']
    $beforeProperty = $State.PSObject.Properties['LastAutomationCommandBeforeIndex']
    $afterProperty = $State.PSObject.Properties['LastAutomationCommandAfterIndex']
    $countProperty = $State.PSObject.Properties['PlaylistCount']
    if ($null -eq $nameProperty -or $null -eq $beforeProperty -or $null -eq $afterProperty -or $null -eq $countProperty) {
        return $false
    }
    $expectedName = if ($Direction -gt 0) { 'Next' } else { 'Previous' }
    if ([string]$nameProperty.Value -ne $expectedName -or
        ($CommandId -ge 0 -and -not (Test-CommandAcknowledgement $State $CommandId $expectedName))) { return $false }
    $before = [int]$beforeProperty.Value; $after = [int]$afterProperty.Value; $count = [int]$countProperty.Value
    if ($before -lt 0 -or $before -ge $count -or $after -lt 0 -or $after -ge $count) { return $false }
    $pathsProperty = $State.PSObject.Properties['PlaylistPaths']
    $beforePath = $State.PSObject.Properties['LastAutomationCommandBeforePath']
    $afterPath = $State.PSObject.Properties['LastAutomationCommandAfterPath']
    if ($null -ne $pathsProperty -and @($pathsProperty.Value).Count -eq $count -and
        ($null -eq $beforePath -or $null -eq $afterPath -or
            -not [string]::Equals([string]$beforePath.Value, [string]@($pathsProperty.Value)[$before], [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$afterPath.Value, [string]@($pathsProperty.Value)[$after], [StringComparison]::OrdinalIgnoreCase))) {
        return $false
    }
    $target = $before + $Direction
    if ($target -lt 0 -or $target -ge $count) { return $after -eq $before }
    return $after -eq $target
}

function Test-TrackAutoplayOutcome {
    param($State, [string] $InvalidPath)
    if ($null -eq $State) { return $false }
    $targetProperty = $State.PSObject.Properties['LastAutomationCommandAfterPath']
    $startedProperty = $State.PSObject.Properties['LastAutomationCommandAfterIsPaused']
    if ($null -eq $targetProperty -or $null -eq $startedProperty) { return $false }
    $targetPath = [string]$targetProperty.Value
    $isInvalid = -not [string]::IsNullOrWhiteSpace($InvalidPath) -and
        [string]::Equals($targetPath, $InvalidPath, [StringComparison]::OrdinalIgnoreCase)
    if ($isInvalid) {
        return [bool]$State.IsPaused -and [string]$State.Status -like 'Playback error:*'
    }
    # The dispatcher captured this immediately after Select-Track.  A one-second
    # clip may legitimately finish before the external process reads the next
    # diagnostic document under CPU load, so current IsPaused is not sufficient
    # evidence.  Require both a synchronous autoplay intent and later evidence
    # of progress, completion, or automatic advancement.
    if ([bool]$startedProperty.Value) { return $false }
    if ([double]$State.PositionMilliseconds -gt 0) { return $true }
    if (@($State.CompletedPaths) -contains $targetPath -and [string]$State.Status -like 'Finished:*') { return $true }
    return -not [string]::Equals([string]$State.CurrentPath, $targetPath,
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-StateSignature {
    param($State, [string[]] $Fields)
    return (($Fields | ForEach-Object {
        $property = $State.PSObject.Properties[$_]
        $value = if ($null -eq $property) { $null } else { $property.Value }
        "$_=" + ($value | ConvertTo-Json -Compress -Depth 6)
    }) -join "`n")
}

function Ensure-PauseResumeBaseline {
    param(
        [string] $InvalidPath,
        [int] $RequiredRemainingMilliseconds = 2000
    )
    $isInvalid = {
        param($State)
        if ([string]::IsNullOrWhiteSpace([string]$State.CurrentPath)) { return $false }
        try { $path = [IO.Path]::GetFullPath([string]$State.CurrentPath) } catch { return $true }
        return [string]::Equals($path, $InvalidPath, [StringComparison]::OrdinalIgnoreCase)
    }
    $hasHeadroom = {
        param($State)
        if (& $isInvalid $State) { return $false }
        $duration = [double]$State.DurationMilliseconds
        $position = [double]$State.PositionMilliseconds
        return $duration -gt 0 -and $position -ge 0 -and
            ($duration - $position) -ge $RequiredRemainingMilliseconds -and
            [string]$State.Status -notlike 'Playback error:*' -and
            [string]$State.Status -notlike 'Finished:*'
    }
    $state = Read-State
    if (-not (& $hasHeadroom $state)) {
        $currentIndex = [int]$state.CurrentIndex
        if ($currentIndex -lt 0) { throw 'Pause/resume baseline has no current track.' }
        # Move only until the first usable long-running track.  Waiting for the
        # dispatcher boundary and its position makes this independent of a
        # short final track reaching Finished between state samples.
        while (-not (& $hasHeadroom $state) -and [int]$state.CurrentIndex -gt 0) {
            $before = $state
            $command = Send-BackgroundCommand 'Previous'
            $state = Wait-State { param($candidate)
                (Test-TrackSwitchInvariant $candidate -1 $command) -and
                    (-not [string]::Equals([string]$candidate.CurrentPath,
                            [string]$candidate.LastAutomationCommandAfterPath, [StringComparison]::OrdinalIgnoreCase) -or
                        [double]$candidate.PositionMilliseconds -gt 0 -or
                        ((& $isInvalid $candidate) -and $candidate.IsPaused -and $candidate.Status -like 'Playback error:*'))
            } 5000 'pause/resume baseline navigation' $command $before 'Previous'
        }
        # If the prefix is unusable (for example after a fixture deletion),
        # walk forward to the next valid track using the same strict boundary.
        while (-not (& $hasHeadroom $state) -and [int]$state.CurrentIndex -lt ([int]$state.PlaylistCount - 1)) {
            $before = $state
            $command = Send-BackgroundCommand 'Next'
            $state = Wait-State { param($candidate)
                (Test-TrackSwitchInvariant $candidate 1 $command) -and
                    (-not [string]::Equals([string]$candidate.CurrentPath,
                            [string]$candidate.LastAutomationCommandAfterPath, [StringComparison]::OrdinalIgnoreCase) -or
                        [double]$candidate.PositionMilliseconds -gt 0 -or
                        ((& $isInvalid $candidate) -and $candidate.IsPaused -and $candidate.Status -like 'Playback error:*'))
            } 5000 'pause/resume baseline track selection' $command $before 'Next'
        }
    }
    if (-not (& $hasHeadroom $state)) {
        throw "Pause/resume baseline has no playable track with $RequiredRemainingMilliseconds ms remaining."
    }
    if ($state.IsPaused) {
        $resume = Send-BackgroundCommand 'TogglePause'
        $state = Wait-State { param($candidate)
            (Test-CommandAcknowledgement $candidate $resume 'TogglePause') -and -not $candidate.IsPaused -and
                (& $hasHeadroom $candidate)
        } 5000 'pause/resume baseline restart'
    }
    return $state
}

function Wait-State {
    param(
        [scriptblock] $Predicate,
        [int] $TimeoutMilliseconds = 3000,
        [string] $Description = 'state change',
        [long] $ExpectedCommandId = -1,
        [AllowNull()] $BeforeState,
        [AllowNull()][string] $ExpectedCommand
    )
    $ackId = if ($ExpectedCommandId -ge 0) { $ExpectedCommandId } else { $script:lastSentCommandId }
    $ackName = if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) { $ExpectedCommand } else { $script:lastSentCommand }
    $watch = [Diagnostics.Stopwatch]::StartNew(); $lastState = $null
    do {
        if ($null -ne $script:playerProcess -and $script:playerProcess.HasExited) {
            $failureText = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
            $evidence = Get-WaitEvidence $ExpectedCommandId $BeforeState $ExpectedCommand $lastState
            throw "ClipPlayer exited while waiting for $Description. $evidence $failureText"
        }
        try { $state = Read-State 500 } catch { $state = $null }
        if ($null -ne $state) {
            $lastState = $state
            if ($null -ne $ackId -and [long]$state.LastAutomationCommandId -eq [long]$ackId -and
                -not [string]::IsNullOrWhiteSpace($ackName) -and
                -not (Test-CommandAcknowledgement $state ([long]$ackId) $ackName)) {
                throw "Player acknowledged command $ackId as '$($state.LastAutomationCommandName)', expected '$ackName'."
            }
        }
        if ($null -ne $state -and (& $Predicate $state)) { return $state }
        Start-Sleep -Milliseconds 25
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    $evidence = Get-WaitEvidence $ExpectedCommandId $BeforeState $ExpectedCommand $lastState
    throw "Player $Description did not complete within $TimeoutMilliseconds ms. $evidence"
}

function Wait-StableState {
    param(
        [scriptblock] $Predicate,
        [string[]] $Fields,
        [int] $TimeoutMilliseconds = 3000,
        [int] $StabilityMilliseconds = 100,
        [string] $Description = 'stable state',
        [long] $ExpectedCommandId = -1,
        [AllowNull()] $BeforeState,
        [AllowNull()][string] $ExpectedCommand
    )
    $ackId = if ($ExpectedCommandId -ge 0) { $ExpectedCommandId } else { $script:lastSentCommandId }
    $ackName = if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) { $ExpectedCommand } else { $script:lastSentCommand }
    $watch = [Diagnostics.Stopwatch]::StartNew(); $previous = $null; $lastState = $null
    do {
        try { $state = Read-State 500 } catch { $state = $null }
        if ($null -ne $state) {
            $lastState = $state
            if ($null -ne $ackId -and [long]$state.LastAutomationCommandId -eq [long]$ackId -and
                -not [string]::IsNullOrWhiteSpace($ackName) -and
                -not (Test-CommandAcknowledgement $state ([long]$ackId) $ackName)) {
                throw "Player acknowledged command $ackId as '$($state.LastAutomationCommandName)', expected '$ackName'."
            }
        }
        if ($null -ne $state -and (& $Predicate $state)) {
            $signature = Get-StateSignature $state $Fields
            if ($signature -eq $previous) { return $state }
            $previous = $signature
            Start-Sleep -Milliseconds $StabilityMilliseconds
        } else { $previous = $null; Start-Sleep -Milliseconds 25 }
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    $evidence = Get-WaitEvidence $ExpectedCommandId $BeforeState $ExpectedCommand $lastState
    throw "Player $Description did not become quiescent within $TimeoutMilliseconds ms. $evidence"
}

function Send-BackgroundCommand {
    param([string] $Command)
    $beforeState = $null
    try { $beforeState = Read-State 250 } catch { }
    $script:commandId++
    $payload = "$script:commandId|$Command"
    $script:lastSentCommandId = $script:commandId
    $script:lastSentCommand = $Command
    $script:lastSentCommandBeforeState = $beforeState
    $temporaryPath = "$commandPath.$PID.$script:commandId.tmp"
    $backupPath = "$commandPath.$PID.bak"
    $writeWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            [IO.File]::WriteAllText($temporaryPath, $payload)
            if ([IO.File]::Exists($commandPath)) {
                if ([IO.File]::Exists($backupPath)) { Remove-Item -LiteralPath $backupPath -Force }
                [IO.File]::Replace($temporaryPath, $commandPath, $backupPath)
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            } else { [IO.File]::Move($temporaryPath, $commandPath) }
            return $script:commandId
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 10
        } finally {
            if ([IO.File]::Exists($temporaryPath) -and $writeWatch.ElapsedMilliseconds -ge 1000) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    } while ($writeWatch.ElapsedMilliseconds -lt 1000)
    throw "Could not write background command within one second: $Command"
}

function Get-Percentile {
    param([double[]] $Values, [double] $Percentile)
    if ($Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    return $sorted[[Math]::Max(0, [Math]::Min($index, $sorted.Count - 1))]
}

function Get-ResourceGateEvaluation {
    param([object[]] $Samples, [int] $PlayerProcessId)
    $warm = @($Samples | Where-Object Phase -eq 'warm-baseline' | Select-Object -Last 1)
    $stress = @($Samples | Where-Object Phase -in @('stress', 'heartbeat', 'stress-final'))
    $violations = New-Object Collections.Generic.List[string]
    if ($warm.Count -ne 1 -or $stress.Count -eq 0) {
        $violations.Add('Warm baseline or terminal stress sample is missing.')
        return [PSCustomObject]@{ Passed = $false; Violations = $violations.ToArray() }
    }
    $baseline = $warm[0]; $terminal = $stress[-1]
    $windowSize = [Math]::Min(3, $stress.Count)
    $firstWindow = @($stress | Select-Object -First $windowSize)
    $lastWindow = @($stress | Select-Object -Last $windowSize)
    $firstHandleMean = ($firstWindow | Measure-Object Handles -Average).Average
    $lastHandleMean = ($lastWindow | Measure-Object Handles -Average).Average
    $handleGrowth = [int]$terminal.Handles - [int]$baseline.Handles
    $handleTrend = [Math]::Round($lastHandleMean - $firstHandleMean, 1)
    $workingSetGrowth = [long]$terminal.WorkingSetBytes - [long]$baseline.WorkingSetBytes
    $privateGrowth = [long]$terminal.PrivateBytes - [long]$baseline.PrivateBytes
    $maxHandles = [int](($stress + $warm | Measure-Object Handles -Maximum).Maximum)
    $maxWorkingSet = [long](($stress + $warm | Measure-Object WorkingSetBytes -Maximum).Maximum)
    $maxPrivate = [long](($stress + $warm | Measure-Object PrivateBytes -Maximum).Maximum)
    $focusIds = @($stress + $warm | ForEach-Object FocusProcessId | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $externalFocusChanged = $focusIds.Count -gt 1
    $playerTookFocus = $focusIds -contains $PlayerProcessId
    # Other applications may legitimately exchange focus while this hidden
    # soak runs. The regression is ClipPlayer acquiring focus, not user input.
    $focusChanged = $playerTookFocus
    if ($handleGrowth -gt 256) { $violations.Add("Handle growth $handleGrowth exceeds 256 from warm baseline.") }
    if ($handleTrend -gt 192) { $violations.Add("Handle trend $handleTrend exceeds 192 (last/first three-sample means).") }
    if ($maxHandles -gt 2500) { $violations.Add("Maximum handle count $maxHandles exceeds 2500.") }
    if ($workingSetGrowth -gt 100663296) { $violations.Add("Working-set growth $workingSetGrowth exceeds 96 MiB.") }
    if ($privateGrowth -gt 67108864) { $violations.Add("Private-byte growth $privateGrowth exceeds 64 MiB.") }
    if ($maxWorkingSet -gt 536870912) { $violations.Add("Maximum working set $maxWorkingSet exceeds 512 MiB.") }
    if ($maxPrivate -gt 536870912) { $violations.Add("Maximum private bytes $maxPrivate exceeds 512 MiB.") }
    if ($playerTookFocus) { $violations.Add("Background ClipPlayer process $PlayerProcessId acquired foreground focus.") }
    return [PSCustomObject]@{
        Passed = $violations.Count -eq 0; Violations = $violations.ToArray()
        WarmBaseline = $baseline; TerminalStress = $terminal
        HandleGrowth = $handleGrowth; HandleTrend = $handleTrend; MaximumHandles = $maxHandles
        WorkingSetGrowthBytes = $workingSetGrowth; PrivateBytesGrowth = $privateGrowth
        MaximumWorkingSetBytes = $maxWorkingSet; MaximumPrivateBytes = $maxPrivate
        FocusProcessIds = $focusIds; FocusChanged = $focusChanged; PlayerTookFocus = $playerTookFocus
        ExternalFocusChanged = $externalFocusChanged
        Limits = [ordered]@{ HandleGrowth = 256; HandleTrend = 192; MaximumHandles = 2500
            WorkingSetGrowthBytes = 100663296; PrivateBytesGrowth = 67108864
            MaximumWorkingSetBytes = 536870912; MaximumPrivateBytes = 536870912 }
    }
}

function Move-ToPlaylistIndex {
    param([int] $TargetIndex, [string] $Description = 'playlist navigation')
    $state = Read-State
    if ($TargetIndex -lt 0 -or $TargetIndex -ge [int]$state.PlaylistCount) {
        throw "Target index $TargetIndex is outside the playlist."
    }
    $remaining = [Math]::Max(2, [int]$state.PlaylistCount * 2)
    while ([int]$state.CurrentIndex -ne $TargetIndex -and $remaining-- -gt 0) {
        $direction = if ([int]$state.CurrentIndex -gt $TargetIndex) { -1 } else { 1 }
        $commandName = if ($direction -lt 0) { 'Previous' } else { 'Next' }
        $before = $state
        $command = Send-BackgroundCommand $commandName
        $state = Wait-State { param($candidate)
            Test-TrackSwitchInvariant $candidate $direction $command
        } 5000 $Description $command $before $commandName
    }
    if ([int]$state.CurrentIndex -ne $TargetIndex) {
        throw "Could not navigate to playlist index $TargetIndex. Last=$(Format-StateEvidence $state)"
    }
    return $state
}

function Invoke-ResumeRaceRepros {
    param([ValidateRange(1, 1000)][int] $Count, [string] $ExpectedPath)
    $before = Read-State
    $expectedIndex = -1
    for ($index = 0; $index -lt @($before.PlaylistPaths).Count; $index++) {
        if ([string]::Equals([string]$before.PlaylistPaths[$index], $ExpectedPath,
                [StringComparison]::OrdinalIgnoreCase)) { $expectedIndex = $index; break }
    }
    if ($expectedIndex -lt 0) { throw "Resume race expected path is not in the playlist: $ExpectedPath" }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $before = Move-ToPlaylistIndex $expectedIndex 'resume race track setup'
        if (-not $before.IsPaused) {
            $pause = Send-BackgroundCommand 'TogglePause'
            $before = Wait-State { param($candidate)
                (Test-CommandAcknowledgement $candidate $pause 'TogglePause') -and $candidate.IsPaused
            } 5000 'resume race pause setup' $pause $before 'TogglePause'
        }
        if ([string]::Equals([string]$before.CurrentPath, $ExpectedPath,
                [StringComparison]::OrdinalIgnoreCase) -and $before.IsPaused) { break }
    }
    if (-not [string]::Equals([string]$before.CurrentPath, $ExpectedPath,
            [StringComparison]::OrdinalIgnoreCase) -or -not $before.IsPaused) {
        throw "Could not atomically pause resume race path: $ExpectedPath"
    }
    # The preceding ended-restart fixture can leave its replacement player
    # paused before MediaOpened.  Wait for duration metadata before injecting
    # the paused-ended race; otherwise the fixture would test decode timing.
    if ([int]$before.DurationMilliseconds -le 0) {
        $before = Wait-State { param($candidate) $candidate.DurationMilliseconds -gt 0 } 5000 'resume race player open'
    }
    # Open/preload is asynchronous.  Do not sample the baseline while the
    # sibling cache is still filling or while an Open callback can still
    # consume pending playback.  The fields below are the complete resource
    # boundary checked by the race assertion, and must be stable together.
    $before = Wait-StableState { param($candidate)
        $candidate.CurrentPath -eq $ExpectedPath -and $candidate.IsPaused -and
        [int]$candidate.PendingPlaybackCount -eq 0 -and
        [int]$candidate.CachedPlayerCount -eq [int]$candidate.PlayerHandlerCount
    } @('CurrentPath', 'PendingPlaybackCount', 'CachedPlayerCount', 'CachedPaths',
        'PlayerHandlerCount', 'CompletedPaths') 5000 100 'resume race baseline resources'
    $baselineCache = [int]$before.CachedPlayerCount
    $baselineHandlers = [int]$before.PlayerHandlerCount
    $baselinePending = [int]$before.PendingPlaybackCount
    $baselineCompletedPaths = @($before.CompletedPaths)
    for ($race = 1; $race -le $Count; $race++) {
        $command = Send-BackgroundCommand 'InjectPausedEndedResumeRaceTestFixture'
        $state = Wait-State { param($candidate)
            $position = [double]$candidate.RaceFixtureAppliedPositionMilliseconds
            $expected = [double]$candidate.RaceFixtureExpectedPositionMilliseconds
            $positionOk = $expected -gt 0 -and [Math]::Abs($position - $expected) -le 150
            (Test-CommandAcknowledgement $candidate $command 'InjectPausedEndedResumeRaceTestFixture') -and
                $candidate.CurrentPath -eq $ExpectedPath -and
                -not $candidate.IsPaused -and $candidate.Status -notlike 'Playback error:*' -and $positionOk
        } 5000 "paused-ended resume race fixture #$race"
        $completedPaths = @($state.CompletedPaths)
        $hasLeak = [int]$state.PendingPlaybackCount -ne 0 -or
            [int]$state.CachedPlayerCount -ne $baselineCache -or
            [int]$state.PlayerHandlerCount -ne $baselineHandlers -or
            $completedPaths -contains $ExpectedPath
        if ($hasLeak) {
            # Build one immutable evidence object before throwing so all values
            # describe the same diagnostics document and are actionable when a
            # process-cleanup callback would otherwise overwrite diagnostics.
            $evidence = [ordered]@{
                Race = $race; ExpectedPath = $ExpectedPath
                BaselineCache = $baselineCache; BaselineHandlers = $baselineHandlers
                BaselinePending = $baselinePending; BaselineCompletedPaths = $baselineCompletedPaths
                ActualPending = [int]$state.PendingPlaybackCount
                ActualCached = [int]$state.CachedPlayerCount; ActualCachedPaths = @($state.CachedPaths)
                ActualHandlers = [int]$state.PlayerHandlerCount; ActualCompletedPaths = $completedPaths
                ActualPosition = [double]$state.PositionMilliseconds
                AppliedPosition = [double]$state.RaceFixtureAppliedPositionMilliseconds
                ExpectedPosition = [double]$state.RaceFixtureExpectedPositionMilliseconds
                CurrentPath = [string]$state.CurrentPath; IsPaused = [bool]$state.IsPaused
                Status = [string]$state.Status
            }
            throw "Resume race fixture #$race leaked pending playback, cache, handler, or completion state: $($evidence | ConvertTo-Json -Compress -Depth 6)"
        }
        if ([Math]::Abs(([double]$state.RaceFixtureAppliedPositionMilliseconds) -
                [double]$state.RaceFixtureExpectedPositionMilliseconds) -gt 150) {
            throw "Resume race fixture #$race exceeded the +/-150 ms position tolerance."
        }
    }
}
