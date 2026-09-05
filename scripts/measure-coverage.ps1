[CmdletBinding()]
param(
    [switch]$SkipPowerShell,
    [switch]$SkipDotNet,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($SkipDotNet -and $SkipPowerShell) { throw 'NOT-MEASURED: all coverage providers were skipped.' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-coverage-' + [Guid]::NewGuid().ToString('N'))
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$summaryPath = Join-Path $OutputDirectory 'coverage-summary.json'
$coverageHelpers = Join-Path $PSScriptRoot 'coverage-helpers.ps1'
if (-not (Test-Path -LiteralPath $coverageHelpers -PathType Leaf)) { throw "Coverage helpers missing: $coverageHelpers" }
. $coverageHelpers

$reports = New-Object Collections.Generic.List[object]
$powerShellCoverage = $null
$powerShellGateBlocked = $false
if (-not $SkipDotNet) {
    # Binding floors sit below the isolated 2026-09-05 assembly baselines so
    # ordinary collector rounding cannot flicker the regression gate.
    $projects = @(
        [PSCustomObject]@{ Path = 'tests\ClipPlayer.Core.Tests\ClipPlayer.Core.Tests.csproj'; Name = 'ClipPlayer.Core'; Assembly = 'ClipPlayer.Core'; Line = 80; Branch = 65 },
        [PSCustomObject]@{ Path = 'tests\ClipPlayer.Audio.Windows.Tests\ClipPlayer.Audio.Windows.Tests.csproj'; Name = 'ClipPlayer.Audio.Windows'; Assembly = 'ClipPlayer.Audio.Windows'; Line = 55; Branch = 40 },
        [PSCustomObject]@{ Path = 'tests\ClipPlayer.App.Tests\ClipPlayer.App.Tests.csproj'; Name = 'ClipPlayer.App'; Assembly = 'ClipPlayer.App'; Line = 45; Branch = 35 }
    )
    foreach ($project in $projects) {
        $results = Join-Path $OutputDirectory ([IO.Path]::GetFileNameWithoutExtension($project.Path))
        $settingsTemplate = Get-Content -LiteralPath (Join-Path $root 'coverage.runsettings') -Raw
        $settingsPath = Join-Path $OutputDirectory ($project.Assembly + '.runsettings')
        [IO.File]::WriteAllText($settingsPath, $settingsTemplate.Replace('__ASSEMBLY__', $project.Assembly), [Text.UTF8Encoding]::new($false))
        $args = @('test', (Join-Path $root $project.Path), '--configuration', 'Debug', '--no-restore', '--settings', $settingsPath, '--collect:XPlat Code Coverage', '--results-directory', $results, '--nologo')
        $dotnetStdoutPath = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N') + '.dotnet-stdout.log')
        $dotnetStderrPath = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N') + '.dotnet-stderr.log')
        $argumentString = (@($args | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
        $dotnetProcess = Start-Process -FilePath 'dotnet.exe' -ArgumentList $argumentString -WorkingDirectory $root `
            -RedirectStandardOutput $dotnetStdoutPath -RedirectStandardError $dotnetStderrPath `
            -WindowStyle Hidden -PassThru
        try { $null = $dotnetProcess.Handle } catch { }
        if (-not $dotnetProcess.WaitForExit(600000)) {
            & taskkill.exe /PID $dotnetProcess.Id /T /F *> $null
            throw "Coverage test timed out for $($project.Path)."
        }
        $dotnetProcess.WaitForExit(); $dotnetProcess.Refresh()
        $dotnetExit = $dotnetProcess.ExitCode
        $dotnetOutput = @()
        foreach ($dotnetLogPath in @($dotnetStdoutPath, $dotnetStderrPath)) {
            if (Test-Path -LiteralPath $dotnetLogPath -PathType Leaf) {
                $dotnetOutput += @(Get-Content -LiteralPath $dotnetLogPath)
                Remove-Item -LiteralPath $dotnetLogPath -Force
            }
        }
        $dotnetOutput | ForEach-Object { Write-Output $_ }
        if ($dotnetExit -ne 0) {
            $dotnetText = $dotnetOutput | Out-String
            if ($dotnetText -match '0x800711C7|Code Integrity|Anwendungssteuerungsrichtlinie') {
                Write-Output "NOT-MEASURED: instrumented .NET binaries were blocked by application control for $($project.Name)."
                exit 2
            }
            throw "Coverage test failed for $($project.Path) (exit $dotnetExit)."
        }
        $report = Get-ChildItem -LiteralPath $results -Filter 'coverage.cobertura.xml' -Recurse -File | Select-Object -First 1
        if ($null -eq $report) { throw "NOT-MEASURED: no instrumented Cobertura report for $($project.Path)." }
        $reports.Add((Get-CoberturaCoverageSummary $report.FullName $project.Name $project.Line $project.Branch))
    }
}

if (-not $SkipPowerShell) {
    $pester = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $pester) {
        Write-Output 'NOT-MEASURED: no Pester version is installed; PowerShell coverage is a hard gate failure, never 0/0 PASS.'
        exit 2
    }
    Import-Module Pester -RequiredVersion $pester.Version -Force
    $psTests = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.Tests.ps1' -Recurse -File)
    if ($psTests.Count -eq 0) { Write-Output 'NOT-MEASURED: no PowerShell tests were found.'; exit 2 }
    $scriptCoveragePaths = @(
        (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.ps1'),
        (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.FolderMode.ps1'),
        (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.PlaybackState.ps1'),
        (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.FolderScanner.ps1'),
        (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.PlaylistPaths.ps1'),
        (Join-Path $root 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1')
    )
    # Pester 5/JaCoCo gates only.  Overall 10/5 reflects the current narrow
    # script integration suite; module floors prevent a large covered module
    # from masking an untested runtime file and must all remain above zero.
    $powerShellFileMinimums = @{
        'ClipPlayer.ps1' = @{ Line = 5; Branch = 2 }
        'ClipPlayer.FolderMode.ps1' = @{ Line = 5; Branch = 2 }
        'ClipPlayer.PlaybackState.ps1' = @{ Line = 5; Branch = 2 }
        'ClipPlayer.FolderScanner.ps1' = @{ Line = 5; Branch = 2 }
        'ClipPlayer.PlaylistPaths.ps1' = @{ Line = 50; Branch = 25 }
        'ClipPlayerLauncher.ps1' = @{ Line = 20; Branch = 10 }
    }
    foreach ($coveragePath in $scriptCoveragePaths) {
        if (-not (Test-Path -LiteralPath $coveragePath -PathType Leaf)) {
            Write-Output "NOT-MEASURED: PowerShell coverage source is missing: $coveragePath"
            exit 2
        }
    }
    if ($pester.Version.Major -ge 5) {
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = @($psTests.FullName)
        $configuration.Run.PassThru = $true
        $configuration.CodeCoverage.Enabled = $true
        $configuration.CodeCoverage.Path = $scriptCoveragePaths
        $powerShellReportPath = Join-Path $OutputDirectory 'powershell-coverage.xml'
        $configuration.CodeCoverage.OutputPath = $powerShellReportPath
        $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
        $configuration.CodeCoverage.CoveragePercentTarget = 10
        $result = Invoke-Pester -Configuration $configuration
        $commandsAnalyzed = if ($null -ne $result.CodeCoverage.PSObject.Properties['CommandsAnalyzedCount']) {
            [long]$result.CodeCoverage.CommandsAnalyzedCount
        } else { [long]$result.CodeCoverage.NumberOfCommandsAnalyzed }
        $commandsExecuted = if ($null -ne $result.CodeCoverage.PSObject.Properties['CommandsExecutedCount']) {
            [long]$result.CodeCoverage.CommandsExecutedCount
        } else { [long]$result.CodeCoverage.NumberOfCommandsExecuted }
        if ($result.FailedCount -gt 0 -or $commandsAnalyzed -le 0 -or $commandsExecuted -le 0) {
            throw 'PowerShell coverage gate failed: no measurable commands or failing tests.'
        }
        $powerShellCoverage = Get-PowerShellCoverageSummary -Path $powerShellReportPath `
            -ExpectedFiles $scriptCoveragePaths -MinimumLinePercent 10 -MinimumBranchPercent 5 `
            -FileMinimums $powerShellFileMinimums
        $powerShellCoverage | Add-Member -NotePropertyName commandsAnalyzed -NotePropertyValue $commandsAnalyzed
        $powerShellCoverage | Add-Member -NotePropertyName commandsExecuted -NotePropertyValue $commandsExecuted
    } else {
        # Pester 3 provides real command coverage, but no branch coverage provider.
        # Keep its per-file command evidence while making the missing branch gate explicit.
        $result = Invoke-Pester -Script @($psTests.FullName) -CodeCoverage $scriptCoveragePaths -PassThru -Quiet
        $coverage = $result.CodeCoverage
        if ($result.FailedCount -gt 0 -or $null -eq $coverage -or
            $coverage.NumberOfCommandsAnalyzed -le 0 -or $coverage.NumberOfCommandsExecuted -le 0) {
            throw 'PowerShell coverage gate failed: Pester reported failing tests or no measurable commands.'
        }
        $fileReports = New-Object Collections.Generic.List[object]
        $zeroEvidenceFiles = New-Object Collections.Generic.List[string]
        foreach ($expected in $scriptCoveragePaths) {
            $hitCommands = @($coverage.HitCommands | Where-Object {
                $null -ne $_ -and [IO.Path]::GetFullPath([string]$_.File) -ieq [IO.Path]::GetFullPath($expected)
            })
            $missedCommands = @($coverage.MissedCommands | Where-Object {
                $null -ne $_ -and [IO.Path]::GetFullPath([string]$_.File) -ieq [IO.Path]::GetFullPath($expected)
            })
            $commandTotal = $hitCommands.Count + $missedCommands.Count
            if ($commandTotal -le 0 -or $hitCommands.Count -le 0) {
                $zeroEvidenceFiles.Add($expected)
                $fileReports.Add([PSCustomObject]@{
                    file = $expected; linesHit = $hitCommands.Count; linesTotal = $commandTotal
                    linePercent = 0; branchesHit = $null; branchesTotal = $null; branchPercent = $null
                    branchStatus = 'NOT-MEASURED (no non-zero Pester 3 command evidence)'
                })
                continue
            }
            $fileReports.Add([PSCustomObject]@{
                file = $expected; linesHit = $hitCommands.Count; linesTotal = $commandTotal
                linePercent = [Math]::Round(100 * $hitCommands.Count / $commandTotal, 2)
                branchesHit = $null; branchesTotal = $null; branchPercent = $null
                branchStatus = 'NOT-MEASURED (Pester 3 has no branch provider)'
            })
        }
        $powerShellCoverage = [PSCustomObject]@{
            report = $null; provider = 'Pester 3 command coverage'
            commandsAnalyzed = $coverage.NumberOfCommandsAnalyzed
            commandsExecuted = $coverage.NumberOfCommandsExecuted
            branchStatus = 'NOT-MEASURED (Pester 3 has no branch provider)'
            zeroEvidenceFiles = @($zeroEvidenceFiles.ToArray())
            files = @($fileReports.ToArray())
        }
        $powerShellGateBlocked = $true
        if ($zeroEvidenceFiles.Count -gt 0) {
            $powerShellCoverage.branchStatus = 'NOT-MEASURED (zero-hit productive module: ' +
                (($zeroEvidenceFiles | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ') + ')'
        }
    }
}

$dotNetComplete = -not $SkipDotNet -and @($reports | Where-Object {
    $_.linePercent -lt 100 -or $_.branchPercent -lt 100
}).Count -eq 0
$powerShellComplete = -not $SkipPowerShell -and ($null -ne $powerShellCoverage -and
    $powerShellCoverage.linePercent -eq 100 -and $powerShellCoverage.branchStatus -eq 'MEASURED' -and
    $powerShellCoverage.branchPercent -eq 100)
$summary = [ordered]@{
    measured = -not $powerShellGateBlocked
    complete100Percent = $dotNetComplete -and $powerShellComplete
    skipped = [ordered]@{ dotNet = [bool]$SkipDotNet; powerShell = [bool]$SkipPowerShell }
    reports = @($reports.ToArray()); powershell = $powerShellCoverage
    outputDirectory = $OutputDirectory
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if ($powerShellGateBlocked) {
    Write-Output "NOT-MEASURED: Pester $($pester.Version) supplied command coverage, but branch coverage is unavailable; see $summaryPath"
    exit 2
}
Write-Output "Coverage regression gates PASS: $summaryPath"
