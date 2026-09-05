[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateRange(1, 10000)]
    [int]$Switches = 1000,
    [ValidateRange(0, 2147483647)]
    [int]$Seed = 17,
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
$processSamples = New-Object Collections.Generic.List[object]
$previousSwitches = $env:CLIPPLAYER_PERF_SWITCHES
$previousSeed = $env:CLIPPLAYER_PERF_SEED
$previousMetrics = $env:CLIPPLAYER_PERF_METRICS_PATH

function Add-ProcessSample {
    param([Diagnostics.Process]$Process, [string]$Phase)
    try {
        # Working-set/private/handle counters collapse to zero after exit.
        # Preserve the last live sample instead of publishing false cleanup.
        if ($Process.HasExited) { return }
        $Process.Refresh()
        $null = $script:processSamples.Add([PSCustomObject]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            phase = $Phase
            processId = $Process.Id
            cpuMilliseconds = [Math]::Round($Process.TotalProcessorTime.TotalMilliseconds, 3)
            workingSetBytes = [long]$Process.WorkingSet64
            privateBytes = [long]$Process.PrivateMemorySize64
            handles = [int]$Process.HandleCount
        })
    } catch { }
}

function Invoke-Dotnet {
    param([string[]]$Arguments, [string]$StdOut, [string]$StdErr, [int]$Timeout)
    $quotedArguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath 'dotnet' -ArgumentList $quotedArguments -WorkingDirectory $root `
        -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr -PassThru -WindowStyle Hidden
    try { $null = $process.Handle } catch { }
    Add-ProcessSample $process 'started'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 500
        Add-ProcessSample $process 'running'
        if ($watch.Elapsed.TotalSeconds -ge $Timeout) {
            $script:timedOut = $true
            try { $process.Kill($true) } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            break
        }
    }
    if ($script:timedOut) {
        try { $null = $process.WaitForExit(5000) } catch { }
        return 124
    }
    if (-not $process.HasExited) { return 124 }
    $process.WaitForExit()
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
    $processSamples.Clear()
    $testStartedAt = [DateTime]::UtcNow
    $args = @('test', $testProject, '-c', $Configuration, '--no-build', '--no-restore', '--filter', 'Category=Performance', '--logger', "trx;LogFileName=$trx")
    Write-Output "Führe $Switches Rapid-Switch-/Cache-Prüfungen mit Seed $Seed aus."
    $env:CLIPPLAYER_PERF_SWITCHES = $Switches.ToString([Globalization.CultureInfo]::InvariantCulture)
    $env:CLIPPLAYER_PERF_SEED = $Seed.ToString([Globalization.CultureInfo]::InvariantCulture)
    $env:CLIPPLAYER_PERF_METRICS_PATH = Join-Path $outputDirectory 'test-metrics.json'
    $testExitCode = [int](@(Invoke-Dotnet $args $testOut $testErr $TimeoutSeconds)[-1])
    $stdout = if (Test-Path -LiteralPath $testOut) { Get-Content -LiteralPath $testOut -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $testErr) { Get-Content -LiteralPath $testErr -Raw } else { '' }
    $combined = "$stdout`n$stderr"
    $testMetrics = $null
    if (Test-Path -LiteralPath $env:CLIPPLAYER_PERF_METRICS_PATH) {
        try { $testMetrics = Get-Content -LiteralPath $env:CLIPPLAYER_PERF_METRICS_PATH -Raw | ConvertFrom-Json } catch { }
    }
    $sacBlocked = $combined -match '0x800711C7'
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $testStartedAt.ToLocalTime() } -ErrorAction SilentlyContinue)
        if ($events | Where-Object { $_.Message -match 'ClipPlayer' }) { $sacBlocked = $true }
    } catch { }

    $metricNames = @('seed', 'actualSwitches', 'switchP50Milliseconds', 'switchP95Milliseconds', 'switchP99Milliseconds', 'switchMaximumMilliseconds')
    $metricsValid = $null -ne $testMetrics -and @($metricNames | Where-Object {
        $testMetrics.PSObject.Properties.Name -notcontains $_
    }).Count -eq 0
    if ($metricsValid) {
        $percentiles = @($metricNames[2..5] | ForEach-Object { [double]$testMetrics.$_ })
        $metricsValid = [int]$testMetrics.seed -eq $Seed -and [int]$testMetrics.actualSwitches -eq $Switches -and
            @($percentiles | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) -or $_ -lt 0 }).Count -eq 0
    }
    Write-Verbose ("testExitCode={0} ({1}), sacBlocked={2} ({3}), testMetrics={4}, metricsValid={5}" -f $testExitCode, $testExitCode.GetType().FullName, $sacBlocked, $sacBlocked.GetType().FullName, ($null -eq $testMetrics), $metricsValid)
    $finalSample = @($processSamples | Select-Object -Last 1)
    $finalSampleValid = $finalSample.Count -eq 1 -and $finalSample[0].workingSetBytes -gt 0 -and
        $finalSample[0].privateBytes -gt 0 -and $finalSample[0].handles -gt 0 -and
        $finalSample[0].cpuMilliseconds -ge $processSamples[0].cpuMilliseconds
    $status = if ([bool]$sacBlocked) { 'environment-blocked' } elseif ([int]$testExitCode -eq 0 -and $metricsValid -and $finalSampleValid) { 'passed' } elseif ([int]$testExitCode -eq 0) { 'failed-no-measured-switches' } elseif ([int]$testExitCode -eq 3) { 'no-tests-matched' } elseif ([int]$testExitCode -eq 124) { 'timeout' } else { 'failed' }
    $cpuPercent = $null
    if ($processSamples.Count -ge 2) {
        $first = $processSamples[0]; $last = $processSamples[$processSamples.Count - 1]
        $elapsedMs = ([DateTime]::Parse($last.timestampUtc) - [DateTime]::Parse($first.timestampUtc)).TotalMilliseconds
        if ($elapsedMs -gt 0) { $cpuPercent = [Math]::Round((($last.cpuMilliseconds - $first.cpuMilliseconds) / $elapsedMs) * 100, 2) }
    }
    $metrics = [ordered]@{
        schema = 'clipplayer.performance.v1'
        status = $status
        startedUtc = $startedAt.ToString('o')
        finishedUtc = [DateTime]::UtcNow.ToString('o')
        configuration = $Configuration
        requestedSwitches = $Switches
        seed = $Seed
        actualSwitches = if ($null -eq $testMetrics) { $null } else { [int]$testMetrics.actualSwitches }
        measuredSwitchP50Milliseconds = if ($null -eq $testMetrics) { $null } else { [double]$testMetrics.switchP50Milliseconds }
        measuredSwitchP95Milliseconds = if ($null -eq $testMetrics) { $null } else { [double]$testMetrics.switchP95Milliseconds }
        measuredSwitchP99Milliseconds = if ($null -eq $testMetrics) { $null } else { [double]$testMetrics.switchP99Milliseconds }
        measuredSwitchMaximumMilliseconds = if ($null -eq $testMetrics) { $null } else { [double]$testMetrics.switchMaximumMilliseconds }
        processCpuPercent = $cpuPercent
        finalCpuSample = if ($finalSample.Count -eq 0) { $null } else { $finalSample[0] }
        processResourceSamples = $processSamples.ToArray()
        workingSetStartBytes = if ($processSamples.Count -eq 0) { $null } else { $processSamples[0].workingSetBytes }
        workingSetEndBytes = if ($processSamples.Count -eq 0) { $null } else { $processSamples[$processSamples.Count - 1].workingSetBytes }
        workingSetMaxBytes = if ($processSamples.Count -eq 0) { $null } else { [long](($processSamples | Measure-Object -Property workingSetBytes -Maximum).Maximum) }
        privateBytesStart = if ($processSamples.Count -eq 0) { $null } else { $processSamples[0].privateBytes }
        privateBytesEnd = if ($processSamples.Count -eq 0) { $null } else { $processSamples[$processSamples.Count - 1].privateBytes }
        handlesStart = if ($processSamples.Count -eq 0) { $null } else { $processSamples[0].handles }
        handlesEnd = if ($processSamples.Count -eq 0) { $null } else { $processSamples[$processSamples.Count - 1].handles }
        handlesMax = if ($processSamples.Count -eq 0) { $null } else { [int](($processSamples | Measure-Object -Property handles -Maximum).Maximum) }
        cpuWorkers = if ($NoCpuStress) { 0 } else { $CpuWorkers }
        cpuWorkerCap = $CpuWorkerCap
        processorCount = $processorCount
        cpuDurationSeconds = if ($NoCpuStress) { 0 } else { $CpuDurationSeconds }
        testExitCode = $testExitCode
        sacBlocked = $sacBlocked
        metricsValid = $metricsValid
        outputDirectory = $outputDirectory
    }
    $metrics | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $metricsPath -Encoding utf8
    Write-Output "Performance-Gate: $status"
    Write-Output "Laufdaten (temporär): $outputDirectory"
    if ($sacBlocked) { exit 42 }
    if ($testExitCode -ne 0) { exit $testExitCode }
    if ($status -ne 'passed') { exit 1 }
    exit 0
}
finally {
    if ($null -eq $previousSwitches) { Remove-Item Env:CLIPPLAYER_PERF_SWITCHES -ErrorAction SilentlyContinue }
    else { $env:CLIPPLAYER_PERF_SWITCHES = $previousSwitches }
    if ($null -eq $previousSeed) { Remove-Item Env:CLIPPLAYER_PERF_SEED -ErrorAction SilentlyContinue }
    else { $env:CLIPPLAYER_PERF_SEED = $previousSeed }
    if ($null -eq $previousMetrics) { Remove-Item Env:CLIPPLAYER_PERF_METRICS_PATH -ErrorAction SilentlyContinue }
    else { $env:CLIPPLAYER_PERF_METRICS_PATH = $previousMetrics }
    Stop-BoundedCpuLoad $cpuJobs
}
