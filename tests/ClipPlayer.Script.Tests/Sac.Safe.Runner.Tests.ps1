Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Describe 'SAC-safe runner artifact lifetime' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Sac.Safe.Runner.TestHelpers.ps1')
        $script:sacOriginalTemp = $env:TEMP
        $script:sacOriginalTmp = $env:TMP
        $script:sacTestTempRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ('ClipPlayer-sac-test-namespace-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:sacTestTempRoot
        # Child processes inherit this per-test-host namespace. This makes the
        # leak checks deterministic even when Pester 5 and 6 run concurrently.
        $env:TEMP = $script:sacTestTempRoot
        $env:TMP = $script:sacTestTempRoot
    }
    AfterAll {
        $env:TEMP = $script:sacOriginalTemp
        $env:TMP = $script:sacOriginalTmp
        if (Test-Path -LiteralPath $script:sacTestTempRoot) {
            Remove-Item -LiteralPath $script:sacTestTempRoot -Recurse -Force
        }
    }
    It 'validates MaxAttempts before allocating a run directory' {
        $before = @(Get-SacDirectories)
        # The fixture wrapper uses the normal default MaxAttempts; invoke the
        # zero-attempt contract separately so this remains deterministic.
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = (& $hostExe -NoLogo -NoProfile -File $wrapper -MaxAttempts 0 -SettleSeconds 0 2>&1 | Out-String)
            $code = [int]$LASTEXITCODE
        } finally { $ErrorActionPreference = $oldErrorAction }
        $code | Should -Be 1
        $output | Should -Match 'MaxAttempts'
        Assert-SacDeltaIsEmpty $before 'MaxAttempts=0'
    }

    It 'cleans the exact directory after a simulated successful run' {
        $before = @(Get-SacDirectories)
        $result = Invoke-SacWrapperFixture 'success'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'SAC-Artefakte entfernt:'
        Assert-SacDeltaIsEmpty $before 'success'
    }

    It 'cleans after test failure, SAC exhaustion, timeout, and internal process exception' {
        foreach ($mode in @('failure', 'sac', 'timeout', 'missing')) {
            $before = @(Get-SacDirectories)
            $result = Invoke-SacWrapperFixture $mode
            if ($mode -eq 'failure' -or $mode -eq 'missing') { $result.ExitCode | Should -Be 1 }
            if ($mode -eq 'sac') { $result.ExitCode | Should -Be 42 }
            if ($mode -eq 'timeout') { $result.ExitCode | Should -Be 124 }
            $result.Output | Should -Match 'SAC-Artefakte entfernt:'
            Assert-SacDeltaIsEmpty $before $mode
        }
    }

    It 'retains only the explicitly requested directory with KeepArtifacts' {
        $before = @(Get-SacDirectories)
        $result = Invoke-SacWrapperFixture 'success' -KeepArtifacts
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'SAC-Artefakte behalten: .*clipplayer-sac-'
        $after = @(Get-SacDirectories)
        $beforeNames = @($before | ForEach-Object FullName)
        $new = @($after | Where-Object { $beforeNames -notcontains $_.FullName })
        @($new).Count | Should -Be 1
        Remove-Item -LiteralPath $new[0].FullName -Recurse -Force
    }
}
