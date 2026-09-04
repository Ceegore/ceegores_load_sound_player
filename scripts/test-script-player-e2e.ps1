[CmdletBinding()]
param(
    [ValidateRange(10, 7200)]
    [int] $DurationSeconds = 60,
    [ValidateRange(0, 16)]
    [int] $CpuWorkers = 0,
    [ValidateRange(100, 5000)]
    [int] $SwitchIntervalMilliseconds = 250,
    [switch] $ExerciseDelete,
    [switch] $KeepFixture
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$playerSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ClipPlayer.Script\ClipPlayer.ps1'
$launcherSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-script-stress-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$diagnostics = Join-Path $testRoot 'diagnostics.json'
$commandPath = Join-Path $testRoot 'command.txt'
$stderrPath = Join-Path $testRoot 'stderr.log'
$stdoutPath = Join-Path $testRoot 'stdout.log'
$resultPath = Join-Path $testRoot 'result.json'
$workerProcesses = @()
$playerProcess = $null
$latencies = New-Object Collections.Generic.List[double]
$roundTripLatencies = New-Object Collections.Generic.List[double]
$pauseChecks = 0
$commandId = 0
$startedAt = Get-Date

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

function Read-State {
    param([int] $TimeoutMilliseconds = 3000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            if (Test-Path -LiteralPath $diagnostics) {
                $json = Get-Content -LiteralPath $diagnostics -Raw
                if (-not [string]::IsNullOrWhiteSpace($json)) {
                    $state = $json | ConvertFrom-Json
                    if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'CurrentIndex') {
                        return $state
                    }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw 'Timed out reading player diagnostics.'
}

function Wait-State {
    param(
        [scriptblock] $Predicate,
        [int] $TimeoutMilliseconds = 3000,
        [string] $Description = 'state change'
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($null -ne $script:playerProcess -and $script:playerProcess.HasExited) {
            $failureText = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
            throw "ClipPlayer exited while waiting for $Description. $failureText"
        }
        try { $state = Read-State 500 } catch { $state = $null }
        if ($null -ne $state -and (& $Predicate $state)) { return $state }
        Start-Sleep -Milliseconds 25
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw "Player $Description did not complete within $TimeoutMilliseconds ms."
}

function Get-Percentile {
    param([double[]] $Values, [double] $Percentile)
    if ($Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    return $sorted[[Math]::Max(0, [Math]::Min($index, $sorted.Count - 1))]
}

function Send-BackgroundCommand {
    param([string] $Command)
    $script:commandId++
    $payload = "$script:commandId|$Command"
    $writeWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            [IO.File]::WriteAllText($commandPath, $payload)
            return $script:commandId
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 10
        }
    } while ($writeWatch.ElapsedMilliseconds -lt 1000)
    throw "Could not write background command within one second: $Command"
}

try {
    if (-not (Test-Path -LiteralPath $playerSource -PathType Leaf)) { throw "Player missing: $playerSource" }
    if (-not (Test-Path -LiteralPath $launcherSource -PathType Leaf)) { throw "Launcher missing: $launcherSource" }
    if ((Get-AuthenticodeSignature -LiteralPath $hostExe).Status -ne 'Valid') { throw 'Windows PowerShell signature is invalid.' }
    $null = New-Item -ItemType Directory -Path $testRoot
    $playerScript = Join-Path $testRoot 'ClipPlayer.ps1'
    $launcherScript = Join-Path $testRoot 'ClipPlayerLauncher.ps1'
    Copy-Item -LiteralPath $playerSource -Destination $playerScript
    Copy-Item -LiteralPath $launcherSource -Destination $launcherScript
    1..3 | ForEach-Object { New-SilentWave (Join-Path $testRoot ("clip-$_.wav")) }
    [IO.File]::WriteAllText((Join-Path $testRoot 'clip-4.wav'), 'not audio')
    New-SilentWave (Join-Path $testRoot 'clip-5.wav') 1

    $workerCommand = '$end=[DateTime]::UtcNow.AddSeconds(' + ($DurationSeconds + 30) + ');' +
        'while([DateTime]::UtcNow -lt $end){for($i=1;$i -lt 200000;$i++){$null=[Math]::Sqrt($i)}}'
    for ($worker = 0; $worker -lt $CpuWorkers; $worker++) {
        $workerProcesses += Start-Process -FilePath $hostExe -ArgumentList @(
            '-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $workerCommand
        ) -PassThru
    }

    $audioPath = Join-Path $testRoot 'clip-1.wav'
    $argumentLine = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File $launcherScript -AudioPath $audioPath -DiagnosticsPath $diagnostics -AutomationCommandPath $commandPath -BackgroundTest"
    $playerProcess = Start-Process -FilePath $hostExe -ArgumentList $argumentLine -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    try { $null = $playerProcess.Handle } catch { }

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

    $initial = Wait-State { param($state) $state.PositionMilliseconds -gt 0 -and $state.DurationMilliseconds -gt 0 } 10000 'autoplay'
    if ($initial.CachedPlayerCount -ne 4) { throw "Expected four preloaded players, got $($initial.CachedPlayerCount)." }
    $pauseCommand = Send-BackgroundCommand 'TogglePause'
    $paused = Wait-State { param($state) $state.LastAutomationCommandId -eq $pauseCommand -and $state.IsPaused } 5000 'initial pause'
    Start-Sleep -Milliseconds 500
    $pausedAgain = Read-State
    if ($pausedAgain.PositionMilliseconds -ne $paused.PositionMilliseconds) { throw 'Position advanced while paused.' }
    $resumeCommand = Send-BackgroundCommand 'TogglePause'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $resumeCommand -and -not $state.IsPaused } 5000 'initial resume'
    $pauseChecks++
    $nextCommand = Send-BackgroundCommand 'Next'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $nextCommand -and $state.CurrentIndex -eq 1 -and -not $state.IsPaused } 5000 'next command'
    $previousCommand = Send-BackgroundCommand 'Previous'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $previousCommand -and $state.CurrentIndex -eq 0 -and -not $state.IsPaused } 5000 'previous command'
    for ($targetIndex = 1; $targetIndex -le 3; $targetIndex++) {
        $endTestCommand = Send-BackgroundCommand 'Next'
        $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $endTestCommand -and $state.CurrentIndex -eq $targetIndex } 5000 'end-of-list setup'
    }
    $null = Wait-State { param($state) $state.CurrentIndex -eq 3 -and $state.IsPaused -and $state.Status -like 'Playback error:*' } 5000 'preloaded decode failure'
    $recoverCommand = Send-BackgroundCommand 'Next'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $recoverCommand -and $state.CurrentIndex -eq 4 -and -not $state.IsPaused -and $state.PositionMilliseconds -gt 0 } 5000 'decode failure recovery'
    $null = Wait-State { param($state) $state.CurrentIndex -eq 4 -and $state.IsPaused -and $state.PositionMilliseconds -eq 0 } 5000 'final-track completion'
    $restartCommand = Send-BackgroundCommand 'TogglePause'
    $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $restartCommand -and -not $state.IsPaused -and $state.PositionMilliseconds -gt 0 } 5000 'final-track restart'
    for ($targetIndex = 3; $targetIndex -ge 0; $targetIndex--) {
        $resetCommand = Send-BackgroundCommand 'Previous'
        $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $resetCommand -and $state.CurrentIndex -eq $targetIndex } 5000 'end-of-list reset'
    }
    $nonIntrusiveCommandChecks = 13

    $deletePassed = $null
    $maximumIndex = 2
    if ($ExerciseDelete) {
        $stateBeforeDelete = Read-State
        $pathBeforeDelete = [string]$stateBeforeDelete.CurrentPath
        $deleteCommand = Send-BackgroundCommand 'DeleteConfirmedTestFixture'
        $deleteWatch = [Diagnostics.Stopwatch]::StartNew()
        do {
            $deletePassed = -not (Test-Path -LiteralPath $pathBeforeDelete)
            if (-not $deletePassed) { Start-Sleep -Milliseconds 100 }
        } while (-not $deletePassed -and $deleteWatch.ElapsedMilliseconds -lt 5000)
        if (-not $deletePassed) { throw 'Delete did not move the selected fixture out of its source folder.' }
        $maximumIndex = 1
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    $switches = 0
    $direction = 1
    $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Id $playerProcess.Id -ErrorAction SilentlyContinue)) { throw 'ClipPlayer exited during stress.' }
        $before = Read-State
        if ($before.CurrentIndex -ge $maximumIndex) { $direction = -1 }
        if ($before.CurrentIndex -le 0) { $direction = 1 }
        $target = $before.CurrentIndex + $direction
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $switchCommand = Send-BackgroundCommand $(if ($direction -gt 0) { 'Next' } else { 'Previous' })
        $after = Wait-State { param($state) $state.LastAutomationCommandId -eq $switchCommand -and $state.CurrentIndex -eq $target -and $state.PositionMilliseconds -gt 0 } 5000 'track switch and autoplay'
        $watch.Stop()
        $latencies.Add([double]$after.LastAutomationCommandDurationMilliseconds)
        $roundTripLatencies.Add($watch.Elapsed.TotalMilliseconds)
        if ($after.IsPaused) { throw 'Track switch did not autoplay.' }
        if ($after.CachedPlayerCount -lt 2 -or $after.CachedPlayerCount -gt 5) { throw 'Preload window left its bounds.' }
        $switches++

        if (($switches % 100) -eq 0) {
            $periodicPause = Send-BackgroundCommand 'TogglePause'
            $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $periodicPause -and $state.IsPaused } 5000 'periodic pause'
            $periodicResume = Send-BackgroundCommand 'TogglePause'
            $null = Wait-State { param($state) $state.LastAutomationCommandId -eq $periodicResume -and -not $state.IsPaused } 5000 'periodic resume'
            $pauseChecks++
        }
        if ([DateTime]::UtcNow -ge $nextHeartbeat) {
            $load = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
            Write-Output ("Heartbeat: elapsed={0:n0}s switches={1} cpu={2}%" -f ((Get-Date)-$startedAt).TotalSeconds,$switches,$load)
            $nextHeartbeat = [DateTime]::UtcNow.AddSeconds(30)
        }
        Start-Sleep -Milliseconds $SwitchIntervalMilliseconds
    }

    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) { throw "Player stderr was not empty: $stderrText" }
    $codeIntegrityEvents = @(Get-WinEvent -FilterHashtable @{
        LogName='Microsoft-Windows-CodeIntegrity/Operational'; Id=3033,3077; StartTime=$startedAt
    } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'ClipPlayer' })
    if ($codeIntegrityEvents.Count -gt 0) { throw "Code Integrity logged $($codeIntegrityEvents.Count) related block events." }

    $switchP95 = Get-Percentile $latencies.ToArray() 0.95
    $maximumSwitch = ($latencies | Measure-Object -Maximum).Maximum
    $roundTripP95 = Get-Percentile $roundTripLatencies.ToArray() 0.95
    if ($switchP95 -gt 150 -or $maximumSwitch -gt 750 -or $roundTripP95 -gt 1500) {
        throw "Responsiveness budget exceeded (switch p95=$switchP95 ms, max=$maximumSwitch ms, roundtrip p95=$roundTripP95 ms)."
    }

    $summary = [ordered]@{
        Result = 'PASS'
        DurationSeconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        StartupMilliseconds = $startupWatch.ElapsedMilliseconds
        Switches = $switches
        NonIntrusiveCommandChecks = $nonIntrusiveCommandChecks
        PauseResumeChecks = $pauseChecks
        SwitchP50Milliseconds = [Math]::Round((Get-Percentile $latencies.ToArray() 0.50), 1)
        SwitchP95Milliseconds = [Math]::Round($switchP95, 1)
        SwitchP99Milliseconds = [Math]::Round((Get-Percentile $latencies.ToArray() 0.99), 1)
        MaximumSwitchMilliseconds = [Math]::Round($maximumSwitch, 1)
        HarnessRoundTripP95Milliseconds = [Math]::Round($roundTripP95, 1)
        InitialCachedPlayers = $initial.CachedPlayerCount
        DeletePassed = $deletePassed
        CodeIntegrityEvents = 0
        FixturePath = $testRoot
    }
    [IO.File]::WriteAllText($resultPath, ($summary | ConvertTo-Json -Depth 3))
    [PSCustomObject]$summary | Format-List
} finally {
    if ($null -ne $playerProcess -and (Get-Process -Id $playerProcess.Id -ErrorAction SilentlyContinue)) {
        try { $null = Send-BackgroundCommand 'Close'; $null = $playerProcess.WaitForExit(3000) } catch { }
        if (Get-Process -Id $playerProcess.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $playerProcess.Id -Force }
    }
    foreach ($workerProcess in $workerProcesses) {
        if (Get-Process -Id $workerProcess.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $workerProcess.Id -Force }
    }
    if (-not $KeepFixture -and (Test-Path -LiteralPath $testRoot)) {
        Get-ChildItem -LiteralPath $testRoot -File | Where-Object {
            $_.Name -like 'clip-*.wav' -or $_.Name -in @('ClipPlayer.ps1', 'ClipPlayerLauncher.ps1', 'command.txt')
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
