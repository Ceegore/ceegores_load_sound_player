[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,
    [string] $OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $root 'artifacts\release'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$stage = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-release-' + [Guid]::NewGuid().ToString('N'))
$archive = Join-Path $OutputDirectory "ClipPlayer-source-$Version.zip"
$archiveHash = "$archive.sha256"
$releaseNotes = "docs\release\v$Version.md"

$assets = @(
    [pscustomobject]@{ Source = 'README.md'; Destination = 'README.md' },
    [pscustomobject]@{ Source = 'LICENSE'; Destination = 'LICENSE' },
    [pscustomobject]@{ Source = 'docs\SAC.md'; Destination = 'docs\SAC.md' },
    [pscustomobject]@{ Source = $releaseNotes; Destination = $releaseNotes },
    [pscustomobject]@{ Source = 'docs\architecture\adr-0005-sac-trusted-script-host.md'; Destination = 'docs\adr-0005-sac-trusted-script-host.md' },
    [pscustomobject]@{ Source = 'scripts\install-script-player.ps1'; Destination = 'scripts\install-script-player.ps1' },
    [pscustomobject]@{ Source = 'scripts\uninstall-script-player.ps1'; Destination = 'scripts\uninstall-script-player.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayer.ps1'; Destination = 'src\ClipPlayer.Script\ClipPlayer.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayer.FolderMode.ps1'; Destination = 'src\ClipPlayer.Script\ClipPlayer.FolderMode.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayer.FolderScanner.ps1'; Destination = 'src\ClipPlayer.Script\ClipPlayer.FolderScanner.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayer.PlaybackState.ps1'; Destination = 'src\ClipPlayer.Script\ClipPlayer.PlaybackState.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayer.PlaylistPaths.ps1'; Destination = 'src\ClipPlayer.Script\ClipPlayer.PlaylistPaths.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1'; Destination = 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1' },
    [pscustomobject]@{ Source = 'src\ClipPlayer.Script\ClipPlayer.Window.xaml'; Destination = 'src\ClipPlayer.Script\ClipPlayer.Window.xaml' }
)

try {
    $null = New-Item -ItemType Directory -Path $stage
    foreach ($asset in $assets) {
        $source = Join-Path $root $asset.Source
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release asset missing: $source" }
        $destination = Join-Path $stage $asset.Destination
        $parent = Split-Path $destination -Parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        Copy-Item -LiteralPath $source -Destination $destination
    }
    [IO.File]::WriteAllText((Join-Path $stage 'VERSION'), "$Version`r`n", [Text.UTF8Encoding]::new($false))

    $manifestLines = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($stage.Length).TrimStart('\').Replace('\', '/')
        "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    })
    [IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'), $manifestLines, [Text.UTF8Encoding]::new($false))

    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $archiveHash -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -CompressionLevel Optimal
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'Release archive was not created.' }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        if ($entries.Count -ne ($assets.Count + 2)) { throw "Release archive entry count mismatch: $($entries.Count)." }
        $forbidden = @($entries | Where-Object { [IO.Path]::GetExtension($_.FullName) -in @('.exe', '.dll', '.com', '.msi', '.msix', '.sys', '.scr', '.cpl') })
        if ($forbidden.Count -gt 0) { throw "Release archive contains an executable image: $($forbidden[0].FullName)" }
        if (@($entries | Where-Object FullName -eq 'SHA256SUMS.txt').Count -ne 1) { throw 'Release archive lacks SHA256SUMS.txt.' }
    } finally { $zip.Dispose() }

    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($archiveHash, "$hash  $([IO.Path]::GetFileName($archive))`r`n", [Text.UTF8Encoding]::new($false))
    Write-Output "Source release: $archive"
    Write-Output "SHA-256: $hash"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
