[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $AudioPath,
    [string] $DiagnosticsPath,
    [string] $AutomationCommandPath,
    [switch] $BackgroundTest,
    [switch] $SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal }
catch { }

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName Microsoft.VisualBasic

$supportedExtensions = @('.wav', '.mp3', '.flac')
$script:playlistPathBase = (Get-Location).ProviderPath
if ([string]::IsNullOrWhiteSpace($script:playlistPathBase)) { $script:playlistPathBase = (Get-Location).Path }
$playlistPathsScript = Join-Path $PSScriptRoot 'ClipPlayer.PlaylistPaths.ps1'
if (-not (Test-Path -LiteralPath $playlistPathsScript -PathType Leaf)) { throw "Playlist paths module missing: $playlistPathsScript" }
. $playlistPathsScript
$folderModeScript = Join-Path $PSScriptRoot 'ClipPlayer.FolderMode.ps1'
if (-not (Test-Path -LiteralPath $folderModeScript -PathType Leaf)) { throw "Folder mode module missing: $folderModeScript" }
. $folderModeScript
$playbackStateScript = Join-Path $PSScriptRoot 'ClipPlayer.PlaybackState.ps1'
if (-not (Test-Path -LiteralPath $playbackStateScript -PathType Leaf)) { throw "Playback state module missing: $playbackStateScript" }
. $playbackStateScript
$xamlPath = Join-Path $PSScriptRoot 'ClipPlayer.Window.xaml'
if (-not (Test-Path -LiteralPath $xamlPath -PathType Leaf)) { throw "Window markup missing: $xamlPath" }
$xaml = Get-Content -LiteralPath $xamlPath -Raw

if ($SelfTest) {
    $probeWindow = New-WindowFromXaml
    $requiredNames = @(
        'Playlist', 'OpenButton', 'PreviousButton', 'PauseButton', 'NextButton',
        'DeleteButton', 'PositionSlider', 'VolumeSlider', 'StatusText',
        'FolderModeToggle', 'FolderPanel', 'FolderView', 'FolderAddress',
        'FolderUpButton', 'FolderGoButton', 'FolderSort', 'FolderDirection'
    )
    foreach ($name in $requiredNames) {
        if ($null -eq $probeWindow.FindName($name)) { throw "Missing UI element: $name" }
    }
    if ($supportedExtensions.Count -ne 3 -or -not (Test-SupportedPath 'probe.wav')) {
        throw 'Supported file rules are invalid.'
    }
    $names = @('clip10.wav', 'clip2.wav', 'clip1.wav' | Sort-Object { Get-NaturalSortKey $_ })
    if (($names -join ',') -ne 'clip1.wav,clip2.wav,clip10.wav') { throw 'Natural file ordering is invalid.' }
    $probeWindow.Close()
    Write-Output 'SELFTEST PASS: trusted-host XAML and file rules are valid.'
    return
}

$script:window = New-WindowFromXaml
$script:playlistControl = $window.FindName('Playlist')
$script:openButton = $window.FindName('OpenButton')
$script:previousButton = $window.FindName('PreviousButton')
$script:pauseButton = $window.FindName('PauseButton')
$script:nextButton = $window.FindName('NextButton')
$script:deleteButton = $window.FindName('DeleteButton')
$script:positionSlider = $window.FindName('PositionSlider')
$script:volumeSlider = $window.FindName('VolumeSlider')
$script:positionText = $window.FindName('PositionText')
$script:durationText = $window.FindName('DurationText')
$script:statusText = $window.FindName('StatusText')
$script:playlist = @()
$script:currentIndex = -1
$script:players = @{}
$script:playerHandlers = @{}
$script:pendingPlayback = @{}
$script:raceFixtureExpectedPosition = 0
$script:raceFixtureAppliedPosition = 0
$script:playerFailures = @{}
$script:completedPlayback = @{}
$script:isPaused = $false
$script:internalSelection = $false
$script:seeking = $false
$script:diagnosticTick = 0
$script:lastAutomationCommandId = 0
$script:lastAutomationCommandDurationMilliseconds = 0
$script:lastAutomationCommandName = $null
$script:lastAutomationCommandBeforeIndex = -1
$script:lastAutomationCommandBeforePath = $null
$script:lastAutomationCommandBeforeIsPaused = $true
$script:lastAutomationCommandAfterIndex = -1
$script:lastAutomationCommandAfterPath = $null
$script:lastAutomationCommandAfterIsPaused = $true
$script:folderWindowClosed = $false
$script:initialFolderScanPath = $null; $script:initialFolderAudioPath = $null

# Automated diagnostics must exercise the same MediaPlayer path without
# unexpectedly playing a user-owned sample through the workstation speakers.
if ($BackgroundTest) { $script:volumeSlider.Value = 0 }

function Set-Status {
    param([string] $Text)
    $script:statusText.Text = $Text
}

function Reset-PositionDisplay {
    $script:seeking = $false
    $script:positionText.Text = '0:00'
    $script:durationText.Text = '0:00'
    $script:positionSlider.Value = 0
    $script:positionSlider.IsEnabled = $false
}

function Update-Controls {
    $hasCurrent = $script:currentIndex -ge 0 -and $script:currentIndex -lt $script:playlist.Count
    $script:previousButton.IsEnabled = $hasCurrent -and $script:currentIndex -gt 0
    $script:nextButton.IsEnabled = $hasCurrent -and $script:currentIndex -lt ($script:playlist.Count - 1)
    $script:pauseButton.IsEnabled = $hasCurrent
    $script:deleteButton.IsEnabled = $hasCurrent
    Update-FolderDeleteButton
}

function Set-PreloadWindow {
    if ($script:currentIndex -lt 0) { return }
    $first = [Math]::Max(0, $script:currentIndex - 1)
    $last = [Math]::Min($script:playlist.Count - 1, $script:currentIndex + 3)
    $wanted = @{}
    for ($index = $first; $index -le $last; $index++) {
        $path = $script:playlist[$index]
        $wanted[$path] = $true
        $null = Get-Player $path
    }
    # Retain already-open players while the five-entry cache has capacity.
    # Closing every entry just outside the moving window made a direction
    # change reopen native MediaPlayer resources repeatedly.
    if ($script:players.Count -gt 5) {
        $evictionCandidates = @($script:players.Keys | Where-Object { -not $wanted.ContainsKey($_) } |
            Sort-Object { [Math]::Abs([Array]::IndexOf($script:playlist, $_) - $script:currentIndex) } -Descending)
        foreach ($cachedPath in $evictionCandidates) {
            if ($script:players.Count -le 5) { break }
            Close-Player $cachedPath
        }
    }
    Publish-Diagnostics
}

function Select-Track {
    param([int] $Index)
    if ($Index -lt 0 -or $Index -ge $script:playlist.Count) { return }
    Reset-PositionDisplay

    if ($script:currentIndex -ge 0) {
        $oldPath = $script:playlist[$script:currentIndex]
        if ($script:players.ContainsKey($oldPath)) {
            $script:players[$oldPath].Pause()
            $script:players[$oldPath].Position = [TimeSpan]::Zero
        }
    }

    Reset-PlaybackCompletion
    $script:currentIndex = $Index
    $script:isPaused = $false
    $script:internalSelection = $true
    $script:playlistControl.SelectedIndex = $Index
    $script:playlistControl.ScrollIntoView($script:playlistControl.SelectedItem)
    $script:internalSelection = $false
    Set-PreloadWindow

    $path = $script:playlist[$Index]
    Set-Status ("Opening: " + [IO.Path]::GetFileName($path))
    if ($script:playerFailures.ContainsKey($path)) {
        # Navigation over a known decode failure must not allocate a fresh
        # native MediaPlayer every time. An explicit resume remains the retry.
        $script:isPaused = $true
        Set-Status ("Playback error: " + $script:playerFailures[$path])
        Sync-FolderSelection $path
        Update-Controls
        Publish-Diagnostics
        return
    }
    $player = Start-PlayerPlayback $path ([TimeSpan]::Zero)
    $player.Volume = [double]$script:volumeSlider.Value
    if ($player.NaturalDuration.HasTimeSpan) { Set-Status ([IO.Path]::GetFileName($path)) }
    Sync-FolderSelection $path
    Update-Controls
    Publish-Diagnostics
}

function Set-Playlist {
    param([string[]] $Paths, [int] $SelectedIndex = 0, [switch] $PreserveOrder, [switch] $KnownExisting)
    $requestedPath = $null
    $inputPaths = @($Paths)
    if ($SelectedIndex -ge 0 -and $SelectedIndex -lt $inputPaths.Count) {
        $requestedPath = $inputPaths[$SelectedIndex]
    }
    $validPaths = if ($KnownExisting) {
        @($inputPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-SupportedPath $_) })
    } else { @(Get-UniqueExistingPlaylistPaths $inputPaths $script:playlistPathBase $supportedExtensions) }
    $requestedFullPath = $null
    if (-not [string]::IsNullOrWhiteSpace($requestedPath)) {
        try {
            $requestedFullPath = Resolve-PlaylistPath $requestedPath $script:playlistPathBase
        } catch { $requestedFullPath = $null }
    }
    foreach ($cachedPath in @($script:players.Keys)) { Close-Player $cachedPath }
    Reset-PlaybackCompletion
    $script:currentIndex = -1; $script:isPaused = $true
    if ($PreserveOrder) { $script:playlist = @($validPaths) }
    else { $script:playlist = @($validPaths |
        Sort-Object @{ Expression = { Get-NaturalSortKey $_ } }, @{ Expression = { $_ } }) }
    Set-PlaylistDisplay $script:playlist
    if ($script:playlist.Count -eq 0) {
        Reset-PositionDisplay
        Set-Status 'No supported files found'
        Update-Controls
        return
    }
    $targetIndex = -1
    if ($null -ne $requestedFullPath) {
        for ($index = 0; $index -lt $script:playlist.Count; $index++) {
            if ([string]::Equals($script:playlist[$index], $requestedFullPath,
                    [StringComparison]::OrdinalIgnoreCase)) {
                $targetIndex = $index
                break
            }
        }
    }
    if ($targetIndex -lt 0) {
        $targetIndex = [Math]::Max(0, [Math]::Min($SelectedIndex, $script:playlist.Count - 1))
    }
    Select-Track $targetIndex
}

function Open-AudioFiles {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Open audio files'
    $dialog.Filter = 'Audio files (*.wav;*.mp3;*.flac)|*.wav;*.mp3;*.flac|All files (*.*)|*.*'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog($script:window)) { Set-Playlist $dialog.FileNames 0 }
}

function Remove-CurrentTrack {
    param([switch] $SkipConfirmation)
    if ($script:currentIndex -lt 0) { return $false }
    $path = $script:playlist[$script:currentIndex]
    if ($SkipConfirmation) {
        $diagnosticFolder = if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) { '' }
            else { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DiagnosticsPath)) }
        if (-not $BackgroundTest -or [string]::IsNullOrWhiteSpace($AutomationCommandPath) -or
            [IO.Path]::GetDirectoryName($path) -ne $diagnosticFolder -or
            [IO.Path]::GetFileName($path) -notmatch '^clip-[1-5]\.wav$') {
            throw 'Unconfirmed deletion is restricted to generated background-test fixtures.'
        }
    } else {
        $answer = [Windows.MessageBox]::Show(
            "Move '$([IO.Path]::GetFileName($path))' to the Recycle Bin?",
            'ClipPlayer', [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return $false }
    }

    $currentPlayer = if ($script:players.ContainsKey($path)) { $script:players[$path] } else { $null }
    $snapshotFailures = @{}
    foreach ($failurePath in $script:playerFailures.Keys) {
        $snapshotFailures[$failurePath] = $script:playerFailures[$failurePath]
    }
    $snapshot = [PSCustomObject]@{
        Playlist = @($script:playlist)
        Index = $script:currentIndex
        Path = $path
        Position = if ($null -eq $currentPlayer) { [TimeSpan]::Zero } else { $currentPlayer.Position }
        Paused = [bool]$script:isPaused
        CachedPaths = @($script:players.Keys)
        Failures = $snapshotFailures
        SelectionIndex = $script:playlistControl.SelectedIndex
        FolderSelectionPath = if ($null -eq $script:folderView -or $null -eq $script:folderView.SelectedItem) {
            $null
        } else { [string]$script:folderView.SelectedItem.Path }
    }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    } catch {
        Restore-PlaybackSnapshot $snapshot
        Set-Status ("Delete failed: " + $_.Exception.Message)
        Publish-Diagnostics
        return $false
    }
    Close-Player $path
    $remaining = @($script:playlist | Where-Object { $_ -ne $path })
    if ($remaining.Count -eq 0) { Set-Playlist @(); return $true }
    Set-Playlist $remaining ([Math]::Min($script:currentIndex, $remaining.Count - 1)) -PreserveOrder
    return $true
}

function Invoke-PlayerCommand {
    param([string] $Command)
    switch ($Command) {
        'Previous' { Select-Track ($script:currentIndex - 1) }
        'Next' { Select-Track ($script:currentIndex + 1) }
        'TogglePause' { Toggle-Pause }
        'Delete' { if (-not (Invoke-FolderDelete)) { Remove-CurrentTrack } }
        'DeleteConfirmedTestFixture' { Remove-CurrentTrack -SkipConfirmation }
        'InjectStaleFailedEventTestFixture' { Invoke-StaleFailedEventTestFixture -BackgroundTest:$BackgroundTest }
        'InjectEndedRestartRaceTestFixture' { Invoke-EndedRestartRaceTestFixture -BackgroundTest:$BackgroundTest }
        'InjectPausedEndedResumeRaceTestFixture' { Invoke-PausedEndedResumeRaceTestFixture -BackgroundTest:$BackgroundTest }
        'Close' { $script:window.Close() }
        default { if (-not (Invoke-FolderAutomationCommand $Command)) { throw "Unknown player command: $Command" } }
    }
}

function Read-AutomationCommand {
    if (-not $BackgroundTest -or [string]::IsNullOrWhiteSpace($AutomationCommandPath) -or
        -not (Test-Path -LiteralPath $AutomationCommandPath -PathType Leaf)) { return }
    $commandId = $null
    $commandWatch = $null
    $command = $null
    try {
        $commandStream = [IO.File]::Open($AutomationCommandPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { $raw = [IO.StreamReader]::new($commandStream).ReadToEnd() } finally { $commandStream.Dispose() }
        $separator = $raw.IndexOf('|')
        if ($separator -le 0) { return }
        $commandId = [long]::Parse($raw.Substring(0, $separator), [Globalization.CultureInfo]::InvariantCulture)
        if ($commandId -le $script:lastAutomationCommandId) { return }
        $command = $raw.Substring($separator + 1)
        # Capture the command boundary on the dispatcher, immediately before
        # invoking it.  A short track can raise MediaEnded between the
        # harness' Read-State and this tick; the harness must validate
        # Next/Previous against this atomic boundary instead of stale state.
        $script:lastAutomationCommandName = $command
        $script:lastAutomationCommandBeforeIndex = $script:currentIndex
        $script:lastAutomationCommandBeforePath = Get-CurrentPlaybackPath
        $script:lastAutomationCommandBeforeIsPaused = [bool]$script:isPaused
        $script:lastAutomationCommandAfterIndex = -1
        $script:lastAutomationCommandAfterPath = $null
        $script:lastAutomationCommandAfterIsPaused = $true
        $commandWatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-PlayerCommand $command
        $commandWatch.Stop()
        $script:lastAutomationCommandDurationMilliseconds = $commandWatch.Elapsed.TotalMilliseconds
        $script:lastAutomationCommandId = $commandId
        $script:lastAutomationCommandAfterIndex = $script:currentIndex
        $script:lastAutomationCommandAfterPath = Get-CurrentPlaybackPath
        $script:lastAutomationCommandAfterIsPaused = [bool]$script:isPaused
        Publish-Diagnostics
    } catch [IO.IOException] { return }
    catch {
        if ($null -ne $commandWatch) { $commandWatch.Stop(); $script:lastAutomationCommandDurationMilliseconds = $commandWatch.Elapsed.TotalMilliseconds }
        if ($null -ne $commandId) {
            $script:lastAutomationCommandId = $commandId
            $script:lastAutomationCommandAfterIndex = $script:currentIndex
            $script:lastAutomationCommandAfterPath = Get-CurrentPlaybackPath
            $script:lastAutomationCommandAfterIsPaused = [bool]$script:isPaused
        }
        Set-Status ("Automation error: $($_.Exception.Message) [$($_.ScriptStackTrace -replace '[\r\n]+', ' ')]")
        Publish-Diagnostics
    }
}

Initialize-FolderMode
$script:openButton.Add_Click({ Open-AudioFiles })
$script:previousButton.Add_Click({ Invoke-PlayerCommand 'Previous' })
$script:nextButton.Add_Click({ Invoke-PlayerCommand 'Next' })
$script:pauseButton.Add_Click({ Invoke-PlayerCommand 'TogglePause' })
$script:deleteButton.Add_Click({ Invoke-PlayerCommand 'Delete' })
$script:volumeSlider.Add_ValueChanged({
    foreach ($player in $script:players.Values) { $player.Volume = [double]$script:volumeSlider.Value }
})
$script:playlistControl.Add_SelectionChanged({
    if (-not $script:internalSelection -and $script:playlistControl.SelectedIndex -ge 0 -and
        $script:playlistControl.SelectedIndex -ne $script:currentIndex) {
        Select-Track $script:playlistControl.SelectedIndex
    }
})
$script:window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None) { return }
    if ($script:folderModeEnabled -and $script:folderNavigationBar.IsKeyboardFocusWithin) { return }
    switch ($eventArgs.Key) {
        ([Windows.Input.Key]::Left) { Invoke-PlayerCommand 'Previous'; $eventArgs.Handled = $true }
        ([Windows.Input.Key]::Right) { Invoke-PlayerCommand 'Next'; $eventArgs.Handled = $true }
        ([Windows.Input.Key]::Space) { Invoke-PlayerCommand 'TogglePause'; $eventArgs.Handled = $true }
        ([Windows.Input.Key]::Delete) { Invoke-PlayerCommand 'Delete'; $eventArgs.Handled = $true }
    }
})
function Complete-Seek {
    if ($script:currentIndex -ge 0) {
        $path = $script:playlist[$script:currentIndex]
        $player = Get-Player $path
        if ($player.NaturalDuration.HasTimeSpan) {
            $seconds = $player.NaturalDuration.TimeSpan.TotalSeconds * [double]$script:positionSlider.Value
            $player.Position = [TimeSpan]::FromSeconds($seconds)
        }
    }
    $script:seeking = $false
}
$script:positionSlider.Add_PreviewMouseDown({ $script:seeking = $true })
$script:positionSlider.Add_PreviewMouseUp({ Complete-Seek })
$script:positionSlider.Add_LostMouseCapture({ if ($script:seeking) { Complete-Seek } })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($(if ($BackgroundTest) { 50 } else { 200 }))
$timer.Add_Tick({
    if ($null -ne $script:initialFolderScanPath) {
        $scanPath = $script:initialFolderScanPath
        $initialAudioPath = $script:initialFolderAudioPath
        $script:initialFolderScanPath = $null
        $script:initialFolderAudioPath = $null
        Start-FolderScan $scanPath $initialAudioPath
    }
    Complete-FolderScanIfReady
    Complete-FolderSortIfReady
    Read-AutomationCommand
    if ($script:currentIndex -ge 0 -and $script:currentIndex -lt $script:playlist.Count) {
        $path = $script:playlist[$script:currentIndex]
        if ($script:players.ContainsKey($path)) {
            $player = $script:players[$path]
            $script:positionText.Text = Convert-TimeText $player.Position
            if ($player.NaturalDuration.HasTimeSpan) {
                $duration = $player.NaturalDuration.TimeSpan
                $script:durationText.Text = Convert-TimeText $duration
                $script:positionSlider.IsEnabled = $true
                if (-not $script:seeking -and $duration.TotalSeconds -gt 0) {
                    $script:positionSlider.Value = [Math]::Min(1, $player.Position.TotalSeconds / $duration.TotalSeconds)
                }
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
        $script:diagnosticTick++
        if ($BackgroundTest -or $script:diagnosticTick -ge 5) {
            $script:diagnosticTick = 0
            Publish-Diagnostics
        }
    }
})
$script:window.Add_Closed({
    $timer.Stop()
    $script:folderWindowClosed = $true
    Stop-FolderScan -Invalidate
    Stop-FolderSort -Invalidate
    foreach ($cachedPath in @($script:players.Keys)) { Close-Player $cachedPath }
    Publish-Diagnostics
})

Update-Controls
if ($BackgroundTest) {
    $script:window.ShowActivated = $false
    $script:window.ShowInTaskbar = $false
    $script:window.WindowState = [Windows.WindowState]::Minimized
}
if (-not [string]::IsNullOrWhiteSpace($AudioPath)) {
    $resolvedAudioPath = $null
    try { $resolvedAudioPath = Resolve-PlaylistPath $AudioPath $script:playlistPathBase } catch { }
    if ($null -eq $resolvedAudioPath) {
        Set-Status 'Audio file was not found.'
    }
    elseif (-not (Test-SupportedPath $resolvedAudioPath)) {
        Set-Status 'Unsupported audio format.'
    }
    elseif (-not (Test-Path -LiteralPath $resolvedAudioPath -PathType Leaf)) {
        Set-Status 'Audio file was not found.'
    }
    else {
        $fullPath = $resolvedAudioPath
        # Defer sibling enumeration so a large directory cannot delay startup.
        Set-Playlist @($fullPath) 0 -PreserveOrder
        $script:initialFolderScanPath = [IO.Path]::GetDirectoryName($fullPath)
        $script:initialFolderAudioPath = $fullPath
    }
}
else {
    Set-Status 'Ready. Open an audio file or folder.'
}
Publish-Diagnostics

$timer.Start()
$null = $script:window.ShowDialog(); Stop-AllFolderWork
