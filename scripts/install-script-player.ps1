[CmdletBinding()]
param(
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ClipPlayer.Script\ClipPlayer.ps1'
$launcherSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Player script missing: $source" }
if (-not (Test-Path -LiteralPath $launcherSource -PathType Leaf)) { throw "Launcher script missing: $launcherSource" }
if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }

$signature = Get-AuthenticodeSignature -LiteralPath $powershellExe
if ($signature.Status -ne 'Valid') { throw 'The Windows PowerShell host is not validly Microsoft-signed.' }

$null = New-Item -ItemType Directory -Path $InstallDirectory -Force
$installedScript = Join-Path $InstallDirectory 'ClipPlayer.ps1'
$installedLauncher = Join-Path $InstallDirectory 'ClipPlayerLauncher.ps1'
Copy-Item -LiteralPath $source -Destination $installedScript -Force
Copy-Item -LiteralPath $launcherSource -Destination $installedLauncher -Force

$quotedHost = '"' + $powershellExe + '"'
$quotedScript = '"' + $installedLauncher + '"'
$openCommand = "$quotedHost -NoLogo -NoProfile -STA -WindowStyle Hidden -File $quotedScript `"%1`""
$progId = 'ClipPlayer.Audio'
$extensions = @('.wav', '.mp3', '.flac')
$classesRoot = 'Registry::HKEY_CURRENT_USER\Software\Classes'

$null = New-Item -Path "$classesRoot\$progId\shell\open\command" -Force
Set-Item -LiteralPath "$classesRoot\$progId" -Value 'ClipPlayer audio file'
Set-Item -LiteralPath "$classesRoot\$progId\shell\open\command" -Value $openCommand
$null = New-Item -Path "$classesRoot\$progId\DefaultIcon" -Force
Set-Item -LiteralPath "$classesRoot\$progId\DefaultIcon" -Value "$env:SystemRoot\System32\shell32.dll,-138"

foreach ($extension in $extensions) {
    $openWith = "$classesRoot\$extension\OpenWithProgids"
    $null = New-Item -Path $openWith -Force
    New-ItemProperty -Path $openWith -Name $progId -Value '' -PropertyType String -Force | Out-Null

    $verb = "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer"
    $null = New-Item -Path "$verb\command" -Force
    Set-Item -LiteralPath $verb -Value 'Play with ClipPlayer'
    New-ItemProperty -Path $verb -Name 'Icon' -Value "$env:SystemRoot\System32\shell32.dll,-138" -PropertyType String -Force | Out-Null
    Set-Item -LiteralPath "$verb\command" -Value $openCommand
}

$capabilities = 'Registry::HKEY_CURRENT_USER\Software\ClipPlayer\Capabilities'
$null = New-Item -Path "$capabilities\FileAssociations" -Force
New-ItemProperty -Path $capabilities -Name 'ApplicationName' -Value 'ClipPlayer' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $capabilities -Name 'ApplicationDescription' -Value 'Fast local audio preview player' -PropertyType String -Force | Out-Null
foreach ($extension in $extensions) {
    New-ItemProperty -Path "$capabilities\FileAssociations" -Name $extension -Value $progId -PropertyType String -Force | Out-Null
}
$null = New-Item -Path 'Registry::HKEY_CURRENT_USER\Software\RegisteredApplications' -Force
New-ItemProperty -Path 'Registry::HKEY_CURRENT_USER\Software\RegisteredApplications' -Name 'ClipPlayer' `
    -Value 'Software\ClipPlayer\Capabilities' -PropertyType String -Force | Out-Null

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $startMenu 'ClipPlayer.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File $quotedScript"
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,138"
$shortcut.Save()

Write-Output "Installed ClipPlayer to $installedScript"
Write-Output 'Windows integration registered for WAV, MP3 and FLAC without changing the current default app.'
