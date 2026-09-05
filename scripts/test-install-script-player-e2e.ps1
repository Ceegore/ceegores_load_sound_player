[CmdletBinding()]
param(
    [switch] $KeepArtifacts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $PSScriptRoot 'install-script-player.ps1'
$sourceRoot = Join-Path $repoRoot 'src\ClipPlayer.Script'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
Add-Type -TypeDefinition @'
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ClipPlayerTestLinks {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateSymbolicLink(string link, string target, int flags);
    public static void CreateDirectory(string link, string target) {
        if (!CreateSymbolicLink(link, target, 3)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@

$assets = @('ClipPlayer.ps1', 'ClipPlayer.FolderMode.ps1', 'ClipPlayer.PlaybackState.ps1',
    'ClipPlayer.FolderScanner.ps1', 'ClipPlayer.PlaylistPaths.ps1', 'ClipPlayerLauncher.ps1', 'ClipPlayer.Window.xaml')
$phases = @('StageCreated', 'AssetsCopied', 'AssetsValidated', 'BackupRenamed', 'StageSwapped',
    'FinalValidated', 'RegistryUpdated', 'ShortcutUpdated', 'BackupRemoved',
    'BackupCleanupMidway', 'BackupCleanupLocked')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClipPlayer-installer-e2e-{0}" -f [Guid]::NewGuid().ToString('N'))
$install = Join-Path $testRoot 'ClipPlayer'
$registryRoot = "Registry::HKEY_CURRENT_USER\Software\ClipPlayerInstallerE2E\$([Guid]::NewGuid().ToString('N'))"
$classesRoot = "$registryRoot\Classes"
$shortcutPath = Join-Path $testRoot 'ClipPlayer.lnk'
$stdout = Join-Path $testRoot 'stdout.log'
$stderr = Join-Path $testRoot 'stderr.log'

function Get-Hashes {
    param([string] $Directory)
    $result = @{}
    foreach ($asset in $assets) {
        $path = Join-Path $Directory $asset
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing test asset: $path" }
        $result[$asset] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    return $result
}
function New-OldVersion {
    if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $install -Force
    foreach ($asset in $assets) {
        $source = Join-Path $sourceRoot $asset
        $destination = Join-Path $install $asset
        Copy-Item -LiteralPath $source -Destination $destination
        # Keep the old tree complete but make every file distinguishable from
        # the source version. Both prefixes are valid comments in their format.
        $text = [IO.File]::ReadAllText($destination)
        if ($asset -eq 'ClipPlayer.Window.xaml') { $text = "<!-- old installer fixture -->`r`n$text" }
        else { $text = "# old installer fixture`r`n$text" }
        [IO.File]::WriteAllText($destination, $text, [Text.UTF8Encoding]::new($false))
    }
    $markerRoot = Join-Path $install 'LegacyMarkers'
    $null = New-Item -ItemType Directory -Path $markerRoot -Force
    for ($index = 0; $index -lt 100; $index++) {
        $marker = Join-Path $markerRoot ('marker-{0:d3}.txt' -f $index)
        [IO.File]::WriteAllText($marker, "old marker $index", [Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]@{ AssetHashes = Get-Hashes $install; TreeSnapshot = @(Get-TreeSnapshot $install) }
}
function Get-TreeSnapshot {
    param([string] $Directory)
    $rootPath = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    return @((Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length).TrimStart('\')
        if ($_.PSIsContainer) { "D|$relative" }
        else { "F|$relative|$($_.Length)|$([int]$_.Attributes)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToUpperInvariant())" }
    }))
}
function Reset-IntegrationState {
    Remove-Item -LiteralPath $registryRoot -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -Path "$classesRoot\ClipPlayer.Audio\shell\open\command" -Force
    Set-Item -LiteralPath "$classesRoot\ClipPlayer.Audio" -Value 'old ProgID description'
    New-ItemProperty -Path "$classesRoot\ClipPlayer.Audio" -Name 'CustomValue' -Value 'preserve-me' -PropertyType String -Force | Out-Null
    Set-Item -LiteralPath "$classesRoot\ClipPlayer.Audio\shell\open\command" -Value 'old command'
    foreach ($extension in @('.wav', '.mp3', '.flac')) {
        $openWith = "$classesRoot\$extension\OpenWithProgids"; $null = New-Item -Path $openWith -Force
        New-ItemProperty -Path $openWith -Name 'Other.App' -Value 'other' -PropertyType String -Force | Out-Null
        # A pre-existing value can legally have any registry kind.  Rollback
        # must restore both data and kind rather than only its string form.
        New-ItemProperty -Path $openWith -Name 'ClipPlayer.Audio' -Value 7 -PropertyType DWord -Force | Out-Null
        $verb = "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer"; $null = New-Item -Path "$verb\command" -Force
        Set-Item -LiteralPath $verb -Value 'old verb'; Set-Item -LiteralPath "$verb\command" -Value 'old command'
        New-ItemProperty -Path $verb -Name 'Icon' -Value 'old icon' -PropertyType String -Force | Out-Null
    }
    $null = New-Item -Path "$registryRoot\ClipPlayer\Capabilities\FileAssociations" -Force
    New-ItemProperty -Path "$registryRoot\ClipPlayer\Capabilities" -Name 'CustomValue' -Value 'old capability' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "$registryRoot\ClipPlayer\Capabilities\FileAssociations" -Name '.other' -Value 'Other.App' -PropertyType String -Force | Out-Null
    $registered = "$registryRoot\RegisteredApplications"; $null = New-Item -Path $registered -Force
    New-ItemProperty -Path $registered -Name 'OtherApplication' -Value 'Other\Capabilities' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $registered -Name 'ClipPlayer' -Value '%TEMP%\old\Capabilities' -PropertyType ExpandString -Force | Out-Null
    $userChoice = "$classesRoot\.wav\UserChoice"; $null = New-Item -Path $userChoice -Force
    New-ItemProperty -Path $userChoice -Name 'ProgId' -Value 'Other.App' -PropertyType String -Force | Out-Null
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllBytes($shortcutPath, [Text.Encoding]::UTF8.GetBytes('custom pre-existing shortcut'))
    (Get-Item -LiteralPath $shortcutPath).Attributes = [IO.FileAttributes]::Hidden
}
function Get-RegistrySnapshotLines {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @('MISSING') }
    $rootKey = Get-Item -LiteralPath $Path
    $keys = @($rootKey) + @(Get-ChildItem -LiteralPath $Path -Recurse | Sort-Object Name)
    $lines = @(foreach ($key in $keys) {
        $relative = [string]$key.Name
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $encoded = if ($value -is [byte[]]) { [Convert]::ToBase64String($value) }
                elseif ($value -is [string[]]) { $value | ConvertTo-Json -Compress }
                else { [string]$value }
            "$relative|$name|$($key.GetValueKind($name))|$encoded"
        }
    })
    return @($lines | Sort-Object)
}
function Get-RegistryHash {
    param([string] $Path)
    $lines = @(Get-RegistrySnapshotLines $Path)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}
function Get-ShortcutHash {
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { return 'MISSING' }
    $item = Get-Item -LiteralPath $shortcutPath -Force
    return "$((Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash.ToUpperInvariant())|$([int]$item.Attributes)"
}
function Invoke-Installer {
    param([string] $Phase, [string] $Root = $testRoot, [string] $InstallPath = $install,
        [string] $RegistryPath = $registryRoot, [string] $LinkPath = $shortcutPath)
    $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + $installer + '"'),
        '-InstallDirectory', ('"' + $InstallPath + '"'), '-TestMode', '-TestRoot', ('"' + $Root + '"'),
        '-IntegrationRegistryRoot', ('"' + $RegistryPath + '"'), '-ShortcutPath', ('"' + $LinkPath + '"'))
    if ($Phase) { $arguments += @('-FaultInjectionPhase', $Phase) }
    $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -Wait
    return $process.ExitCode
}
function Assert-OldVersion {
    param($Expected)
    $actual = Get-Hashes $install
    foreach ($asset in $assets) {
        if ($actual[$asset] -ne $Expected.AssetHashes[$asset]) { throw "Rollback left a mixed install: $asset" }
    }
    $actualTree = @(Get-TreeSnapshot $install)
    if ($actualTree.Count -ne $Expected.TreeSnapshot.Count) { throw 'Rollback did not restore all 100 markers/assets.' }
    for ($index = 0; $index -lt $actualTree.Count; $index++) {
        if ($actualTree[$index] -cne $Expected.TreeSnapshot[$index]) { throw "Rollback tree mismatch at entry $index." }
    }
    $parent = Split-Path $install -Parent
    $leftovers = @(Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -like '.ClipPlayer.stage.*' -or $_.Name -like '.ClipPlayer.backup.*' -or $_.Name -like '.ClipPlayer.rollback.*' -or $_.Name -like '.ClipPlayer.integration.*' })
    if ($leftovers.Count -ne 0) { throw "Rollback left transaction artifacts: $($leftovers[0].FullName)" }
}
function Get-RegistryValue {
    param([string] $Path, [string] $Name = '')
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}
function Get-RegistryValueKind {
    param([string] $Path, [string] $Name = '')
    return (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name).ToString()
}
function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ([string]$Actual -cne [string]$Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}
function Assert-PositiveIntegration {
    $launcher = Join-Path $install 'ClipPlayerLauncher.ps1'
    $quotedHost = '"' + $hostExe + '"'; $quotedScript = '"' + $launcher + '"'
    $expectedCommand = "$quotedHost -NoLogo -NoProfile -STA -WindowStyle Hidden -File $quotedScript `"%1`""
    Assert-Equal (Get-RegistryValue "$classesRoot\ClipPlayer.Audio") 'ClipPlayer audio file' 'ProgID description mismatch.'
    Assert-Equal (Get-RegistryValue "$classesRoot\ClipPlayer.Audio\shell\open\command") $expectedCommand 'ProgID open command mismatch.'
    Assert-Equal (Get-RegistryValue "$classesRoot\ClipPlayer.Audio\DefaultIcon") "$env:SystemRoot\System32\shell32.dll,-138" 'ProgID icon mismatch.'
    foreach ($extension in @('.wav', '.mp3', '.flac')) {
        Assert-Equal (Get-RegistryValue "$classesRoot\$extension\OpenWithProgids" 'ClipPlayer.Audio') '' "$extension OpenWithProgids mismatch."
        Assert-Equal (Get-RegistryValue "$classesRoot\$extension\OpenWithProgids" 'Other.App') 'other' "$extension foreign OpenWithProgids value changed."
        $verb = "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer"
        Assert-Equal (Get-RegistryValue $verb) 'Play with ClipPlayer' "$extension verb label mismatch."
        Assert-Equal (Get-RegistryValue $verb 'Icon') "$env:SystemRoot\System32\shell32.dll,-138" "$extension verb icon mismatch."
        Assert-Equal (Get-RegistryValue "$verb\command") $expectedCommand "$extension verb command mismatch."
    }
    Assert-Equal (Get-RegistryValue "$registryRoot\ClipPlayer\Capabilities" 'ApplicationName') 'ClipPlayer' 'Capability name mismatch.'
    Assert-Equal (Get-RegistryValue "$registryRoot\ClipPlayer\Capabilities" 'ApplicationDescription') 'Fast local audio preview player' 'Capability description mismatch.'
    foreach ($extension in @('.wav', '.mp3', '.flac')) {
        Assert-Equal (Get-RegistryValue "$registryRoot\ClipPlayer\Capabilities\FileAssociations" $extension) 'ClipPlayer.Audio' "$extension capability mismatch."
    }
    $registeredValue = ($registryRoot -replace '^Registry::HKEY_CURRENT_USER\\', '') + '\ClipPlayer\Capabilities'
    Assert-Equal (Get-RegistryValue "$registryRoot\RegisteredApplications" 'ClipPlayer') $registeredValue 'RegisteredApplications mismatch.'
    Assert-Equal (Get-RegistryValue "$registryRoot\RegisteredApplications" 'OtherApplication') 'Other\Capabilities' 'Foreign RegisteredApplications value changed.'
    $shell = New-Object -ComObject WScript.Shell; $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        Assert-Equal $shortcut.TargetPath $hostExe 'Shortcut target mismatch.'
        Assert-Equal $shortcut.Arguments "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$launcher`"" 'Shortcut arguments mismatch.'
        Assert-Equal $shortcut.WorkingDirectory $install 'Shortcut working directory mismatch.'
    } finally {
        if ($null -ne $shortcut) { [Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null }
        if ($null -ne $shell) { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
    }
}
function Assert-ReparseEscapesRejected {
    $escapeTarget = Join-Path $env:LOCALAPPDATA ("ClipPlayer-installer-escape-{0}" -f [Guid]::NewGuid().ToString('N'))
    $junctionRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClipPlayer-installer-e2e-{0}" -f [Guid]::NewGuid().ToString('N'))
    $symlinkRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClipPlayer-installer-e2e-{0}" -f [Guid]::NewGuid().ToString('N'))
    $leafRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClipPlayer-installer-e2e-{0}" -f [Guid]::NewGuid().ToString('N'))
    $symlinkTarget = "$escapeTarget-symlink"; $leafTarget = "$escapeTarget-leaf"
    $junctionRegistry = $null; $symlinkRegistry = $null; $leafRegistry = $null
    try {
        $null = New-Item -ItemType Directory -Path $escapeTarget -Force
        $null = New-Item -ItemType Junction -Path $junctionRoot -Target $escapeTarget
        $junctionRegistry = "Registry::HKEY_CURRENT_USER\Software\ClipPlayerInstallerE2E\$([Guid]::NewGuid().ToString('N'))"
        if ((Invoke-Installer '' $junctionRoot (Join-Path $junctionRoot 'ClipPlayer') $junctionRegistry (Join-Path $junctionRoot 'ClipPlayer.lnk')) -eq 0) { throw 'Junction TestRoot escape was accepted.' }
        if (Test-Path -LiteralPath (Join-Path $escapeTarget 'ClipPlayer')) { throw 'Junction TestRoot escape modified its physical target.' }
        [IO.Directory]::Delete($junctionRoot)
        $null = New-Item -ItemType Directory -Path $symlinkTarget -Force
        $symlinkCreated = $false
        try { [ClipPlayerTestLinks]::CreateDirectory($symlinkRoot, $symlinkTarget); $symlinkCreated = $true }
        catch [ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -ne 1314) { throw }
            Write-Verbose 'Symbolic-link creation needs elevation; junction reparse checks remain mandatory.'
        }
        if ($symlinkCreated) {
            $symlinkRegistry = "Registry::HKEY_CURRENT_USER\Software\ClipPlayerInstallerE2E\$([Guid]::NewGuid().ToString('N'))"
            if ((Invoke-Installer '' $symlinkRoot (Join-Path $symlinkRoot 'ClipPlayer') $symlinkRegistry (Join-Path $symlinkRoot 'ClipPlayer.lnk')) -eq 0) { throw 'Symbolic-link TestRoot escape was accepted.' }
            if (Test-Path -LiteralPath (Join-Path $symlinkTarget 'ClipPlayer')) { throw 'Symbolic-link TestRoot escape modified its physical target.' }
            [IO.Directory]::Delete($symlinkRoot)
        }
        $null = New-Item -ItemType Directory -Path $leafRoot -Force
        $null = New-Item -ItemType Directory -Path $leafTarget -Force
        [IO.File]::WriteAllText((Join-Path $leafTarget 'outside.txt'), 'preserve', [Text.UTF8Encoding]::new($false))
        $null = New-Item -ItemType Junction -Path (Join-Path $leafRoot 'ClipPlayer') -Target $leafTarget
        $leafRegistry = "Registry::HKEY_CURRENT_USER\Software\ClipPlayerInstallerE2E\$([Guid]::NewGuid().ToString('N'))"
        if ((Invoke-Installer '' $leafRoot (Join-Path $leafRoot 'ClipPlayer') $leafRegistry (Join-Path $leafRoot 'ClipPlayer.lnk')) -eq 0) { throw 'Junction InstallDirectory escape was accepted.' }
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $leafTarget 'outside.txt'))) 'preserve' 'Junction leaf target was modified.'
    } finally {
        if ($null -ne $junctionRegistry) { Remove-Item -LiteralPath $junctionRegistry -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $symlinkRegistry) { Remove-Item -LiteralPath $symlinkRegistry -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $leafRegistry) { Remove-Item -LiteralPath $leafRegistry -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $junctionRoot) { [IO.Directory]::Delete($junctionRoot) }
        if (Test-Path -LiteralPath $symlinkRoot) { [IO.Directory]::Delete($symlinkRoot) }
        if (Test-Path -LiteralPath (Join-Path $leafRoot 'ClipPlayer')) { [IO.Directory]::Delete((Join-Path $leafRoot 'ClipPlayer')) }
        Remove-Item -LiteralPath $leafRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $escapeTarget -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $symlinkTarget -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $leafTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot -Force
    Assert-ReparseEscapesRejected
    $sourceHashes = Get-Hashes $sourceRoot
    $oldHashes = New-OldVersion
    Reset-IntegrationState
    $initialUserChoiceHash = Get-RegistryHash "$classesRoot\.wav\UserChoice"
    if ((Invoke-Installer '') -ne 0) { throw "Successful install failed: $([IO.File]::ReadAllText($stderr))" }
    $installedHashes = Get-Hashes $install
    foreach ($asset in $assets) { if ($installedHashes[$asset] -ne $sourceHashes[$asset]) { throw "Source/install hash mismatch: $asset" } }
    if ((Get-RegistryHash "$classesRoot\.wav\UserChoice") -ne $initialUserChoiceHash) { throw 'UserChoice changed during successful install.' }
    Assert-PositiveIntegration
    $successLeftovers = @(Get-ChildItem -LiteralPath $testRoot -Force | Where-Object { $_.Name -like '.ClipPlayer.*' })
    if ($successLeftovers.Count -ne 0) { throw "Successful install left transaction artifacts: $($successLeftovers[0].FullName)" }

    for ($phaseIndex = 0; $phaseIndex -lt $phases.Count; $phaseIndex++) {
        $phase = $phases[$phaseIndex]
        Write-Output "Installer fault-injection: $phase"
        $oldHashes = New-OldVersion
        Reset-IntegrationState
        if (($phaseIndex % 2) -eq 1) { Remove-Item -LiteralPath $shortcutPath -Force }
        $oldRegistryHash = Get-RegistryHash $registryRoot
        $oldRegistrySnapshot = @(Get-RegistrySnapshotLines $registryRoot)
        $oldUserChoiceHash = Get-RegistryHash "$classesRoot\.wav\UserChoice"
        $oldShortcutHash = Get-ShortcutHash
        if ((Invoke-Installer $phase) -eq 0) { throw "Fault injection did not fail at $phase." }
        Assert-OldVersion $oldHashes
        if ((Get-RegistryHash $registryRoot) -ne $oldRegistryHash) {
            $difference = Compare-Object $oldRegistrySnapshot @(Get-RegistrySnapshotLines $registryRoot) |
                ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
            throw "Registry rollback mismatch at $phase`: $($difference -join '; ')"
        }
        if ((Get-RegistryHash "$classesRoot\.wav\UserChoice") -ne $oldUserChoiceHash) { throw "UserChoice changed at $phase." }
        if ((Get-ShortcutHash) -ne $oldShortcutHash) { throw "Shortcut rollback mismatch at $phase." }
    }
    $oldHashes = New-OldVersion
    Reset-IntegrationState
    if ((Invoke-Installer 'RegistryConcurrentMutation') -eq 0) {
        throw 'Concurrent registry mutation fault did not fail.'
    }
    Assert-OldVersion $oldHashes
    foreach ($extension in @('.wav', '.mp3', '.flac')) {
        Assert-Equal (Get-RegistryValue "$classesRoot\$extension\OpenWithProgids" 'ClipPlayer.Audio') 7 "$extension ClipPlayer value was not rolled back."
        Assert-Equal (Get-RegistryValueKind "$classesRoot\$extension\OpenWithProgids" 'ClipPlayer.Audio') 'DWord' "$extension ClipPlayer value kind was not rolled back."
        Assert-Equal (Get-RegistryValue "$classesRoot\$extension\OpenWithProgids" 'Other.App') 'concurrent' "$extension concurrent foreign value was overwritten."
    }
    Assert-Equal (Get-RegistryValue "$registryRoot\RegisteredApplications" 'ClipPlayer') '%TEMP%\old\Capabilities' 'ClipPlayer RegisteredApplications value was not rolled back.'
    Assert-Equal (Get-RegistryValueKind "$registryRoot\RegisteredApplications" 'ClipPlayer') 'ExpandString' 'ClipPlayer RegisteredApplications value kind was not rolled back.'
    Assert-Equal (Get-RegistryValue "$registryRoot\RegisteredApplications" 'OtherApplication') 'Concurrent\Capabilities' 'Concurrent foreign RegisteredApplications value was overwritten.'

    $oldHashes = New-OldVersion
    Reset-IntegrationState
    if ((Invoke-Installer 'PreIntegrationConcurrentMutation') -eq 0) {
        throw 'Pre-integration concurrent mutation fault did not fail.'
    }
    Assert-OldVersion $oldHashes
    foreach ($extension in @('.wav', '.mp3', '.flac')) {
        Assert-Equal (Get-RegistryValue "$classesRoot\$extension\OpenWithProgids" 'Other.App') `
            'concurrent-before-integration' "$extension pre-integration mutation was overwritten."
        Assert-Equal (Get-RegistryValue "$classesRoot\$extension\OpenWithProgids" 'ClipPlayer.Audio') 7 `
            "$extension owned value changed before integration began."
    }
    Assert-Equal (Get-RegistryValue "$registryRoot\ClipPlayer\Capabilities" 'CustomValue') `
        'concurrent-before-integration' 'App-tree pre-integration mutation was overwritten.'
    Assert-Equal ([IO.File]::ReadAllText($shortcutPath)) 'concurrent-before-integration' `
        'Shortcut pre-integration mutation was overwritten.'
    $afterSourceHashes = Get-Hashes $sourceRoot
    foreach ($asset in $assets) { if ($afterSourceHashes[$asset] -ne $sourceHashes[$asset]) { throw "Installer changed source asset: $asset" } }
    Write-Output ("Installer atomic swap/fault-injection E2E: PASS ({0} phases + pre/post-integration concurrent mutations; registry data/kinds and source/install hashes verified)" -f $phases.Count)
}
finally {
    Remove-Item -LiteralPath $registryRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
