[CmdletBinding()]
param(
    [ValidateRange(10, 7200)]
    [int] $DurationSeconds = 60,
    [ValidateRange(0, 16)]
    [int] $CpuWorkers = 0,
    [ValidateRange(100, 5000)]
    [int] $SwitchIntervalMilliseconds = 250,
    [ValidateRange(0, 2147483647)]
    [int] $Seed = 17,
    [switch] $ExerciseDelete,
    [switch] $ExerciseStaleEvents,
    [ValidateRange(1, 1000)][int] $RestartRaceRepros = 1,
    [ValidateRange(0, 1000)][int] $ResumeRaceRepros = 0,
    [string] $MetricsPath,
    [switch] $KeepFixture
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
$signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue
if ($null -eq $signatureCommand) {
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    $signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue
}
if ($null -eq $signatureCommand) {
    throw 'Microsoft.PowerShell.Security did not provide Get-AuthenticodeSignature.'
}
$sourceRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ClipPlayer.Script'
$playerSource = Join-Path $sourceRoot 'ClipPlayer.ps1'; $folderModuleSource = Join-Path $sourceRoot 'ClipPlayer.FolderMode.ps1'
$playbackStateSource = Join-Path $sourceRoot 'ClipPlayer.PlaybackState.ps1'; $folderScannerSource = Join-Path $sourceRoot 'ClipPlayer.FolderScanner.ps1'
$playlistPathsSource = Join-Path $sourceRoot 'ClipPlayer.PlaylistPaths.ps1'
$launcherSource = Join-Path $sourceRoot 'ClipPlayerLauncher.ps1'; $windowSource = Join-Path $sourceRoot 'ClipPlayer.Window.xaml'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer script stress-' + [Guid]::NewGuid().ToString('N'))
$diagnostics = Join-Path $testRoot 'diagnostics.json'; $commandPath = Join-Path $testRoot 'command.txt'
$stderrPath = Join-Path $testRoot 'stderr.log'; $stdoutPath = Join-Path $testRoot 'stdout.log'; $resultPath = Join-Path $testRoot 'result.json'
$failureSnapshotPath = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-resume-race-failure-' + [Guid]::NewGuid().ToString('N') + '.json')
$workerProcesses = @(); $playerProcess = $null; $ownedProcessStarts = @{}
$latencies = New-Object Collections.Generic.List[double]; $roundTripLatencies = New-Object Collections.Generic.List[double]
$resourceSamples = New-Object Collections.Generic.List[object]
$actionCounts = @{
    Next = 0; Previous = 0; Pause = 0; Resume = 0; FolderNavigation = 0; FolderSort = 0
}
$pauseChecks = 0; $commandId = 0; $lastSentCommandId = $null; $lastSentCommand = $null
$lastSentCommandBeforeState = $null; $startedAt = Get-Date; $runSucceeded = $false; $failureMessage = $null
$random = New-Object System.Random($Seed); $lastResourceSampleAt = [DateTime]::MinValue
$initialResourceSample = $null; $finalResourceSample = $null; $resourceGate = $null; $folderScanTimeoutMilliseconds = 30000
. (Join-Path $PSScriptRoot 'test-script-player-helpers.ps1')
function Register-OwnedProcess {
    param([Diagnostics.Process] $Process)
    try {
        $null = $Process.Handle
        $Process.Refresh()
        $script:ownedProcessStarts[[int]$Process.Id] = $Process.StartTime
    } catch { }
}
function Stop-OwnedProcess {
    param([Diagnostics.Process] $Process)
    if ($null -eq $Process) { return }
    try {
        $expectedStart = $script:ownedProcessStarts[[int]$Process.Id]
        if ($null -eq $expectedStart -or $Process.HasExited) { return }
        $Process.Refresh()
        if ($Process.StartTime -ne $expectedStart) { return }
        $Process.Kill()
        $null = $Process.WaitForExit(3000)
    } catch { }
}
function Get-FocusProcessId {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused) { return [int]$focused.Current.ProcessId }
    } catch { }
    return $null
}
function Add-ResourceSample {
    param([string] $Phase)
    if ($null -eq $script:playerProcess) { return $null }
    try {
        $process = Get-Process -Id $script:playerProcess.Id -ErrorAction Stop
        $sample = [PSCustomObject]@{
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            Phase = $Phase
            ProcessId = $process.Id
            CpuMilliseconds = [Math]::Round($process.TotalProcessorTime.TotalMilliseconds, 3)
            WorkingSetBytes = [long]$process.WorkingSet64
            PrivateBytes = [long]$process.PrivateMemorySize64
            Handles = [int]$process.HandleCount
            FocusProcessId = Get-FocusProcessId
        }
        $script:resourceSamples.Add($sample)
        $script:lastResourceSampleAt = [DateTime]::UtcNow
        return $sample
    } catch { return $null }
}
function Invoke-PauseResumeCheck {
    param([string] $InvalidPath, [string] $Description = 'pause/resume')
    $null = Ensure-PauseResumeBaseline $InvalidPath
    $stateFields = @('LastAutomationCommandId', 'CurrentPath', 'IsPaused', 'Status', 'FailureMap')
    $pauseCommand = Send-BackgroundCommand 'TogglePause'
    $null = Wait-StableState { param($state) (Test-CommandAcknowledgement $state $pauseCommand 'TogglePause') -and
        $state.IsPaused } $stateFields 5000 100 "$Description pause" $pauseCommand $null 'TogglePause'
    $resumeCommand = Send-BackgroundCommand 'TogglePause'
    $null = Wait-StableState { param($state)
        $healthy = -not $state.IsPaused -and $state.PositionMilliseconds -gt 0 -and
            $state.Status -notlike 'Playback error:*' -and $state.Status -notlike 'Finished:*'
        (Test-CommandAcknowledgement $state $resumeCommand 'TogglePause') -and $healthy
    } $stateFields 5000 100 "$Description resume" $resumeCommand $null 'TogglePause'
}
function New-SilentWave {
    param([string] $Path, [int] $Seconds = 30)
    $sampleRate = 44100
    $channels = 2
    $dataBytes = $sampleRate * $channels * 2 * $Seconds
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([int]0x46464952); $writer.Write([int](36 + $dataBytes)); $writer.Write([int]0x45564157)
        $writer.Write([int]0x20746D66); $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]$channels)
        $writer.Write([int]$sampleRate); $writer.Write([int]($sampleRate * $channels * 2))
        $writer.Write([int16]($channels * 2)); $writer.Write([int16]16); $writer.Write([int]0x61746164)
        $writer.Write([int]$dataBytes); $stream.SetLength(44 + $dataBytes)
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}
try {
    if (-not (Test-Path -LiteralPath $playerSource -PathType Leaf)) { throw "Player missing: $playerSource" }
    if (-not (Test-Path -LiteralPath $folderModuleSource -PathType Leaf)) { throw "Folder module missing: $folderModuleSource" }
    if (-not (Test-Path -LiteralPath $playbackStateSource -PathType Leaf)) { throw "Playback state module missing: $playbackStateSource" }
    if (-not (Test-Path -LiteralPath $folderScannerSource -PathType Leaf)) { throw "Folder scanner module missing: $folderScannerSource" }
    if (-not (Test-Path -LiteralPath $playlistPathsSource -PathType Leaf)) { throw "Playlist paths module missing: $playlistPathsSource" }
    if (-not (Test-Path -LiteralPath $launcherSource -PathType Leaf)) { throw "Launcher missing: $launcherSource" }
    if (-not (Test-Path -LiteralPath $windowSource -PathType Leaf)) { throw "Window markup missing: $windowSource" }
    if ((Get-AuthenticodeSignature -LiteralPath $hostExe).Status -ne 'Valid') { throw 'Windows PowerShell signature is invalid.' }
    $null = New-Item -ItemType Directory -Path $testRoot
    $playerScript = Join-Path $testRoot 'ClipPlayer.ps1'
    $folderModule = Join-Path $testRoot 'ClipPlayer.FolderMode.ps1'
    $playbackState = Join-Path $testRoot 'ClipPlayer.PlaybackState.ps1'
    $folderScanner = Join-Path $testRoot 'ClipPlayer.FolderScanner.ps1'; $playlistPaths = Join-Path $testRoot 'ClipPlayer.PlaylistPaths.ps1'
    $launcherScript = Join-Path $testRoot 'ClipPlayerLauncher.ps1'
    $windowMarkup = Join-Path $testRoot 'ClipPlayer.Window.xaml'
    Copy-Item -LiteralPath $playerSource -Destination $playerScript
    Copy-Item -LiteralPath $folderModuleSource -Destination $folderModule
    Copy-Item -LiteralPath $playbackStateSource -Destination $playbackState
    Copy-Item -LiteralPath $folderScannerSource -Destination $folderScanner; Copy-Item -LiteralPath $playlistPathsSource -Destination $playlistPaths
    Copy-Item -LiteralPath $launcherSource -Destination $launcherScript
    Copy-Item -LiteralPath $windowSource -Destination $windowMarkup
    1..3 | ForEach-Object { New-SilentWave (Join-Path $testRoot ("clip-$_.wav")) }
    [IO.File]::WriteAllText((Join-Path $testRoot 'clip-4.wav'), 'not audio')
    New-SilentWave (Join-Path $testRoot 'clip-5.wav') 1
    [IO.File]::WriteAllText((Join-Path $testRoot 'ignored.txt'), 'not listed')
    $nestedRoot = Join-Path $testRoot 'folder-a'
    $null = New-Item -ItemType Directory -Path $nestedRoot
    New-SilentWave (Join-Path $nestedRoot 'nested.wav')
    $invalidFixturePath = [IO.Path]::GetFullPath((Join-Path $testRoot 'clip-4.wav'))
    $workerCommand = '$end=[DateTime]::UtcNow.AddSeconds(' + ($DurationSeconds + 30) + ');' +
        'while([DateTime]::UtcNow -lt $end){for($i=1;$i -lt 200000;$i++){$null=[Math]::Sqrt($i)}}'
    for ($worker = 0; $worker -lt $CpuWorkers; $worker++) {
        $workerProcess = Start-Process -FilePath $hostExe -ArgumentList @(
            '-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $workerCommand
        ) -PassThru
        $workerProcesses += $workerProcess
        Register-OwnedProcess $workerProcess
    }
    $audioPath = Join-Path $testRoot 'clip-1.wav'
    $argumentLine = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$launcherScript`" -AudioPath `"$audioPath`" " +
        "-DiagnosticsPath `"$diagnostics`" -AutomationCommandPath `"$commandPath`" -BackgroundTest"
    $playerProcess = Start-Process -FilePath $hostExe -ArgumentList $argumentLine -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Register-OwnedProcess $playerProcess
    try { $null = $playerProcess.Handle } catch { }
    $initialResourceSample = Add-ResourceSample 'started'
    Add-Type -AssemblyName UIAutomationClient
    $processCondition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::ProcessIdProperty, $playerProcess.Id)
    $window = $null
    $startupWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($startupWatch.ElapsedMilliseconds -lt 30000 -and $null -eq $window) {
        if (-not (Get-Process -Id $playerProcess.Id -ErrorAction SilentlyContinue)) { break }
        $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll(
            [Windows.Automation.TreeScope]::Children, $processCondition)
        $window = @($windows | Where-Object { $_.Current.Name -eq 'ClipPlayer' })[0]
        if ($null -eq $window) { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $window) { throw 'ClipPlayer did not create its WPF window within 30 seconds.' }
    $startupWatch.Stop()
    $initial = Wait-State { param($state) $state.PositionMilliseconds -gt 0 -and $state.DurationMilliseconds -gt 0 -and
        $state.PlaylistCount -eq 5 -and $state.CachedPlayerCount -eq 4 } 15000 'autoplay and deferred sibling scan'
    if ($initial.CachedPlayerCount -ne 4) { throw "Expected four preloaded players, got $($initial.CachedPlayerCount)." }
    if ($ExerciseStaleEvents) {
        $null = Wait-StableState { param($state)
            $state.PlayerFailureCount -gt 0 -and $state.FailureMap.PSObject.Properties.Name -contains $invalidFixturePath
        } @('PlayerFailureCount', 'FailureMap') 5000 100 'preloaded failure settlement'
        $staleFields = @(
            'CurrentIndex', 'PlaylistSelectedIndex', 'CurrentPath', 'PlaylistCount', 'PlaylistPaths',
            'IsPaused', 'PositionMilliseconds', 'DurationMilliseconds', 'CachedPlayerCount', 'CachedPaths',
            'PlayerFailureCount', 'FailureMap', 'Status', 'FolderMode', 'FolderPath', 'FolderScanGeneration',
            'FolderScanPending', 'FolderScanPath', 'FolderSortPending', 'FolderItemCount', 'FolderAudioCount', 'FolderSort',
            'FolderDescending', 'FolderSelectedPath', 'FolderItemNames', 'PositionText', 'DurationText',
            'PositionSliderEnabled', 'PositionSliderValue')
        $stalePause = Send-BackgroundCommand 'TogglePause'
        $staleBefore = Wait-StableState { param($state) (Test-CommandAcknowledgement $state $stalePause 'TogglePause') -and $state.IsPaused } `
            $staleFields 5000 100 'stale media event pause'
        $staleCommand = Send-BackgroundCommand 'InjectStaleFailedEventTestFixture'
        $staleState = Wait-StableState { param($state) Test-CommandAcknowledgement $state $staleCommand 'InjectStaleFailedEventTestFixture' } `
            $staleFields 5000 100 'stale media event fixture'
        if ((Get-StateSignature $staleState $staleFields) -cne (Get-StateSignature $staleBefore $staleFields)) {
            $changedFields = @($staleFields | Where-Object {
                (Get-StateSignature $staleState @($_)) -cne (Get-StateSignature $staleBefore @($_))
            })
            throw "Stale media event changed playback state fields: $($changedFields -join ',')."
        }
        $staleResume = Send-BackgroundCommand 'TogglePause'
        $null = Wait-State { param($state) (Test-CommandAcknowledgement $state $staleResume 'TogglePause') -and -not $state.IsPaused } 5000 'stale media event resume'
    }
    $folderOn = Send-BackgroundCommand 'FolderModeOn'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderOn -and $state.FolderMode -and
        -not $state.FolderScanPending -and
        $state.FolderPath -eq $testRoot -and $state.FolderItemCount -eq 6 -and $state.FolderAudioCount -eq 5 -and
        $state.FolderSelectedPath -eq (Join-Path $testRoot 'clip-1.wav') } $folderScanTimeoutMilliseconds 'folder mode activation'
    $folderOpen = Send-BackgroundCommand 'FolderOpenFirstFolder'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderOpen -and
        -not $state.FolderScanPending -and
        $state.FolderPath -eq $nestedRoot -and $state.FolderItemCount -eq 1 -and $state.FolderAudioCount -eq 1 } $folderScanTimeoutMilliseconds 'folder navigation'
    $folderUp = Send-BackgroundCommand 'FolderUp'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderUp -and
        -not $state.FolderScanPending -and $state.FolderPath -eq $testRoot } $folderScanTimeoutMilliseconds 'parent navigation'
    $folderSelect = Send-BackgroundCommand 'FolderSelectFirstFolder'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderSelect -and
        -not $state.FolderScanPending -and $state.FolderSelectedPath -eq $nestedRoot } 5000 'folder selection'
    $positionBeforeSort = (Read-State).PositionMilliseconds
    $sortDescending = Send-BackgroundCommand 'FolderSortNameDescending'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $sortDescending -and
        -not $state.FolderScanPending -and -not $state.FolderSortPending -and $state.FolderDescending -and $state.FolderItemNames[0] -eq 'folder-a' -and
        $state.FolderItemNames[1] -eq 'clip-5.wav' -and $state.CurrentIndex -eq 4 -and
        $state.PositionMilliseconds -ge $positionBeforeSort -and
        $state.FolderSelectedPath -eq $nestedRoot } 5000 'descending sort preserving playback and selection'
    $replacePlaylist = Send-BackgroundCommand 'ReplacePlaylistWithFirstAudioTest'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $replacePlaylist -and
        $state.PlaylistCount -eq 1 -and $state.CurrentIndex -eq 0 -and
        $state.CurrentPath -eq (Join-Path $testRoot 'clip-5.wav') -and
        $state.PositionMilliseconds -gt 0 } 5000 'shorter playlist replacement'
    foreach ($sortCase in @(
        [PSCustomObject]@{ Command = 'FolderSortDateCreated'; Expected = 'Date created' }
        [PSCustomObject]@{ Command = 'FolderSortDateModified'; Expected = 'Date modified' }
        [PSCustomObject]@{ Command = 'FolderSortType'; Expected = 'Type' }
        [PSCustomObject]@{ Command = 'FolderSortSize'; Expected = 'Size' })) {
        $sortCommand = Send-BackgroundCommand $sortCase.Command
        $expectedSort = $sortCase.Expected
        $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $sortCommand -and
            -not $state.FolderScanPending -and -not $state.FolderSortPending -and $state.FolderSort -eq $expectedSort -and -not $state.FolderDescending } 5000 "$expectedSort folder sort"
    }
    $sortAscending = Send-BackgroundCommand 'FolderSortNameAscending'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $sortAscending -and
        -not $state.FolderScanPending -and -not $state.FolderSortPending -and -not $state.FolderDescending -and $state.FolderItemNames[1] -eq 'clip-1.wav' } 5000 'ascending folder sort'
    $folderPlay = Send-BackgroundCommand 'FolderPlayFirstAudio'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderPlay -and
        -not $state.FolderScanPending -and $state.CurrentPath -eq (Join-Path $testRoot 'clip-1.wav') -and -not $state.IsPaused -and
        $state.PositionMilliseconds -gt 0 -and $state.CachedPlayerCount -eq 4 } 5000 'folder autoplay and preload'
    $folderOff = Send-BackgroundCommand 'FolderModeOff'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderOff -and -not $state.FolderMode } 5000 'folder mode deactivation'
    $invalidCommand = Send-BackgroundCommand 'IntentionalUnknownCommand'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $invalidCommand -and
        $state.Status -like 'Automation error:*' } 5000 'automation error acknowledgement'
    Invoke-PauseResumeCheck $invalidFixturePath 'initial'
    $actionCounts.Pause++
    $actionCounts.Resume++
    $pauseChecks++
    $nextCommand = Send-BackgroundCommand 'Next'
    $null = Wait-State { param($state) (Test-TrackSwitchInvariant $state 1 $nextCommand) -and -not $state.IsPaused } 5000 'next command' $nextCommand $null 'Next'
    $previousCommand = Send-BackgroundCommand 'Previous'
    $null = Wait-State { param($state) (Test-TrackSwitchInvariant $state -1 $previousCommand) -and -not $state.IsPaused } 5000 'previous command' $previousCommand $null 'Previous'
    $null = Move-ToPlaylistIndex 3 'end-of-list setup'
    $null = Wait-State { param($state) $state.CurrentIndex -eq 3 -and $state.IsPaused -and
        $state.Status -like 'Playback error:*' -and -not $state.PositionSliderEnabled -and
        $state.PositionText -eq '0:00' -and $state.DurationText -eq '0:00' } 5000 'preloaded decode failure UI reset'
    $recoverCommand = Send-BackgroundCommand 'Next'
    $null = Wait-State { param($state) (Test-TrackSwitchInvariant $state 1 $recoverCommand) -and
        $state.LastAutomationCommandAfterIndex -eq 4 -and -not $state.IsPaused -and $state.PositionMilliseconds -gt 0 } 5000 'decode failure recovery' $recoverCommand $null 'Next'
    $null = Wait-State { param($state) $state.CurrentIndex -eq 4 -and $state.IsPaused -and $state.PositionMilliseconds -eq 0 } 5000 'final-track completion'
    $restartCommand = Send-BackgroundCommand 'TogglePause'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $restartCommand -and -not $state.IsPaused -and $state.PositionMilliseconds -gt 0 } 5000 'final-track restart'
    if ($ExerciseStaleEvents) {
        for ($race = 1; $race -le $RestartRaceRepros; $race++) { $raceCommand = Send-BackgroundCommand 'InjectEndedRestartRaceTestFixture'
            $null = Wait-State { param($state) $target = Join-Path $testRoot 'clip-5.wav'
                $progressed = $state.PositionMilliseconds -gt 0
                $naturallyFinished = $state.IsPaused -and $state.Status -like 'Finished:*' -and $state.CompletedPaths -contains $target
                $state.LastAutomationCommandId -eq $raceCommand -and $state.CurrentIndex -eq 4 -and
                    -not $state.LastAutomationCommandAfterIsPaused -and ($progressed -or $naturallyFinished)
            } 5000 "ended restart race fixture #$race" }
    }
    if ($ResumeRaceRepros -gt 0) { Invoke-ResumeRaceRepros $ResumeRaceRepros (Join-Path $testRoot 'clip-1.wav') }
    $null = Move-ToPlaylistIndex 0 'end-of-list reset'
    $nonIntrusiveCommandChecks = 28
    $deletePassed = $null
    if ($ExerciseDelete) {
        $folderDeleteMode = Send-BackgroundCommand 'FolderModeOn'
        $deleteSetup = Wait-State { param($state) (Test-CommandAcknowledgement $state $folderDeleteMode 'FolderModeOn') -and
            $state.FolderMode -and -not $state.FolderScanPending -and
            $state.FolderSelectedPath -eq $state.LastAutomationCommandBeforePath } $folderScanTimeoutMilliseconds 'folder delete setup'
        $deleteCommand = Send-BackgroundCommand 'FolderDeleteSelectedTestFixture'
        $deleteState = Wait-State { param($state) (Test-CommandAcknowledgement $state $deleteCommand 'FolderDeleteSelectedTestFixture') -and
            $state.FolderMode -and -not $state.FolderScanPending -and $state.FolderAudioCount -eq 4 } $folderScanTimeoutMilliseconds 'folder delete refresh'
        $deletedPath = [string]$deleteState.LastAutomationCommandBeforePath
        $deletePassed = -not [string]::IsNullOrWhiteSpace($deletedPath) -and -not (Test-Path -LiteralPath $deletedPath)
        if (-not $deletePassed) { throw 'Delete did not move the selected fixture out of its source folder.' }
        if ($deleteState.PlaylistCount -lt 4) {
            throw "Delete unexpectedly reduced the active playlist to $($deleteState.PlaylistCount) tracks."
        }
        $folderDeleteOff = Send-BackgroundCommand 'FolderModeOff'
        $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $folderDeleteOff -and
            -not $state.FolderMode } 5000 'folder delete teardown'
    }
    $null = Add-ResourceSample 'warm-baseline'
    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    $switches = 0
    $direction = 1
    $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Id $playerProcess.Id -ErrorAction SilentlyContinue)) { throw 'ClipPlayer exited during stress.' }
        $before = Read-State
        $playlistCount = [int]$before.PlaylistCount
        if ($playlistCount -lt 2) { throw "Playlist unexpectedly contains fewer than two tracks after delete (count=$playlistCount)." }
        $maximumIndex = $playlistCount - 1
        if ($before.CurrentIndex -ge $maximumIndex) { $direction = -1 }
        if ($before.CurrentIndex -le 0) { $direction = 1 }
        $actionRoll = $random.Next(100)
        if ($actionRoll -lt 7) {
            $randomFolderOn = Send-BackgroundCommand 'FolderModeOn'
        $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $randomFolderOn -and $state.FolderMode -and
            -not $state.FolderScanPending -and $state.FolderItemCount -gt 0 } $folderScanTimeoutMilliseconds 'random folder navigation'
            $randomSort = if ($random.Next(2) -eq 0) { 'FolderSortNameAscending' } else { 'FolderSortNameDescending' }
            $randomSortId = Send-BackgroundCommand $randomSort
            $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $randomSortId -and $state.FolderMode -and
                -not $state.FolderScanPending -and -not $state.FolderSortPending -and $state.FolderItemCount -gt 0 } $folderScanTimeoutMilliseconds 'random folder sort'
            $randomFolderOff = Send-BackgroundCommand 'FolderModeOff'
            $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $randomFolderOff -and -not $state.FolderMode } $folderScanTimeoutMilliseconds 'random folder teardown'
            $actionCounts.FolderNavigation++
            $actionCounts.FolderSort++
            continue
        }
        if ($actionRoll -ge 82 -and $actionRoll -lt 92) {
            Invoke-PauseResumeCheck $invalidFixturePath 'random'
            $actionCounts.Pause++
            $actionCounts.Resume++
            $pauseChecks++
            continue
        }
        $direction = if ($random.Next(2) -eq 0) { -1 } else { 1 }
        if ($before.CurrentIndex -ge $maximumIndex) { $direction = -1 }
        if ($before.CurrentIndex -le 0) { $direction = 1 }
        $commandName = if ($direction -gt 0) { 'Next' } else { 'Previous' }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $switchCommand = Send-BackgroundCommand $commandName
        $after = Wait-State { param($state) (Test-TrackSwitchInvariant $state $direction $switchCommand) -and
            (Test-TrackAutoplayOutcome $state $invalidFixturePath) } 5000 'track switch and autoplay' `
            $switchCommand $before $commandName
        $watch.Stop()
        $latencies.Add([double]$after.LastAutomationCommandDurationMilliseconds)
        $roundTripLatencies.Add($watch.Elapsed.TotalMilliseconds)
        if (-not (Test-TrackAutoplayOutcome $after $invalidFixturePath)) { throw 'Track switch did not autoplay.' }
        if ($after.CachedPlayerCount -lt 2 -or $after.CachedPlayerCount -gt 5) { throw 'Preload window left its bounds.' }
        $switches++
        if ($direction -gt 0) { $actionCounts.Next++ } else { $actionCounts.Previous++ }
        if ([DateTime]::UtcNow -ge $lastResourceSampleAt.AddSeconds(5)) { $null = Add-ResourceSample 'stress' }
        if (($switches % 100) -eq 0) {
            Invoke-PauseResumeCheck $invalidFixturePath 'periodic'
            $pauseChecks++
        }
        if ([DateTime]::UtcNow -ge $nextHeartbeat) {
            $sample = Add-ResourceSample 'heartbeat'
            Write-Output ("Heartbeat: elapsed={0:n0}s switches={1} processCpuMs={2}" -f ((Get-Date)-$startedAt).TotalSeconds,$switches,$sample.CpuMilliseconds)
            $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(30)
        }
        Start-Sleep -Milliseconds $SwitchIntervalMilliseconds
    }
    $null = Add-ResourceSample 'stress-final'
    $resourceGate = Get-ResourceGateEvaluation $resourceSamples.ToArray() $playerProcess.Id
    $clearCommand = Send-BackgroundCommand 'ClearPlaylistTest'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $clearCommand -and
        $state.CurrentIndex -eq -1 -and $state.CachedPlayerCount -eq 0 -and
        -not $state.PositionSliderEnabled -and $state.PositionText -eq '0:00' -and
        $state.DurationText -eq '0:00' } 5000 'empty playlist UI reset'
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) { throw "Player stderr was not empty: $stderrText" }
    $codeIntegrityEvents = @(Get-WinEvent -FilterHashtable @{
        LogName='Microsoft-Windows-CodeIntegrity/Operational'; Id=3033,3077; StartTime=$startedAt
    } -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -eq $playerProcess.Id })
    if ($codeIntegrityEvents.Count -gt 0) { throw "Code Integrity logged $($codeIntegrityEvents.Count) related block events." }
    $finalResourceSample = Add-ResourceSample 'finished'
    if ($null -eq $finalResourceSample -or $finalResourceSample.Phase -ne 'finished') { throw 'No final CPU/resource sample was captured.' }
    $switchP95 = Get-Percentile $latencies.ToArray() 0.95
    $maximumSwitch = ($latencies | Measure-Object -Maximum).Maximum
    $switchP50 = Get-Percentile $latencies.ToArray() 0.50
    $switchP99 = Get-Percentile $latencies.ToArray() 0.99
    $roundTripP50 = Get-Percentile $roundTripLatencies.ToArray() 0.50
    $roundTripP95 = Get-Percentile $roundTripLatencies.ToArray() 0.95
    $roundTripP99 = Get-Percentile $roundTripLatencies.ToArray() 0.99
    $roundTripMaximum = ($roundTripLatencies | Measure-Object -Maximum).Maximum
    if ($switchP95 -gt 150 -or $maximumSwitch -gt 750 -or $roundTripP95 -gt 1500) {
        throw "Responsiveness budget exceeded (switch p95=$switchP95 ms, max=$maximumSwitch ms, roundtrip p95=$roundTripP95 ms)."
    }
    $cpuPercent = $null
    if ($null -ne $initialResourceSample -and $null -ne $finalResourceSample) {
        $wallMilliseconds = (([DateTime]::Parse($finalResourceSample.TimestampUtc).ToUniversalTime()) -
            ([DateTime]::Parse($initialResourceSample.TimestampUtc).ToUniversalTime())).TotalMilliseconds
        if ($wallMilliseconds -gt 0) {
            $cpuPercent = [Math]::Round((($finalResourceSample.CpuMilliseconds - $initialResourceSample.CpuMilliseconds) /
                $wallMilliseconds) * 100, 2)
        }
    }
    $finalPlaylistCount = (Read-State).PlaylistCount
    $summary = [ordered]@{
        Result = if ($resourceGate.Passed) { 'PASS' } else { 'FAIL' }
        Seed = $Seed
        DurationSeconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        StartupMilliseconds = $startupWatch.ElapsedMilliseconds
        Switches = $switches
        NonIntrusiveCommandChecks = $nonIntrusiveCommandChecks
        PauseResumeChecks = $pauseChecks
        SwitchP50Milliseconds = [Math]::Round($switchP50, 1)
        SwitchP95Milliseconds = [Math]::Round($switchP95, 1)
        SwitchP99Milliseconds = [Math]::Round($switchP99, 1)
        MaximumSwitchMilliseconds = [Math]::Round($maximumSwitch, 1)
        HarnessRoundTripP50Milliseconds = [Math]::Round($roundTripP50, 1)
        HarnessRoundTripP95Milliseconds = [Math]::Round($roundTripP95, 1)
        HarnessRoundTripP99Milliseconds = [Math]::Round($roundTripP99, 1)
        HarnessRoundTripMaximumMilliseconds = [Math]::Round($roundTripMaximum, 1)
        ActualTrackSwitches = $switches
        ActionCounts = $actionCounts
        InitialCachedPlayers = $initial.CachedPlayerCount
        FinalPlaylistCount = $finalPlaylistCount
        DeletePassed = $deletePassed; RestartRaceRepros = if ($ExerciseStaleEvents) { $RestartRaceRepros } else { 0 }
        ResumeRaceRepros = $ResumeRaceRepros
        CodeIntegrityEvents = $codeIntegrityEvents.Count
        CodeIntegrityDelta = [ordered]@{ BaselineUtc = $startedAt.ToUniversalTime().ToString('o'); AddedBlockEvents = $codeIntegrityEvents.Count; EventIds = @($codeIntegrityEvents | ForEach-Object Id) }
        ProcessCpuPercent = $cpuPercent
        ProcessResourceSamples = $resourceSamples.ToArray()
        InitialResource = $initialResourceSample
        FinalResource = $finalResourceSample
        ResourceGate = $resourceGate
        FocusProcessIds = $resourceGate.FocusProcessIds
        FocusChanged = $resourceGate.FocusChanged
        ExternalFocusProcessIds = @($resourceSamples | ForEach-Object FocusProcessId | Where-Object { $null -ne $_ -and $_ -ne $playerProcess.Id } | Select-Object -Unique)
        FixturePath = $testRoot
    }
    $null = Send-BackgroundCommand 'Close'
    if (-not $playerProcess.WaitForExit(5000)) { throw 'Player did not close gracefully within 5 seconds.' }
    $playerProcess.WaitForExit(); $playerProcess.Refresh()
    if ($playerProcess.ExitCode -ne 0) { throw "Player exited with code $($playerProcess.ExitCode)." }
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) { throw "Player stderr was not empty after close: $stderrText" }
    [IO.File]::WriteAllText($resultPath, ($summary | ConvertTo-Json -Depth 3))
    if (-not [string]::IsNullOrWhiteSpace($MetricsPath)) {
        $metricsParent = Split-Path -Parent ([IO.Path]::GetFullPath($MetricsPath))
        if (-not (Test-Path -LiteralPath $metricsParent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $metricsParent -Force
        }
        Copy-Item -LiteralPath $resultPath -Destination $MetricsPath -Force
    }
    if (-not $resourceGate.Passed) {
        throw "Resource/focus gate failed: $($resourceGate.Violations -join ' ') Metrics=$MetricsPath"
    }
    [PSCustomObject]$summary | Format-List
    $runSucceeded = $true
} catch {
    $failureMessage = $_.Exception.ToString()
    throw "$failureMessage FailureSnapshot=$failureSnapshotPath"
} finally {
    if (-not $runSucceeded) {
        try {
            $diagnosticState = $null
            if (Test-Path -LiteralPath $diagnostics -PathType Leaf) {
                $diagnosticState = Get-Content -LiteralPath $diagnostics -Raw | ConvertFrom-Json
            }
            $failureSnapshot = [ordered]@{ CapturedUtc = [DateTime]::UtcNow.ToString('o'); Error = $failureMessage
                FixturePath = $testRoot; DiagnosticsPath = $diagnostics; State = $diagnosticState }
            [IO.File]::WriteAllText($failureSnapshotPath, ($failureSnapshot | ConvertTo-Json -Depth 8))
            Write-Output "Failure snapshot: $failureSnapshotPath"
        } catch {
            Write-Warning "Could not persist failure snapshot $failureSnapshotPath`: $($_.Exception.Message)"
        }
    }
    if ($null -ne $playerProcess -and -not $playerProcess.HasExited) {
        try { $null = Send-BackgroundCommand 'Close'; $null = $playerProcess.WaitForExit(3000) } catch { }
        if (-not $playerProcess.HasExited) { Stop-OwnedProcess $playerProcess }
    }
    foreach ($workerProcess in $workerProcesses) { Stop-OwnedProcess $workerProcess }
    if ($runSucceeded -and -not $KeepFixture -and (Test-Path -LiteralPath $testRoot)) {
        $resolvedFixture = [IO.Path]::GetFullPath($testRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedFixture) -like 'ClipPlayer script stress-*') {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
        }
    }
}
