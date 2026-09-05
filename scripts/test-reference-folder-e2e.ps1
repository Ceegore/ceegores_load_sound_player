[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $FolderPath,
    [ValidateRange(5, 120)]
    [int] $TimeoutSeconds = 45,
    [string] $LauncherPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Wait-ReferenceState {
    param([scriptblock] $Predicate, [string] $Description)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            if ([IO.File]::Exists($script:diagnosticsPath)) {
                $state = [IO.File]::ReadAllText($script:diagnosticsPath) | ConvertFrom-Json
                if (& $Predicate $state) { return $state }
            }
        } catch { }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out: $Description"
}

function Send-ReferenceCommand {
    param([long] $Id, [string] $Command)
    [IO.File]::WriteAllText($script:commandsPath, "$Id|$Command")
    return Wait-ReferenceState {
        param($state)
        $state.LastAutomationCommandId -eq $Id -and $state.LastAutomationCommandName -eq $Command
    } "command $Command"
}

$resolvedFolder = [IO.Path]::GetFullPath($FolderPath)
$directory = [IO.DirectoryInfo]::new($resolvedFolder)
$files = @($directory.GetFiles() | Where-Object { $_.Extension -in @('.wav', '.mp3', '.flac') })
if ($files.Count -eq 0) { throw "No supported audio files in '$resolvedFolder'." }
$expectedItemCount = $files.Count + @($directory.GetDirectories()).Count
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-reference-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:diagnosticsPath = Join-Path $testRoot 'diagnostics.json'
$script:commandsPath = Join-Path $testRoot 'commands.txt'
$stderrPath = Join-Path $testRoot 'stderr.log'
$stdoutPath = Join-Path $testRoot 'stdout.log'
$launcher = [IO.Path]::GetFullPath($LauncherPath)
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Launcher not found: $launcher" }
$firstAudio = $files[0].FullName
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process = $null
$processStart = $null

try {
    $arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$launcher`" -AudioPath `"$firstAudio`" " +
        "-DiagnosticsPath `"$script:diagnosticsPath`" -AutomationCommandPath `"$script:commandsPath`" -BackgroundTest"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $processStart = $process.StartTime
    $ready = Wait-ReferenceState {
        param($state)
        -not $state.FolderScanPending -and $state.FolderPath -eq $resolvedFolder -and
            $state.PlaylistCount -eq $files.Count -and $state.FolderItemCount -eq $expectedItemCount
    } 'large-folder scan and sibling playlist'
    $watch.Stop()
    if ($ready.FolderAudioCount -ne $files.Count) { throw "Expected $($files.Count) audio entries, got $($ready.FolderAudioCount)." }
    if ($ready.PlayerFailureCount -ne 0) { throw "Playback failure(s): $($ready.FailureMap | ConvertTo-Json -Compress)" }
    $paused = Send-ReferenceCommand 1 'TogglePause'
    if (-not $paused.IsPaused) { throw 'Pause command did not stop playback.' }
    $previous = if ($paused.CurrentIndex -gt 0) { Send-ReferenceCommand 2 'Previous' } else { $null }
    if ($null -ne $previous -and $previous.LastAutomationCommandAfterIndex -ne ($previous.LastAutomationCommandBeforeIndex - 1)) {
        throw 'Previous did not select the preceding sibling.'
    }
    $next = Send-ReferenceCommand $(if ($null -eq $previous) { 2 } else { 3 }) 'Next'
    if ($next.LastAutomationCommandAfterIndex -ne ($next.LastAutomationCommandBeforeIndex + 1)) {
        throw 'Next did not select the following sibling.'
    }
    if ($next.PlayerFailureCount -ne 0) { throw "Navigation produced playback failure(s): $($next.FailureMap | ConvertTo-Json -Compress)" }
    $null = Send-ReferenceCommand $(if ($null -eq $previous) { 3 } else { 4 }) 'Close'
    if (-not $process.WaitForExit(10000)) { throw 'ClipPlayer did not close on request.' }
    $stderr = if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "Player wrote to stderr: $stderr" }
    [pscustomobject]@{
        Result = 'PASS'; FolderPath = $resolvedFolder; AudioFiles = $files.Count; FolderItems = $expectedItemCount
        ScanAndPlaylistMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        InitialPath = $firstAudio; FinalIndex = $next.CurrentIndex; CachedPlayers = $next.CachedPlayerCount
    } | ConvertTo-Json -Compress
} finally {
    if ($null -ne $process) {
        try {
            $process.Refresh()
            if (-not $process.HasExited -and $process.StartTime -eq $processStart) { $process.Kill(); $null = $process.WaitForExit(3000) }
        } catch { }
    }
}
