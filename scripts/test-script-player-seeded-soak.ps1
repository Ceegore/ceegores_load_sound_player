[CmdletBinding()]
param(
    [ValidateRange(900, 7200)]
    [int] $DurationSeconds = 900,
    [ValidateRange(100, 5000)]
    [int] $SwitchIntervalMilliseconds = 100,
    [ValidateRange(0, 16)]
    [int] $CpuWorkers = 0,
    [ValidateRange(1, 1000)]
    [int] $RestartRaceRepros = 20,
    [ValidateRange(0, 1000)]
    [int] $ResumeRaceRepros = 50,
    [int[]] $Seeds = @(17, 2718, 65537),
    [ValidateRange(1, 64)]
    [int] $TimeoutPaddingSeconds = 180,
    [string] $SummaryPath,
    [switch] $KeepArtifacts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$e2e = Join-Path $PSScriptRoot 'test-script-player-e2e.ps1'
if (-not (Test-Path -LiteralPath $e2e -PathType Leaf)) { throw "E2E script missing: $e2e" }
$evidenceHelpers = Join-Path $PSScriptRoot 'seeded-soak-evidence.ps1'
if (-not (Test-Path -LiteralPath $evidenceHelpers -PathType Leaf)) { throw "Evidence helpers missing: $evidenceHelpers" }
. $evidenceHelpers
if ($Seeds.Count -ne 3 -or @($Seeds | Select-Object -Unique).Count -ne 3) {
    throw 'Seeded soak requires exactly three distinct seeds.'
}

$runId = [Guid]::NewGuid().ToString('N')
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer seeded-soak-' + $runId)
$summaryPath = Resolve-SeededSoakSummaryPath $runRoot $root $SummaryPath $runId -KeepArtifacts:$KeepArtifacts
$null = New-Item -ItemType Directory -Path $runRoot -Force
$runs = New-Object Collections.Generic.List[object]

function Invoke-SeedRun {
    param([int] $Seed)
    $prefix = Join-Path $runRoot ('seed-' + $Seed)
    $stdout = $prefix + '.stdout.log'; $stderr = $prefix + '.stderr.log'; $metricsPath = $prefix + '.json'
    $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + $e2e + '"'),
        '-DurationSeconds', $DurationSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-SwitchIntervalMilliseconds', $SwitchIntervalMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-CpuWorkers', $CpuWorkers.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-Seed', $Seed.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-RestartRaceRepros', $RestartRaceRepros.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-ResumeRaceRepros', $ResumeRaceRepros.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-ExerciseDelete', '-ExerciseStaleEvents', '-MetricsPath', ('"' + $metricsPath + '"'))
    $argumentString = $arguments -join ' '
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentString -WorkingDirectory $root `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    try { $null = $process.Handle } catch { }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timeout = $DurationSeconds + $TimeoutPaddingSeconds
    while (-not $process.HasExited -and $watch.Elapsed.TotalSeconds -lt $timeout) { Start-Sleep -Milliseconds 500 }
    if (-not $process.HasExited) {
        & taskkill.exe /PID $process.Id /T /F *> $null
        try { $null = $process.WaitForExit(5000) } catch { }
        return [PSCustomObject]@{ seed = $Seed; status = 'timeout'; exitCode = 124; metrics = $null; stdout = $stdout; stderr = $stderr }
    }
    # HasExited alone does not guarantee that Windows PowerShell has populated
    # Process.ExitCode.  Synchronize the native process handle before gating;
    # otherwise a successful run can compare as $null here yet serialize as 0.
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = $process.ExitCode
    $stdoutText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
    $text = "$stdoutText`n$stderrText"
    $sac = $text -match '0x800711C7|Code Integrity logged|SAC'
    $metrics = $null
    if (Test-Path -LiteralPath $metricsPath) {
        try { $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json } catch { }
    }
    $status = if ($sac) { 'environment-blocked' } elseif ($exitCode -eq 0 -and $null -ne $metrics -and
        [string]$metrics.Result -eq 'PASS' -and [int]$metrics.Seed -eq $Seed -and
        [double]$metrics.DurationSeconds -ge $DurationSeconds -and [int]$metrics.ActualTrackSwitches -gt 0 -and
        [int]$metrics.RestartRaceRepros -eq $RestartRaceRepros -and
        [int]$metrics.ResumeRaceRepros -eq $ResumeRaceRepros -and
        [int]$metrics.CodeIntegrityEvents -eq 0 -and $null -ne $metrics.FinalResource -and
        $null -ne $metrics.ResourceGate -and [bool]$metrics.ResourceGate.Passed -and
        -not [bool]$metrics.FocusChanged) { 'passed' } else { 'failed' }
    [PSCustomObject]@{ seed = $Seed; status = $status; exitCode = [int]$exitCode; metrics = $metrics; stdout = $stdout; stderr = $stderr }
}

try {
    foreach ($seed in $Seeds) {
        Write-Output "Seeded soak: seed=$seed duration=${DurationSeconds}s"
        $runs.Add((Invoke-SeedRun $seed))
    }
    $status = if (@($runs | Where-Object status -eq 'environment-blocked').Count -gt 0) {
        'environment-blocked'
    } elseif (@($runs | Where-Object status -ne 'passed').Count -gt 0) { 'failed' } else { 'passed' }
    $summary = [ordered]@{
        schema = 'clipplayer.seeded-soak.v1'; status = $status; requiredDurationSeconds = $DurationSeconds
        cpuWorkers = $CpuWorkers
        requiredRestartRaceRepros = $RestartRaceRepros; requiredResumeRaceRepros = $ResumeRaceRepros
        seeds = @($Seeds); runs = @($runs | ForEach-Object {
            $diagnostics = if ($_.status -eq 'passed') { $null } else {
                [ordered]@{
                    stdoutTail = Get-SeededSoakDiagnosticTail $_.stdout
                    stderrTail = Get-SeededSoakDiagnosticTail $_.stderr
                }
            }
            [ordered]@{
                seed = $_.seed; status = $_.status; exitCode = $_.exitCode
                metrics = $_.metrics; diagnostics = $diagnostics
            }
        }); outputDirectory = if ($KeepArtifacts) { $runRoot } else { $null }
        artifactsRetained = [bool]$KeepArtifacts; summaryPath = $summaryPath
    }
    $summaryParent = Split-Path -Parent $summaryPath
    if (-not (Test-Path -LiteralPath $summaryParent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $summaryParent -Force
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    Write-Output "Seeded soak: $status; evidence=$summaryPath"
    if ($status -eq 'environment-blocked') { exit 42 }
    if ($status -ne 'passed') { exit 1 }
    exit 0
}
finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $runRoot)) {
        $resolved = [IO.Path]::GetFullPath($runRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved) -like 'ClipPlayer seeded-soak-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
