[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installer = Join-Path $PSScriptRoot 'install-script-player.ps1'
$uninstaller = Join-Path $PSScriptRoot 'uninstall-script-player.ps1'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer'
$classesRoot = 'Registry::HKEY_CURRENT_USER\Software\Classes'
$registeredApplications = 'Registry::HKEY_CURRENT_USER\Software\RegisteredApplications'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ClipPlayer.lnk'
$extensions = @('.wav', '.mp3', '.flac')
$probeName = 'ClipPlayer.UninstallProbe.' + [Guid]::NewGuid().ToString('N')
$probeValue = 'preserve-' + [Guid]::NewGuid().ToString('N')

function Get-RegistryTreeDigest {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $rootKey = Get-Item -LiteralPath $Path
    $keys = @($rootKey) + @(Get-ChildItem -LiteralPath $Path -Recurse | Sort-Object Name)
    $lines = @(foreach ($key in $keys) {
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            $value = $key.GetValue($name, $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $encoded = if ($value -is [byte[]]) { [Convert]::ToBase64String($value) }
                elseif ($value -is [string[]]) { $value | ConvertTo-Json -Compress }
                else { [string]$value }
            "$($key.Name)|$name|$($key.GetValueKind($name))|$encoded"
        }
    })
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Invoke-ScriptProcess {
    param([string] $Path)
    $output = & $hostExe -NoLogo -NoProfile -File $Path 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Path)) failed with exit $LASTEXITCODE`: $output" }
    return $output
}

function Test-RegistryValueExists {
    param([string] $Path, [string] $Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    return $null -ne $key -and $key.GetValueNames() -contains $Name
}

$userChoiceBefore = @{}
foreach ($extension in $extensions) {
    $userChoiceBefore[$extension] = Get-RegistryTreeDigest "$classesRoot\$extension\UserChoice"
}

try {
    $null = Invoke-ScriptProcess $installer
    if (-not (Test-Path -LiteralPath $installDirectory -PathType Container)) { throw 'Installer did not create the product directory.' }
    foreach ($extension in $extensions) {
        $openWith = "$classesRoot\$extension\OpenWithProgids"
        if (-not (Test-Path -LiteralPath $openWith)) { $null = New-Item -Path $openWith -Force }
        New-ItemProperty -Path $openWith -Name $probeName -Value $probeValue -PropertyType String -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $registeredApplications)) {
        $null = New-Item -Path $registeredApplications -Force
    }
    New-ItemProperty -Path $registeredApplications -Name $probeName -Value $probeValue -PropertyType String -Force | Out-Null

    $null = Invoke-ScriptProcess $uninstaller
    $null = Invoke-ScriptProcess $uninstaller

    if (Test-Path -LiteralPath $installDirectory) { throw 'Uninstaller retained the product directory.' }
    if (Test-Path -LiteralPath $shortcut) { throw 'Uninstaller retained the ClipPlayer shortcut.' }
    foreach ($ownedPath in @(
        "$classesRoot\ClipPlayer.Audio",
        'Registry::HKEY_CURRENT_USER\Software\ClipPlayer'
    )) {
        if (Test-Path -LiteralPath $ownedPath) { throw "Uninstaller retained owned registry tree: $ownedPath" }
    }
    foreach ($extension in $extensions) {
        $openWith = "$classesRoot\$extension\OpenWithProgids"
        if (Test-RegistryValueExists $openWith 'ClipPlayer.Audio') { throw "$extension retained ClipPlayer OpenWithProgids." }
        if (-not (Test-RegistryValueExists $openWith $probeName)) { throw "$extension lost a foreign shared-key value." }
        if ((Get-ItemPropertyValue -LiteralPath $openWith -Name $probeName) -ne $probeValue) {
            throw "$extension changed a foreign shared-key value."
        }
        if (Test-Path -LiteralPath "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer") {
            throw "$extension retained the ClipPlayer shell verb."
        }
        if ((Get-RegistryTreeDigest "$classesRoot\$extension\UserChoice") -ne $userChoiceBefore[$extension]) {
            throw "$extension UserChoice changed across install/uninstall."
        }
    }
    if (Test-RegistryValueExists $registeredApplications 'ClipPlayer') { throw 'RegisteredApplications retained ClipPlayer.' }
    if (-not (Test-RegistryValueExists $registeredApplications $probeName)) { throw 'Foreign RegisteredApplications value was removed.' }
    Write-Output 'Production install/uninstall E2E: PASS (idempotent; foreign shared values and UserChoice preserved)'
}
finally {
    foreach ($extension in $extensions) {
        Remove-ItemProperty -LiteralPath "$classesRoot\$extension\OpenWithProgids" -Name $probeName -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -LiteralPath $registeredApplications -Name $probeName -ErrorAction SilentlyContinue
}
