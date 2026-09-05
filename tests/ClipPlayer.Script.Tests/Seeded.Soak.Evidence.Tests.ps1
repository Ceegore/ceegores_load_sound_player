Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Describe 'Seeded soak evidence lifetime' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        . (Join-Path $root 'scripts\seeded-soak-evidence.ps1')
    }

    It 'keeps default summary evidence outside the disposable run directory' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-soak-evidence-' + [Guid]::NewGuid().ToString('N'))
        $runRoot = Join-Path $fixture 'run'
        try {
            $null = New-Item -ItemType Directory -Path $runRoot -Force
            $summaryPath = Resolve-SeededSoakSummaryPath $runRoot $fixture $null 'unit-default'
            (Test-SeededSoakPathWithin $summaryPath $runRoot) | Should -Be $false
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $summaryPath) -Force
            Set-Content -LiteralPath $summaryPath -Value '{"status":"passed"}' -Encoding utf8
            Remove-Item -LiteralPath $runRoot -Recurse -Force
            Test-Path -LiteralPath $summaryPath -PathType Leaf | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'keeps the summary with artifacts when KeepArtifacts is set' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-soak-evidence-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $summaryPath = Resolve-SeededSoakSummaryPath $fixture $root $null 'unit-keep' -KeepArtifacts
            $summaryPath | Should -Be (Join-Path $fixture 'seeded-soak-summary.json')
            (Test-SeededSoakPathWithin $summaryPath $fixture) | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'rejects disposable explicit evidence without KeepArtifacts' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-soak-evidence-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $message = $null
            try {
                Resolve-SeededSoakSummaryPath $fixture $root (Join-Path $fixture 'summary.json') 'unit-reject' |
                    Out-Null
            } catch { $message = $_.Exception.Message }
            $message | Should -Match 'outside the disposable run directory'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'synchronizes process completion before evaluating ExitCode' {
        $runner = Join-Path $root 'scripts\test-script-player-seeded-soak.ps1'
        $text = [IO.File]::ReadAllText($runner)
        $handle = $text.IndexOf('$null = $process.Handle', [StringComparison]::Ordinal)
        $wait = $text.IndexOf('$process.WaitForExit()', [StringComparison]::Ordinal)
        $read = $text.IndexOf('$exitCode = $process.ExitCode', [StringComparison]::Ordinal)
        $handle | Should -BeGreaterThan -1
        $wait | Should -BeGreaterThan $handle
        $read | Should -BeGreaterThan $wait
        $text | Should -Match '\$status\s*=.*\$exitCode\s*-eq\s*0'
    }

    It 'makes the paranoid race counts binding evidence gates' {
        $runner = Join-Path $root 'scripts\test-script-player-seeded-soak.ps1'
        $text = [IO.File]::ReadAllText($runner)
        $text | Should -Match '\[int\]\s*\$RestartRaceRepros\s*=\s*20'
        $text | Should -Match '\[int\]\s*\$ResumeRaceRepros\s*=\s*50'
        $text | Should -Match '\$metrics\.RestartRaceRepros\s*-eq\s*\$RestartRaceRepros'
        $text | Should -Match '\$metrics\.ResumeRaceRepros\s*-eq\s*\$ResumeRaceRepros'
    }

    It 'retains a bounded diagnostic tail when disposable failure logs are cleaned' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-soak-diagnostics-' + [Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllText($fixture, '0123456789', [Text.UTF8Encoding]::new($false))
            (Get-SeededSoakDiagnosticTail $fixture 4) | Should -Be '6789'
            (Get-SeededSoakDiagnosticTail ($fixture + '.missing') 4) | Should -Be ''
            $runner = [IO.File]::ReadAllText((Join-Path $root 'scripts\test-script-player-seeded-soak.ps1'))
            $runner | Should -Match 'stdoutTail\s*=\s*Get-SeededSoakDiagnosticTail'
            $runner | Should -Match 'stderrTail\s*=\s*Get-SeededSoakDiagnosticTail'
        } finally {
            Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
        }
    }
}
