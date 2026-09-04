[CmdletBinding()]
param(
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$defaultInstallDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer'))
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
if (-not $InstallDirectory.Equals($defaultInstallDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ClipPlayer uses the fixed per-user install directory: $defaultInstallDirectory"
}

$classesRoot = 'Registry::HKEY_CURRENT_USER\Software\Classes'
$progId = 'ClipPlayer.Audio'
foreach ($extension in @('.wav', '.mp3', '.flac')) {
    Remove-ItemProperty -LiteralPath "$classesRoot\$extension\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer" -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath "$classesRoot\$progId" -Recurse -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\RegisteredApplications' -Name 'ClipPlayer' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\ClipPlayer' -Recurse -Force -ErrorAction SilentlyContinue

$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ClipPlayer.lnk'
Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $InstallDirectory) {
    $resolved = (Resolve-Path -LiteralPath $InstallDirectory).Path
    if (-not $resolved.Equals($defaultInstallDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected install directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

Write-Output 'ClipPlayer script installation and per-user Windows integration removed.'
