Set-StrictMode -Version 2.0

$root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$wrapper = Join-Path $root 'scripts\run-tests-sac-safe.ps1'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-SacDirectories {
    return @(Get-ChildItem -LiteralPath $script:sacTestTempRoot -Directory -Filter 'clipplayer-sac-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Parent.FullName -eq $script:sacTestTempRoot.TrimEnd('\') })
}

function Invoke-SacWrapperFixture {
    param(
        [ValidateSet('success', 'failure', 'sac', 'timeout', 'missing')]
        [string] $Mode,
        [switch] $KeepArtifacts
    )
    $fixture = Join-Path $script:sacTestTempRoot ('ClipPlayer-sac-runner-test-' + [Guid]::NewGuid().ToString('N'))
    $fakeDotnet = Join-Path $fixture 'dotnet.cmd'
    $oldPath = $env:Path
    try {
        $null = New-Item -ItemType Directory -Path $fixture -Force
        if ($Mode -ne 'missing') {
            $body = switch ($Mode) {
                'success' { "@echo off`r`nexit /b 0" }
                'failure' { "@echo off`r`nexit /b 7" }
                'sac' { "@echo 0x800711C7`r`nexit /b 1" }
                'timeout' { "@echo off`r`nping.exe -n 8 127.0.0.1 > nul`r`nexit /b 0" }
            }
            Set-Content -LiteralPath $fakeDotnet -Value $body -Encoding ascii
        }
        $env:Path = if ($Mode -eq 'missing') { $fixture } else { $fixture + ';' + $oldPath }
        $args = @('-NoLogo', '-NoProfile', '-File', $wrapper, '-SkipBuild', '-SettleSeconds', '0', '-TimeoutSeconds', '1')
        if ($Mode -eq 'sac') { $args += @('-MaxAttempts', '1') }
        if ($KeepArtifacts) { $args += '-KeepArtifacts' }
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = (& $hostExe @args 2>&1 | Out-String)
            $code = [int]$LASTEXITCODE
        } finally { $ErrorActionPreference = $oldErrorAction }
        return [PSCustomObject]@{ ExitCode = $code; Output = $output }
    } finally {
        $env:Path = $oldPath
        if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}

function Assert-SacDeltaIsEmpty {
    param([object[]] $Before, [string] $Description)
    $after = @(Get-SacDirectories)
    $beforeNames = @($Before | ForEach-Object FullName)
    $new = @($after | Where-Object { $beforeNames -notcontains $_.FullName })
    @($new).Count | Should -Be 0 -Because $Description
}
