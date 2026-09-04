[CmdletBinding()]
param(
    [string]$Solution = 'ClipPlayer.sln',
    [string]$CanaryProject = 'tests/ClipPlayer.Core.Tests/ClipPlayer.Core.Tests.csproj',
    [string]$Filter = '',
    [string]$CanaryFilter = 'FullyQualifiedName~ClipPlayer.Core.Tests.PlaybackCoordinatorTests.EmptyPlaylistIsEmptyAndMissingDecoderIsVisible',
    [int]$MaxAttempts = 4,
    [int]$SettleSeconds = 20,
    [int]$TimeoutSeconds = 300,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $root $Solution
$runDirectory = Join-Path ([IO.Path]::GetTempPath()) ("clipplayer-sac-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory | Out-Null

function Get-Output([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return ([IO.StreamReader]::new($stream)).ReadToEnd() }
    finally { $stream.Dispose() }
}

function Get-SacEvent([datetime]$started) {
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $started } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'ClipPlayer' })
    } catch { return @() }
}

function Invoke-TestProcess([string]$testFilter, [int]$attempt, [string]$target = $solutionPath) {
    $stdout = Join-Path $runDirectory "attempt-$attempt.out"
    $stderr = Join-Path $runDirectory "attempt-$attempt.err"
    $targetPath = if ([IO.Path]::IsPathRooted($target)) { $target } else { Join-Path $root $target }
    $args = @('test', $targetPath, '--configuration', 'Release', '--no-build', '--logger', 'console;verbosity=normal')
    if ($testFilter) { $args += @('--filter', $testFilter) }
    $started = Get-Date
    $argumentString = ($args | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $process = Start-Process -FilePath 'dotnet' -ArgumentList $argumentString -WorkingDirectory $root -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try { $null = $process.Handle } catch { }
    $lastHeartbeat = Get-Date
    while (-not $process.HasExited) {
        if (((Get-Date) - $started).TotalSeconds -gt $TimeoutSeconds) {
            & taskkill.exe /PID $process.Id /T /F *> $null
            return [PSCustomObject]@{ ExitCode = 124; Output = (Get-Output $stdout) + (Get-Output $stderr); Sac = $false; Timeout = $true }
        }
        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 30) {
            Write-Output ("[{0}] Testprozess läuft noch ({1}s)" -f (Get-Date -Format 'HH:mm:ss'), [int]((Get-Date) - $started).TotalSeconds)
            $lastHeartbeat = Get-Date
        }
        Start-Sleep -Milliseconds 250
    }
    $output = (Get-Output $stdout) + (Get-Output $stderr)
    $events = Get-SacEvent $started
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
        return [PSCustomObject]@{ ExitCode = 125; Output = $output; Sac = $false; Timeout = $false; Inconclusive = $true }
    }
    [PSCustomObject]@{ ExitCode = [int]$exitCode; Output = $output; Sac = ($output -match '0x800711C7' -or $events.Count -gt 0); Timeout = $false; Inconclusive = $false }
}

function Resolve-TestTarget([string]$testFilter) {
    if ($testFilter -match 'ClipPlayer\.Audio\.Windows\.Tests') { return 'tests/ClipPlayer.Audio.Windows.Tests/ClipPlayer.Audio.Windows.Tests.csproj' }
    if ($testFilter -match 'ClipPlayer\.Core\.Tests') { return 'tests/ClipPlayer.Core.Tests/ClipPlayer.Core.Tests.csproj' }
    if ($testFilter -match 'ClipPlayer\.App\.Tests') { return 'tests/ClipPlayer.App.Tests/ClipPlayer.App.Tests.csproj' }
    if ($testFilter -match 'ClipPlayer\.Performance\.Tests') { return 'tests/ClipPlayer.Performance.Tests/ClipPlayer.Performance.Tests.csproj' }
    return $solutionPath
}

if ($MaxAttempts -lt 1 -or $MaxAttempts -gt 4) { throw 'MaxAttempts muss zwischen 1 und 4 liegen.' }
if (-not $SkipBuild) {
    Write-Output 'Restore und Release-Build der Testziele starten (WAP bleibt externes VS-Gate).'
    & dotnet restore $solutionPath --locked-mode
    if ($LASTEXITCODE -ne 0) { exit 1 }
    $buildTargets = @(
        (Join-Path $root 'src\ClipPlayer.App\ClipPlayer.App.csproj'),
        (Join-Path $root $CanaryProject),
        (Join-Path $root (Resolve-TestTarget $Filter))
    ) | Select-Object -Unique
    foreach ($buildTarget in $buildTargets) {
        $buildArguments = @('build', $buildTarget, '--configuration', 'Release', '--no-restore')
        if ($buildTarget -eq (Join-Path $root 'src\ClipPlayer.App\ClipPlayer.App.csproj')) {
            $buildArguments += @('--runtime', 'win-x64')
        }
        # Test lockfiles intentionally remain RID-less; only the app is RID-specific.
        & dotnet @buildArguments
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
} else {
    Write-Output 'Vorhandenen Release-Build verwenden (--SkipBuild).'
}
if ([string]::IsNullOrWhiteSpace($CanaryFilter)) { Write-Output 'CanaryFilter darf nicht leer sein.'; exit 3 }
$canaryName = (($CanaryFilter -split '~')[-1] -split '\.')[-1]
$canarySource = Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.cs' -Recurse -File |
    Select-String -Pattern $canaryName -SimpleMatch | Select-Object -First 1
if ($null -eq $canarySource) { Write-Output "Canary-Test nicht gefunden: $CanaryFilter"; exit 3 }
if ($SettleSeconds -gt 0) { Write-Output "SAC-Settle: $SettleSeconds Sekunden"; Start-Sleep -Seconds $SettleSeconds }

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $canary = Invoke-TestProcess $CanaryFilter $attempt $CanaryProject
    if ($canary.Sac) {
        Write-Warning "SAC/CodeIntegrity blockiert den Canary (Versuch $attempt); kein Testergebnis."
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (30 * $attempt) }
        continue
    }
    if ($canary.Timeout) { Write-Output 'Canary-Test überschritt das harte Timeout.'; exit 124 }
    if ($canary.Inconclusive) { Write-Output 'Canary-Test ohne verwertbaren ExitCode; Ergebnis ist inconclusive.'; exit 125 }
    if ($canary.Output -match '(?i)(no test matches|kein test entspricht)') {
        Write-Output 'Canary-Filter passte zu keinem Test.'; exit 3
    }
    if ($canary.ExitCode -ne 0) {
        $canary.Output | Write-Output
        exit 1
    }
    $result = Invoke-TestProcess $Filter $attempt (Resolve-TestTarget $Filter)
    $result.Output | Write-Output
    if ($result.Sac) {
        Write-Warning 'SAC/CodeIntegrity blockiert den Testlauf; Exit 42 bedeutet Umgebungs-Nicht-Ergebnis.'
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (30 * $attempt) }
        continue
    }
    if ($result.Timeout) { Write-Output 'Testlauf überschritt das harte Timeout.'; exit 124 }
    if ($result.Inconclusive) { Write-Output 'Testlauf ohne verwertbaren ExitCode; Ergebnis ist inconclusive.'; exit 125 }
    if (($result.Output -match '(?i)(no test matches|kein test entspricht)') -and
        $result.Output -notmatch '(?im)^\s*(passed|bestanden|failed|fehler)\b') { exit 3 }
    exit ([int]$result.ExitCode)
}
Write-Output "SAC/CodeIntegrity blockiert nach $MaxAttempts Versuch(en); Tests sind ein Umgebungs-Nicht-Ergebnis."
exit 42
