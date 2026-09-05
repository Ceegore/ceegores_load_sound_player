[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Join-Path $root 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('ClipPlayer-startup-states-' + [Guid]::NewGuid().ToString('N'))
$player = $null
$playerStart = $null
$codeIntegrityEventCount = 0

try {
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Launcher missing: $launcher" }
    if ((Get-AuthenticodeSignature -LiteralPath $hostExe).Status -ne 'Valid') {
        throw 'Windows PowerShell host signature is invalid.'
    }
    $null = New-Item -ItemType Directory -Path $testRoot
    # Exercise the real launcher boundary with Unicode, whitespace, an
    # ampersand, and an apostrophe in the path—not only simple ASCII names.
    $unsupported = Join-Path $testRoot 'unsupported ä & O''Brien.txt'
    [IO.File]::WriteAllText($unsupported, 'not audio', [Text.UTF8Encoding]::new($false))
    $cases = @(
        [PSCustomObject]@{ Name = 'empty'; AudioPath = $null; Status = 'Ready. Open an audio file or folder.' },
        [PSCustomObject]@{ Name = 'unsupported'; AudioPath = $unsupported; Status = 'Unsupported audio format.' },
        [PSCustomObject]@{ Name = 'missing'; AudioPath = (Join-Path $testRoot 'missing.wav'); Status = 'Audio file was not found.' }
    )

    foreach ($case in $cases) {
        $diagnostics = Join-Path $testRoot ($case.Name + '.diagnostics.json')
        $commands = Join-Path $testRoot ($case.Name + '.commands.txt')
        $stdout = Join-Path $testRoot ($case.Name + '.stdout.log')
        $stderr = Join-Path $testRoot ($case.Name + '.stderr.log')
        $arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$launcher`" " +
            "-DiagnosticsPath `"$diagnostics`" -AutomationCommandPath `"$commands`" -BackgroundTest"
        if (-not [string]::IsNullOrWhiteSpace($case.AudioPath)) {
            $arguments += " -AudioPath `"$($case.AudioPath)`""
        }
        $started = Get-Date
        $player = Start-Process -FilePath $hostExe -ArgumentList $arguments -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try { $player.Refresh(); $playerStart = $player.StartTime; $null = $player.Handle } catch { }

        $state = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline -and $null -eq $state) {
            if ($player.HasExited) {
                $errorText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
                throw "$($case.Name) player exited before readiness: $errorText"
            }
            try {
                if (Test-Path -LiteralPath $diagnostics -PathType Leaf) {
                    $candidate = Get-Content -LiteralPath $diagnostics -Raw | ConvertFrom-Json
                    if ($candidate.ProcessId -eq $player.Id -and $candidate.CurrentIndex -eq -1 -and
                        $candidate.PlaylistCount -eq 0 -and $candidate.CachedPlayerCount -eq 0 -and
                        -not $candidate.PositionSliderEnabled -and $candidate.Status -eq $case.Status) {
                        $state = $candidate
                    }
                }
            } catch { }
            if ($null -eq $state) { Start-Sleep -Milliseconds 50 }
        }
        if ($null -eq $state) { throw "$($case.Name) player did not publish '$($case.Status)' within 20 seconds." }

        [IO.File]::WriteAllText($commands, '1|Close', [Text.UTF8Encoding]::new($false))
        if (-not $player.WaitForExit(5000)) { throw "$($case.Name) player did not close within 5 seconds." }
        $player.WaitForExit(); $player.Refresh()
        if ($player.ExitCode -ne 0) { throw "$($case.Name) player exited with code $($player.ExitCode)." }
        $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) { throw "$($case.Name) player stderr was not empty: $stderrText" }
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3033, 3077; StartTime = $started
        } -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -eq $player.Id })
        $codeIntegrityEventCount += $events.Count
        $player = $null; $playerStart = $null
    }
    if ($codeIntegrityEventCount -ne 0) {
        throw "Code Integrity logged $codeIntegrityEventCount startup-state block event(s)."
    }
    Write-Output 'Empty/unsupported/missing source-only WPF startup states: PASS'
    Write-Output 'Code Integrity events: 0'
}
finally {
    if ($null -ne $player -and -not $player.HasExited) {
        try {
            $player.Refresh()
            if ($null -ne $playerStart -and $player.StartTime -eq $playerStart) {
                $player.Kill(); $null = $player.WaitForExit(3000)
            }
        } catch { }
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'ClipPlayer-startup-states-*' -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
