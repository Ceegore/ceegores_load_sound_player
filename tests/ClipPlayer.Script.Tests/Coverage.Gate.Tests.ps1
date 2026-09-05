Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Describe 'Cobertura coverage gate regression' {
    BeforeAll { . (Join-Path $PSScriptRoot 'Coverage.TestHelpers.ps1') }
    It 'counts a 50-percent condition as one of two root branches' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-coverage-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-CoberturaFixture $fixture
            $summary = Get-CoberturaCoverageSummary $report 'Synthetic' 70 40
            $summary.branchesHit | Should -Be 1
            $summary.branchesTotal | Should -Be 2
            $summary.branchPercent | Should -Be 50
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'rejects a report below its binding branch minimum' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-coverage-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-CoberturaFixture $fixture
            $message = $null
            try { Get-CoberturaCoverageSummary $report 'Synthetic' 70 51 | Out-Null }
            catch { $message = $_.Exception.Message }
            $message | Should -Match 'branch coverage 50% is below 51%'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'rejects a Cobertura rate and count mismatch' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-coverage-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-CoberturaFixture $fixture -ReportedBranchRate '0.9'
            $message = $null
            try { Get-CoberturaCoverageSummary $report 'Synthetic' 0 0 | Out-Null }
            catch { $message = $_.Exception.Message }
            $message | Should -Match 'root rates disagree with covered/valid counts'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }
}

Describe 'Pester 5 JaCoCo coverage gate regression' {
    BeforeAll { . (Join-Path $PSScriptRoot 'Coverage.TestHelpers.ps1') }
    It 'returns a stable file array without the PS5.1 generic-list binder failure' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-jacoco-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-JaCoCoFixture $fixture
            $summary = Get-PowerShellCoverageSummary $report @('C:\product\ClipPlayer.ps1') 50 40
            @($summary.files).Count | Should -Be 1
            $summary.files[0].linePercent | Should -Be 80
            $summary.files[0].branchPercent | Should -Be 60
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'rejects one-percent overall line and branch coverage' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-jacoco-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-JaCoCoFixture $fixture -LinesCovered 1 -LinesMissed 99 -BranchesCovered 1 -BranchesMissed 99
            $message = $null
            try { Get-PowerShellCoverageSummary $report @('C:\product\ClipPlayer.ps1') | Out-Null }
            catch { $message = $_.Exception.Message }
            $message | Should -Match 'overall: lines 1%/10%'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'rejects zero-hit evidence for the required launcher' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-jacoco-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-JaCoCoFixture $fixture -Name 'ClipPlayerLauncher.ps1' -LinesCovered 0 -LinesMissed 10
            $message = $null
            $floors = @{ 'ClipPlayerLauncher.ps1' = @{ Line = 20; Branch = 10 } }
            try {
                Get-PowerShellCoverageSummary $report @('C:\product\ClipPlayerLauncher.ps1') 0 0 $floors |
                    Out-Null
            }
            catch { $message = $_.Exception.Message }
            $message | Should -Match 'lacks non-zero line evidence'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'enforces a required file floor even when overall coverage is high' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-jacoco-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-JaCoCoFixture $fixture
            $floors = @{ 'ClipPlayer.ps1' = @{ Line = 90; Branch = 70 } }
            $message = $null
            try { Get-PowerShellCoverageSummary $report @('C:\product\ClipPlayer.ps1') 10 5 $floors | Out-Null }
            catch { $message = $_.Exception.Message }
            $message | Should -Match 'ClipPlayer.ps1: lines 80%/90%'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'accepts a valid report at both overall and file floors' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-jacoco-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-JaCoCoFixture $fixture
            $floors = @{ 'ClipPlayer.ps1' = @{ Line = 75; Branch = 55 } }
            $summary = Get-PowerShellCoverageSummary $report @('C:\product\ClipPlayer.ps1') 75 55 $floors
            $summary.provider | Should -Be 'Pester JaCoCo line coverage'
            $summary.linePercent | Should -Be 80
            $summary.branchPercent | Should -Be 60
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'reports branch coverage as not measured when Pester omits branch counters' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-jacoco-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $report = New-JaCoCoFixture $fixture -OmitBranches
            $summary = Get-PowerShellCoverageSummary $report @('C:\product\ClipPlayer.ps1') 75 100
            $summary.linePercent | Should -Be 80
            $summary.branchPercent | Should -BeNullOrEmpty
            $summary.branchStatus | Should -Match '^NOT-MEASURED'
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }
}
