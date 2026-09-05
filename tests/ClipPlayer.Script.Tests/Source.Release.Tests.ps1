Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Describe 'SAC-oriented source release' {
    BeforeAll {
        $script:root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        $script:builder = Join-Path $script:root 'scripts\build-source-release.ps1'
    }

    It 'contains only source assets with internally and externally valid hashes' {
        $output = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-source-release-test-' + [Guid]::NewGuid().ToString('N'))
        $extract = "$output-extracted"
        try {
            & $script:builder -Version '1.0.0' -OutputDirectory $output
            $archive = Join-Path $output 'ClipPlayer-source-1.0.0.zip'
            $outerHash = [IO.File]::ReadAllText("$archive.sha256").Split(' ')[0]
            $outerHash | Should -Be (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            Expand-Archive -LiteralPath $archive -DestinationPath $extract
            [IO.File]::ReadAllText((Join-Path $extract 'LICENSE')) | Should -Be `
                ([IO.File]::ReadAllText((Join-Path $script:root 'LICENSE')))
            $lines = @(Get-Content -LiteralPath (Join-Path $extract 'SHA256SUMS.txt'))
            foreach ($line in $lines) {
                $parts = $line -split '  ', 2
                $path = Join-Path $extract ($parts[1].Replace('/', '\'))
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $parts[0]
            }
            $forbidden = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object {
                $_.Extension -in @('.exe', '.dll', '.com', '.msi', '.msix', '.sys', '.scr', '.cpl')
            })
            $forbidden.Count | Should -Be 0
            & powershell.exe -NoLogo -NoProfile -STA -File (Join-Path $extract 'src\ClipPlayer.Script\ClipPlayer.ps1') -SelfTest
            $LASTEXITCODE | Should -Be 0
        } finally {
            foreach ($path in @($output, $extract)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
        }
    }
}
