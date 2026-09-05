Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Describe 'Source-only security and policy contract' {
    BeforeAll {
        $script:root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        $script:productScripts = @(
            Get-ChildItem -LiteralPath (Join-Path $script:root 'src\ClipPlayer.Script') -Filter '*.ps1' -File
            Get-Item -LiteralPath (Join-Path $script:root 'scripts\install-script-player.ps1')
            Get-Item -LiteralPath (Join-Path $script:root 'scripts\uninstall-script-player.ps1')
        )
    }

    It 'parses every repository PowerShell file without errors' {
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path $script:root 'src') -Filter '*.ps1' -Recurse -File
            Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -Recurse -File
            Get-ChildItem -LiteralPath (Join-Path $script:root 'tests') -Filter '*.ps1' -Recurse -File
        )
        foreach ($file in $files) {
            $tokens = $null; $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0 -Because $file.FullName
        }
    }

    It 'contains no policy bypass or protection-disable command in executable scripts' {
        foreach ($file in $script:productScripts) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text | Should -Not -Match '(?i)-ExecutionPolicy\s+Bypass' -Because $file.FullName
            $text | Should -Not -Match '(?i)\bUnblock-File\b' -Because $file.FullName
            $text | Should -Not -Match '(?i)\bSet-ExecutionPolicy\b|\bSet-MpPreference\b|DisableRealtimeMonitoring' -Because $file.FullName
        }
    }

    It 'keeps the player runtime free of dynamically compiled custom assemblies' {
        $runtimeText = (Get-ChildItem -LiteralPath (Join-Path $script:root 'src\ClipPlayer.Script') -Filter '*.ps1' -File |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $runtimeText | Should -Not -Match '(?i)Add-Type\s+-TypeDefinition'
    }

    It 'keeps every maintained script within the reviewable 500-line limit' {
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path $script:root 'src\ClipPlayer.Script') -Filter '*.ps1' -File
            Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -File
        )
        foreach ($file in $files) {
            @(Get-Content -LiteralPath $file.FullName).Count | Should -BeLessOrEqual 500 -Because $file.FullName
        }
    }

    It 'loads valid XAML and finds no executable image beside the source runtime' {
        $runtime = Join-Path $script:root 'src\ClipPlayer.Script'
        { [xml](Get-Content -LiteralPath (Join-Path $runtime 'ClipPlayer.Window.xaml') -Raw) } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $runtime -Recurse -File | Where-Object {
            $_.Extension -in @('.exe', '.dll', '.com', '.msi', '.msix', '.sys', '.scr', '.cpl')
        }).Count | Should -Be 0
    }

    It 'uses the validly signed inbox Windows PowerShell host' {
        $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        (Get-AuthenticodeSignature -LiteralPath $hostExe).Status | Should -Be 'Valid'
    }

    It 'synchronizes every polled child process before reading ExitCode' {
        foreach ($relative in @(
            'scripts\generate-sbom.ps1',
            'scripts\run-audio-stress.ps1',
            'scripts\run-tests-sac-safe.ps1',
            'scripts\test-script-player-seeded-soak.ps1'
        )) {
            $text = [IO.File]::ReadAllText((Join-Path $script:root $relative))
            $wait = $text.IndexOf('$process.WaitForExit()', [StringComparison]::Ordinal)
            $exit = $text.IndexOf('$process.ExitCode', [StringComparison]::Ordinal)
            $wait | Should -BeGreaterThan -1 -Because $relative
            $exit | Should -BeGreaterThan $wait -Because $relative
        }
    }

    It 'keeps every PowerShell source file UTF-8 BOM encoded' {
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path $script:root 'src') -Filter '*.ps1' -Recurse -File
            Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts') -Filter '*.ps1' -Recurse -File
            Get-ChildItem -LiteralPath (Join-Path $script:root 'tests') -Filter '*.ps1' -Recurse -File
        )
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
                Should -Be $true -Because $file.FullName
        }
    }
}
