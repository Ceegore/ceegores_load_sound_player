[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateRange(1, 10000)]
    [int]$Switches = 1000,
    [ValidateRange(0, 64)]
    [int]$CpuWorkers = 0,
    [ValidateRange(1, 64)]
    [int]$CpuWorkerCap = 4,
    [ValidateRange(1, 120)]
    [int]$CpuDurationSeconds = 20,
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 120,
    [switch]$SkipBuild,
    [switch]$NoCpuStress
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$processorCount = [Environment]::ProcessorCount
if ($CpuWorkers -eq 0) {
    $CpuWorkers = [Math]::Max(1, [Math]::Min($CpuWorkerCap, $processorCount - 1))
} elseif ($CpuWorkers -gt $CpuWorkerCap) {
    throw "CpuWorkers ($CpuWorkers) darf den expliziten CpuWorkerCap ($CpuWorkerCap) nicht überschreiten."
}
$testProject = Join-Path $root 'tests\ClipPlayer.Performance.Tests\ClipPlayer.Performance.Tests.csproj'
if (-not (Test-Path -LiteralPath $testProject)) { throw "Performance-Testprojekt fehlt: $testProject" }

$runId = "{0:yyyyMMdd-HHmmss}-{1}" -f [DateTime]::UtcNow, $PID
$outputDirectory = Join-Path ([IO.Path]::GetTempPath()) "ClipPlayer\stress-$runId"
$null = New-Item -ItemType Directory -Path $outputDirectory -Force
$buildOut = Join-Path $outputDirectory 'build.stdout.log'
$buildErr = Join-Path $outputDirectory 'build.stderr.log'
$testOut = Join-Path $outputDirectory 'test.stdout.log'
$testErr = Join-Path $outputDirectory 'test.stderr.log'
$trx = Join-Path $outputDirectory 'performance.trx'
$metricsPath = Join-Path $outputDirectory 'metrics.json'
$startedAt = [DateTime]::UtcNow
$testExitCode = $null
$timedOut = $false
$sacBlocked = $false
$cpuJobs = @()
$previousSwitches = $env:CLIPPLAYER_PERF_SWITCHES

function Invoke-Dotnet {
    param([string[]]$Arguments, [string]$StdOut, [string]$StdErr, [int]$Timeout)
    $quotedArguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath 'dotnet' -ArgumentList $quotedArguments -WorkingDirectory $root `
        -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -PassThru -WindowStyle Hidden
    try { $null = $process.Handle } catch { }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 500
        if ($watch.Elapsed.TotalSeconds -ge $Timeout) {
            $script:timedOut = $true
            try { $process.Kill($true) } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            break
        }
    }
    if (-not $process.HasExited) { return 124 }
    $process.Refresh()
    if ($null -eq $process.ExitCode) { return 125 }
    return [int]$process.ExitCode
}

function Start-BoundedCpuLoad {
    param([int]$Workers, [int]$Duration)
    $jobs = @()
    for ($i = 0; $i -lt $Workers; $i++) {
        $jobs += Start-Job -Name "ClipPlayerCpu-$runId-$i" -ArgumentList $Duration -ScriptBlock {
            param([int]$Seconds)
            $until = [DateTime]::UtcNow.AddSeconds($Seconds)
            $sha = [Security.Cryptography.SHA256]::Create()
            $buffer = [byte[]]::new(4096)
            try {
                while ([DateTime]::UtcNow -lt $until) {
                    [void]$sha.ComputeHash($buffer)
                }
            } finally { $sha.Dispose() }
        }
    }
    return $jobs
}

function Stop-BoundedCpuLoad {
    param([object[]]$Jobs)
    foreach ($job in $Jobs) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

try {
    if (-not $SkipBuild) {
        Write-Output 'Baue Produkt und Performance-Test mit --no-restore (WAP bleibt externes VS-Gate).'
        foreach ($project in @('src\ClipPlayer.App\ClipPlayer.App.csproj', $testProject)) {
            $buildCode = Invoke-Dotnet @('build', $project, '-c', $Configuration, '--no-restore') $buildOut $buildErr 600
            if ($buildCode -ne 0) {
                Write-Error "Build-Gate fehlgeschlagen (Exit $buildCode). Logs: $outputDirectory"
                exit $buildCode
            }
        }
    }

    if (-not $NoCpuStress) {
        Write-Output "Starte $CpuWorkers begrenzte CPU-Worker für $CpuDurationSeconds Sekunden (normale Priorität)."
        $cpuJobs = Start-BoundedCpuLoad $CpuWorkers $CpuDurationSeconds
    }
    $testStartedAt = [DateTime]::UtcNow
    $args = @('test', $testProject, '-c', $Configuration, '--no-build', '--no-restore', '--filter', 'Category=Performance', '--logger', "trx;LogFileName=$trx")
    Write-Output "Führe $Switches Rapid-Switch-/Cache-Prüfungen aus."
    $env:CLIPPLAYER_PERF_SWITCHES = $Switches.ToString([Globalization.CultureInfo]::InvariantCulture)
    $testExitCode = Invoke-Dotnet $args $testOut $testErr $TimeoutSeconds
    $stdout = if (Test-Path -LiteralPath $testOut) { Get-Content -LiteralPath $testOut -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $testErr) { Get-Content -LiteralPath $testErr -Raw } else { '' }
    $combined = "$stdout`n$stderr"
    $sacBlocked = $combined -match '0x800711C7'
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $testStartedAt.ToLocalTime() } -ErrorAction SilentlyContinue)
        if ($events | Where-Object { $_.Message -match 'ClipPlayer' }) { $sacBlocked = $true }
    } catch { }

    $status = if ($sacBlocked) { 'environment-blocked' } elseif ($testExitCode -eq 0) { 'passed' } elseif ($testExitCode -eq 3) { 'no-tests-matched' } elseif ($testExitCode -eq 124) { 'timeout' } else { 'failed' }
    $metrics = [ordered]@{
        schema = 'clipplayer.performance.v1'
        status = $status
        startedUtc = $startedAt.ToString('o')
        finishedUtc = [DateTime]::UtcNow.ToString('o')
        configuration = $Configuration
        requestedSwitches = $Switches
        cpuWorkers = if ($NoCpuStress) { 0 } else { $CpuWorkers }
        cpuWorkerCap = $CpuWorkerCap
        processorCount = $processorCount
        cpuDurationSeconds = if ($NoCpuStress) { 0 } else { $CpuDurationSeconds }
        testExitCode = $testExitCode
        sacBlocked = $sacBlocked
        outputDirectory = $outputDirectory
    }
    $metrics | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $metricsPath -Encoding utf8
    Write-Output "Performance-Gate: $status"
    Write-Output "Laufdaten (temporär): $outputDirectory"
    if ($sacBlocked) { exit 42 }
    if ($testExitCode -ne 0) { exit $testExitCode }
    exit 0
}
finally {
    if ($null -eq $previousSwitches) { Remove-Item Env:CLIPPLAYER_PERF_SWITCHES -ErrorAction SilentlyContinue }
    else { $env:CLIPPLAYER_PERF_SWITCHES = $previousSwitches }
    Stop-BoundedCpuLoad $cpuJobs
}
