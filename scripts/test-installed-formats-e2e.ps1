[CmdletBinding()]
param(
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer'),
    [string] $FfmpegPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher = Join-Path $InstallDirectory 'ClipPlayerLauncher.ps1'
if (-not $FfmpegPath) { $FfmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Installed launcher missing: $launcher" }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-format-e2e-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot
$diagnostics = Join-Path $fixtureRoot 'diagnostics.json'
$commandPath = Join-Path $fixtureRoot 'command.txt'
$stdoutPath = Join-Path $fixtureRoot 'stdout.log'
$stderrPath = Join-Path $fixtureRoot 'stderr.log'
$playerProcess = $null
$startedAt = Get-Date

function Wait-FormatState {
    param([scriptblock] $Predicate, [int] $TimeoutMilliseconds = 15000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($null -ne $script:playerProcess -and $script:playerProcess.HasExited) {
            $errorText = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
            throw "Installed player exited early: $errorText"
        }
        try {
            if (Test-Path -LiteralPath $diagnostics) {
                $state = Get-Content -LiteralPath $diagnostics -Raw | ConvertFrom-Json
                if (& $Predicate $state) { return $state }
            }
        } catch { }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    throw 'Installed format state timed out.'
}

try {
    $formats = @('format-1.wav', 'format-2.mp3', 'format-3.flac')
    foreach ($name in $formats) {
        $target = Join-Path $fixtureRoot $name
        & $FfmpegPath -hide_banner -loglevel error -f lavfi -i 'anullsrc=r=44100:cl=stereo' -t 4 -y $target
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed to generate $name." }
    }

    $audioPath = Join-Path $fixtureRoot $formats[0]
    $argumentLine = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$launcher`" -AudioPath `"$audioPath`" " +
        "-DiagnosticsPath `"$diagnostics`" -AutomationCommandPath `"$commandPath`" -BackgroundTest"
    $playerProcess = Start-Process -FilePath $hostExe -ArgumentList $argumentLine -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $state = Wait-FormatState { param($value) $value.CurrentIndex -eq 0 -and
        $value.CurrentPath -like '*.wav' -and $value.PositionMilliseconds -gt 0 -and $value.DurationMilliseconds -gt 0 }
    $results = @([PSCustomObject]@{ Format = 'WAV'; DurationMilliseconds = $state.DurationMilliseconds })
    for ($index = 1; $index -le 2; $index++) {
        [IO.File]::WriteAllText($commandPath, "$index|Next")
        $expectedName = $formats[$index]
        $state = Wait-FormatState { param($value) $value.LastAutomationCommandId -eq $index -and
            [IO.Path]::GetFileName($value.CurrentPath) -eq $expectedName -and
            $value.PositionMilliseconds -gt 0 -and $value.DurationMilliseconds -gt 0 }
        $results += [PSCustomObject]@{
            Format = [IO.Path]::GetExtension($expectedName).TrimStart('.').ToUpperInvariant()
            DurationMilliseconds = $state.DurationMilliseconds
        }
    }

    [IO.File]::WriteAllText($commandPath, '3|Close')
    $null = $playerProcess.WaitForExit(5000)
    if (-not $playerProcess.HasExited) { throw 'Installed player did not close gracefully.' }
    $stderrText = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) { throw "Installed player stderr was not empty: $stderrText" }
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $startedAt
    } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'ClipPlayer' })
    if ($events.Count -ne 0) { throw "Code Integrity logged $($events.Count) related block events." }
    $results | Format-Table -AutoSize
    Write-Output 'Installed WAV/MP3/FLAC autoplay and switching: PASS'
    Write-Output 'Code Integrity events: 0'
}
finally {
    if ($null -ne $playerProcess -and -not $playerProcess.HasExited) {
        Stop-Process -Id $playerProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
