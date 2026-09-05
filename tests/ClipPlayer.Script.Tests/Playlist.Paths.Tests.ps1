Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Describe 'Playlist path identity' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        . (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.PlaylistPaths.ps1')
    }

    It 'wires the explicit startup base into playlist construction' {
        $playerText = Get-Content -LiteralPath (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.ps1') -Raw
        $playerText | Should -Match 'playlistPathBase\s*=\s*\(Get-Location\)\.ProviderPath'
        $playerText | Should -Match 'Get-UniqueExistingPlaylistPaths\s+\$inputPaths\s+\$script:playlistPathBase'
        $playerText | Should -Match 'Resolve-PlaylistPath\s+\$AudioPath\s+\$script:playlistPathBase'
    }

    It 'deduplicates relative absolute and case variants against an explicit base' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-path-test-' + [Guid]::NewGuid().ToString('N'))
        $other = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-current-dir-' + [Guid]::NewGuid().ToString('N'))
        $oldCurrentDirectory = [Environment]::CurrentDirectory
        $oldLocation = Get-Location
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            $null = New-Item -ItemType Directory -Path $other
            $clip = Join-Path $fixture 'clip.wav'
            [IO.File]::WriteAllBytes($clip, [byte[]](0, 1))
            Set-Location -LiteralPath $fixture
            [Environment]::CurrentDirectory = $other
            $paths = @(Get-UniqueExistingPlaylistPaths @(
                '.\clip.wav', $clip, $clip.ToUpperInvariant(), '.\missing.wav',
                (Join-Path $fixture 'MISSING.WAV'), '.\unsupported.ogg'
            ) $fixture @('.wav', '.mp3', '.flac'))

            $paths.Count | Should -Be 1
            [string]::Equals($paths[0], [IO.Path]::GetFullPath($clip),
                [StringComparison]::OrdinalIgnoreCase) | Should -Be $true
            [Environment]::CurrentDirectory | Should -Be $other
            (Get-Location).Path | Should -Be $fixture
        } finally {
            Set-Location -LiteralPath $oldLocation.Path
            [Environment]::CurrentDirectory = $oldCurrentDirectory
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
            if (Test-Path -LiteralPath $other) { Remove-Item -LiteralPath $other -Recurse -Force }
        }
    }
}
