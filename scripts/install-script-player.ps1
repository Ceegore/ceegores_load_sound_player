[CmdletBinding()]
param(
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer'),
    [switch] $TestMode,
    [string] $TestRoot,
    [string] $IntegrationRegistryRoot,
    [string] $ShortcutPath,
    [Alias('FaultInjectionStep', 'TestFaultPhase')]
    [string] $FaultInjectionPhase,
    [switch] $SkipWindowsIntegration, [switch] $OpenDefaultAppSettings
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Load the signed-host verifier before any installer work so module auto-loading
# cannot race with another PowerShell process.
$signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue
if ($null -eq $signatureCommand) { $env:PSModulePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'; Import-Module Microsoft.PowerShell.Security -ErrorAction Stop; $signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue }
if ($null -eq $signatureCommand) { throw 'Microsoft.PowerShell.Security did not provide Get-AuthenticodeSignature.' }

if ($TestMode) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ClipPlayerPhysicalPath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    public static string Get(string path) {
        using (var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new IOException("Cannot open directory handle.", Marshal.GetLastWin32Error());
            var buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) throw new IOException("Cannot resolve physical directory path.", Marshal.GetLastWin32Error());
            string result = buffer.ToString();
            if (result.StartsWith(@"\\?\UNC\")) return @"\\" + result.Substring(8);
            return result.StartsWith(@"\\?\") ? result.Substring(4) : result;
        }
    }
}
'@
}

function Get-PhysicalDirectoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [ClipPlayerPhysicalPath]::Get([IO.Path]::GetFullPath($Path)).TrimEnd('\')
}
function Assert-NotReparsePoint {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name)
    if ((Test-Path -LiteralPath $Path) -and (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "$Name must not be a junction, symbolic link, or other reparse point: $Path"
    }
}

$defaultInstallDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\ClipPlayer'))
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
if (-not $InstallDirectory.Equals($defaultInstallDirectory, [StringComparison]::OrdinalIgnoreCase) -and -not $TestMode) {
    throw "ClipPlayer uses the fixed per-user install directory: $defaultInstallDirectory"
}
if ($TestMode) {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $InstallDirectory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TestMode installation must stay below the temporary directory: $tempRoot"
    }
}
if ($SkipWindowsIntegration -and -not $TestMode) { throw 'Skipping Windows integration is only available in TestMode.' }
if (-not [string]::IsNullOrWhiteSpace($FaultInjectionPhase) -and -not $TestMode) { throw 'Fault injection is only available in TestMode.' }; if ($OpenDefaultAppSettings -and $TestMode) { throw 'Opening Default Apps is unavailable in TestMode.' }

$tempDirectory = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($TestRoot)) { throw 'TestMode requires a dedicated TestRoot.' }
    if (-not (Test-Path -LiteralPath $TestRoot -PathType Container)) { throw "TestRoot is missing: $TestRoot" }
    $TestRoot = (Resolve-Path -LiteralPath $TestRoot).Path.TrimEnd('\')
    Assert-NotReparsePoint -Path $TestRoot -Name 'TestRoot'
    $testRootParent = Split-Path $TestRoot -Parent
    if (-not $testRootParent.Equals($tempDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $TestRoot -Leaf) -notmatch '^ClipPlayer-installer-e2e-[0-9a-f]{32}$') {
        throw 'TestRoot must be a canonical dedicated directory directly below the system temp directory.'
    }
    $physicalTemp = Get-PhysicalDirectoryPath $tempDirectory
    $physicalTestRoot = Get-PhysicalDirectoryPath $TestRoot
    if (-not (Split-Path $physicalTestRoot -Parent).Equals($physicalTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TestRoot physically escapes the system temp directory.'
    }
    $expectedTestInstall = Join-Path $TestRoot 'ClipPlayer'
    if (-not $InstallDirectory.Equals($expectedTestInstall, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TestMode InstallDirectory must be TestRoot\ClipPlayer.'
    }
    Assert-NotReparsePoint -Path $InstallDirectory -Name 'TestMode InstallDirectory'
    if (Test-Path -LiteralPath $InstallDirectory -PathType Container) {
        $physicalInstall = Get-PhysicalDirectoryPath $InstallDirectory
        if (-not (Split-Path $physicalInstall -Parent).Equals($physicalTestRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'TestMode InstallDirectory physically escapes TestRoot.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($IntegrationRegistryRoot) -or
        $IntegrationRegistryRoot -notmatch '^Registry::HKEY_CURRENT_USER\\Software\\ClipPlayerInstallerE2E\\[0-9a-f]{32}$') {
        throw 'TestMode requires an isolated IntegrationRegistryRoot.'
    }
    if ([string]::IsNullOrWhiteSpace($ShortcutPath) -or
        -not $ShortcutPath.Equals((Join-Path $TestRoot 'ClipPlayer.lnk'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TestMode ShortcutPath must be TestRoot\ClipPlayer.lnk.'
    }
}
$transactionParent = Split-Path $InstallDirectory -Parent
if ($TestMode -and -not $transactionParent.Equals($TestRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test transaction paths must remain directly below TestRoot.'
}

$root = Split-Path $PSScriptRoot -Parent
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$classesRoot = 'Registry::HKEY_CURRENT_USER\Software\Classes'
$capabilities = 'Registry::HKEY_CURRENT_USER\Software\ClipPlayer\Capabilities'
$registeredApplications = 'Registry::HKEY_CURRENT_USER\Software\RegisteredApplications'
$integrationShortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ClipPlayer.lnk'
if ($TestMode) {
    $classesRoot = "$IntegrationRegistryRoot\Classes"
    $capabilities = "$IntegrationRegistryRoot\ClipPlayer\Capabilities"
    $registeredApplications = "$IntegrationRegistryRoot\RegisteredApplications"
    $integrationShortcutPath = $ShortcutPath
}
$progId = 'ClipPlayer.Audio'
$extensions = @('.wav', '.mp3', '.flac')
$capabilityRoot = Split-Path $capabilities -Parent
# This manifest is the single source of truth for the complete runnable runtime.
$assetManifest = @(
    [pscustomobject]@{ Name = 'ClipPlayer.ps1'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.ps1' },
    [pscustomobject]@{ Name = 'ClipPlayer.FolderMode.ps1'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.FolderMode.ps1' },
    [pscustomobject]@{ Name = 'ClipPlayer.PlaybackState.ps1'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.PlaybackState.ps1' },
    [pscustomobject]@{ Name = 'ClipPlayer.FolderScanner.ps1'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.FolderScanner.ps1' },
    [pscustomobject]@{ Name = 'ClipPlayer.PlaylistPaths.ps1'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.PlaylistPaths.ps1' },
    [pscustomobject]@{ Name = 'ClipPlayerLauncher.ps1'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayerLauncher.ps1' },
    [pscustomobject]@{ Name = 'ClipPlayer.Window.xaml'; Source = Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.Window.xaml' }
)

function Get-NormalizedFaultPhase {
    param([string] $Phase)
    if ([string]::IsNullOrWhiteSpace($Phase)) { return '' }
    return (($Phase -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}
$faultPhaseAliases = @{
    stagecreated = 'StageCreated'; afterstagecreated = 'StageCreated'; stage = 'StageCreated'
    assetscopied = 'AssetsCopied'; afterassetscopied = 'AssetsCopied'; copy = 'AssetsCopied'; aftercopy = 'AssetsCopied'
    assetsvalidated = 'AssetsValidated'; afterassetsvalidated = 'AssetsValidated'; validation = 'AssetsValidated'; aftervalidation = 'AssetsValidated'
    backuprenamed = 'BackupRenamed'; afterbackuprenamed = 'BackupRenamed'; backuprename = 'BackupRenamed'
    stageswapped = 'StageSwapped'; afterstageswapped = 'StageSwapped'; stageswap = 'StageSwapped'; swap = 'StageSwapped'
    finalvalidated = 'FinalValidated'; afterfinalvalidated = 'FinalValidated'; finalvalidation = 'FinalValidated'
    registryupdated = 'RegistryUpdated'; afterregistryupdated = 'RegistryUpdated'; registry = 'RegistryUpdated'
    shortcutupdated = 'ShortcutUpdated'; aftershortcutupdated = 'ShortcutUpdated'; shortcut = 'ShortcutUpdated'
    backupremoved = 'BackupRemoved'; afterbackupremoved = 'BackupRemoved'; cleanup = 'BackupRemoved'
    backupcleanupmidway = 'BackupCleanupMidway'; duringbackupcleanup = 'BackupCleanupMidway'
    backupcleanuplocked = 'BackupCleanupLocked'; lockedbackupcleanup = 'BackupCleanupLocked'
    registryconcurrentmutation = 'RegistryConcurrentMutation'
    preintegrationconcurrentmutation = 'PreIntegrationConcurrentMutation'
}
$requestedFaultPhase = Get-NormalizedFaultPhase $FaultInjectionPhase
if ($TestMode -and $requestedFaultPhase -and -not $faultPhaseAliases.ContainsKey($requestedFaultPhase)) {
    throw "Unknown fault-injection phase '$FaultInjectionPhase'."
}
function Invoke-FaultInjection {
    param([Parameter(Mandatory = $true)][string] $Phase)
    if ($TestMode -and $requestedFaultPhase -and
        $faultPhaseAliases[$requestedFaultPhase] -eq 'PreIntegrationConcurrentMutation' -and
        $Phase -eq 'AssetsValidated') {
        foreach ($extension in $extensions) {
            Set-ItemProperty -LiteralPath "$classesRoot\$extension\OpenWithProgids" `
                -Name 'Other.App' -Value 'concurrent-before-integration'
        }
        Set-ItemProperty -LiteralPath "$capabilities" -Name 'CustomValue' `
            -Value 'concurrent-before-integration'
        (Get-Item -LiteralPath $integrationShortcutPath -Force).Attributes = [IO.FileAttributes]::Normal; [IO.File]::WriteAllText($integrationShortcutPath, 'concurrent-before-integration',
            [Text.UTF8Encoding]::new($false))
        throw 'Deterministic concurrent mutation injected before Windows integration.'
    }
    if ($TestMode -and $requestedFaultPhase -and
        $faultPhaseAliases[$requestedFaultPhase] -eq 'RegistryConcurrentMutation' -and
        $Phase -eq 'RegistryUpdated') {
        foreach ($extension in $extensions) {
            Set-ItemProperty -LiteralPath "$classesRoot\$extension\OpenWithProgids" -Name 'Other.App' -Value 'concurrent'
        }
        Set-ItemProperty -LiteralPath $registeredApplications -Name 'OtherApplication' -Value 'Concurrent\Capabilities'
        throw 'Deterministic concurrent-registry mutation injected after RegistryUpdated.'
    }
    if ($TestMode -and $requestedFaultPhase -and $faultPhaseAliases[$requestedFaultPhase] -eq $Phase) {
        throw "Deterministic installer fault injected after $Phase."
    }
}

function Get-AssetHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
function Assert-AssetSet {
    param([Parameter(Mandatory = $true)][string] $Directory, [Parameter(Mandatory = $true)][object[]] $Manifest,
        [Parameter(Mandatory = $true)][hashtable] $ExpectedHashes)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Asset directory is missing: $Directory" }
    $expectedNames = @($Manifest | ForEach-Object { $_.Name }); $actualFiles = @(Get-ChildItem -LiteralPath $Directory -File)
    if ($actualFiles.Count -ne $expectedNames.Count) { throw "Asset count mismatch in '$Directory'." }
    foreach ($file in $actualFiles) {
        if (@($expectedNames | Where-Object { $_.Equals($file.Name, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { throw "Unexpected installer asset: $($file.FullName)" }
    }
    $nested = @(Get-ChildItem -LiteralPath $Directory -Recurse -Force | Where-Object {
        ($_.PSIsContainer -and $_.FullName -ne $Directory) -or (-not $_.PSIsContainer -and $_.DirectoryName -ne $Directory)
    })
    if ($nested.Count -gt 0) { throw "Unexpected nested content in staged assets: $($nested[0].FullName)" }
    foreach ($asset in $Manifest) {
        $path = Join-Path $Directory $asset.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required asset is missing: $($asset.Name)" }
        if ((Get-AssetHash $path) -ne $ExpectedHashes[$asset.Name]) { throw "SHA-256 mismatch for $($asset.Name)." }
    }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory = $true)][string] $Directory)
    $rootPath = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    return @((Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length).TrimStart('\')
        if ($_.PSIsContainer) { "D|$relative" }
        else { "F|$relative|$($_.Length)|$([int]$_.Attributes)|$(Get-AssetHash $_.FullName)" }
    }))
}
function Assert-TreeSnapshot {
    param([Parameter(Mandatory = $true)][string] $Directory, [Parameter(Mandatory = $true)][object[]] $Expected)
    $actual = @(Get-TreeSnapshot $Directory)
    if ($actual.Count -ne $Expected.Count) { throw "Tree entry count mismatch in '$Directory'." }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($actual[$index] -cne $Expected[$index]) { throw "Tree snapshot mismatch in '$Directory' at entry $index." }
    }
}
function Remove-BackupForCommit {
    param([Parameter(Mandatory = $true)][string] $Directory)
    if ($requestedFaultPhase -and $faultPhaseAliases[$requestedFaultPhase] -eq 'BackupCleanupMidway') {
        $first = Get-ChildItem -LiteralPath $Directory -Force | Sort-Object Name | Select-Object -First 1
        if ($null -ne $first) { Remove-Item -LiteralPath $first.FullName -Recurse -Force }
        Invoke-FaultInjection 'BackupCleanupMidway'
    }
    if ($requestedFaultPhase -and $faultPhaseAliases[$requestedFaultPhase] -eq 'BackupCleanupLocked') {
        $candidate = Get-ChildItem -LiteralPath $Directory -Recurse -File -Force | Sort-Object FullName | Select-Object -Last 1
        if ($null -eq $candidate) { throw 'Locked-cleanup fault requires a backup file.' }
        $lock = [IO.File]::Open($candidate.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Remove-Item -LiteralPath $Directory -Recurse -Force }
        finally { $lock.Dispose() }
        throw 'Locked backup cleanup unexpectedly succeeded.'
    }
    Remove-Item -LiteralPath $Directory -Recurse -Force
}
function Remove-PostCommitArtifact {
    param([string] $Path)
    if ($null -eq $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force }
    catch { Write-Warning "Committed installation retained cleanup artifact '$Path': $($_.Exception.Message)" }
}
function Invoke-RollbackStep {
    param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[string]] $Errors)
    try { & $Action }
    catch { $Errors.Add("$Name`: $($_.Exception.Message)") }
}

function Remove-ClipPlayerIntegration {
    $progId = 'ClipPlayer.Audio'
    foreach ($extension in @('.wav', '.mp3', '.flac')) {
        Remove-ItemProperty -LiteralPath "$classesRoot\$extension\OpenWithProgids" -Name $progId -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath "$classesRoot\$progId" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $registeredApplications -Name 'ClipPlayer' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $capabilities -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path $capabilities -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $integrationShortcutPath -Force -ErrorAction SilentlyContinue
}
function Register-ClipPlayerIntegration {
    param([Parameter(Mandatory = $true)][string] $LauncherPath)
    $quotedHost = '"' + $powershellExe + '"'; $quotedScript = '"' + $LauncherPath + '"'; $openCommand = "$quotedHost -NoLogo -NoProfile -STA -WindowStyle Hidden -File $quotedScript `"%1`""
    $progId = 'ClipPlayer.Audio'; $extensions = @('.wav', '.mp3', '.flac')
    $null = New-Item -Path "$classesRoot\$progId\shell\open\command" -Force; Set-Item -LiteralPath "$classesRoot\$progId" -Value 'ClipPlayer audio file'; Set-Item -LiteralPath "$classesRoot\$progId\shell\open\command" -Value $openCommand
    $null = New-Item -Path "$classesRoot\$progId\DefaultIcon" -Force; Set-Item -LiteralPath "$classesRoot\$progId\DefaultIcon" -Value "$env:SystemRoot\System32\shell32.dll,-138"
    foreach ($extension in $extensions) {
        $openWith = "$classesRoot\$extension\OpenWithProgids"
        if (-not (Test-Path -LiteralPath $openWith)) { $null = New-Item -Path $openWith -Force }
        New-ItemProperty -Path $openWith -Name $progId -Value '' -PropertyType String -Force | Out-Null
        $verb = "$classesRoot\SystemFileAssociations\$extension\shell\ClipPlayer"; $null = New-Item -Path "$verb\command" -Force; Set-Item -LiteralPath $verb -Value 'Play with ClipPlayer'; New-ItemProperty -Path $verb -Name 'Icon' -Value "$env:SystemRoot\System32\shell32.dll,-138" -PropertyType String -Force | Out-Null; Set-Item -LiteralPath "$verb\command" -Value $openCommand
    }
    $null = New-Item -Path "$capabilities\FileAssociations" -Force; New-ItemProperty -Path $capabilities -Name 'ApplicationName' -Value 'ClipPlayer' -PropertyType String -Force | Out-Null; New-ItemProperty -Path $capabilities -Name 'ApplicationDescription' -Value 'Fast local audio preview player' -PropertyType String -Force | Out-Null
    foreach ($extension in $extensions) { New-ItemProperty -Path "$capabilities\FileAssociations" -Name $extension -Value $progId -PropertyType String -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $registeredApplications)) {
        $null = New-Item -Path $registeredApplications -Force
    }
    $registeredValue = if ($TestMode) { ($IntegrationRegistryRoot -replace '^Registry::HKEY_CURRENT_USER\\', '') + '\ClipPlayer\Capabilities' } else { 'Software\ClipPlayer\Capabilities' }
    New-ItemProperty -Path $registeredApplications -Name 'ClipPlayer' -Value $registeredValue -PropertyType String -Force | Out-Null
}
function Register-ClipPlayerShortcut {
    param([Parameter(Mandatory = $true)][string] $LauncherPath, [Parameter(Mandatory = $true)][string] $WorkingDirectory)
    $startMenu = Split-Path $integrationShortcutPath -Parent; $null = New-Item -ItemType Directory -Path $startMenu -Force
    Remove-Item -LiteralPath $integrationShortcutPath -Force -ErrorAction SilentlyContinue
    $shell = New-Object -ComObject WScript.Shell; $shortcut = $null
    try { $shortcut = $shell.CreateShortcut($integrationShortcutPath); $shortcut.TargetPath = $powershellExe; $shortcut.Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$LauncherPath`""; $shortcut.WorkingDirectory = $WorkingDirectory; $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,138"; $shortcut.Save() }
    finally { if ($null -ne $shortcut) { [Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null }; if ($null -ne $shell) { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } }
}

function Capture-RegistryTree {
    param([Parameter(Mandatory = $true)][string] $Path)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return [pscustomobject]@{ Path = $Path; Exists = $false; Values = @(); Children = @() } }
    $values = @($key.GetValueNames() | ForEach-Object {
        $name = [string]$_
        [pscustomobject]@{
            Name = $name; Kind = $key.GetValueKind($name).ToString()
            Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    })
    $children = @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
        Capture-RegistryTree (([string]$_.PSPath) -replace '^Microsoft\.PowerShell\.Core\\', '')
    })
    return [pscustomobject]@{ Path = $Path; Exists = $true; Values = $values; Children = $children }
}

function Restore-RegistryTree {
    param([Parameter(Mandatory = $true)]$Snapshot)
    Remove-Item -LiteralPath $Snapshot.Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $Snapshot.Exists) { return }
    $null = New-Item -Path $Snapshot.Path -Force
    foreach ($value in $Snapshot.Values) {
        Set-RegistrySnapshotValue -Path $Snapshot.Path -Name $value.Name -Value $value.Value -Kind $value.Kind
    }
    foreach ($child in $Snapshot.Children) { Restore-RegistryTree $child }
}

function Set-RegistrySnapshotValue {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Name,
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)][string] $Kind
    )
    if ($Path -notmatch '^(?:Microsoft\.PowerShell\.Core\\)?Registry::HKEY_CURRENT_USER\\(.+)$') { throw "Unsupported registry snapshot path: $Path" }
    $subKey = $Matches[1]
    $registryKind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse(
        [Microsoft.Win32.RegistryValueKind], $Kind, $true))
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Default); $key = $null
    try { $key = $baseKey.CreateSubKey($subKey); $key.SetValue($Name, $Value, $registryKind) }
    finally { if ($null -ne $key) { $key.Dispose() }; $baseKey.Dispose() }
}

function Capture-RegistryValue {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) {
        return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Value = $null; Kind = $null }
    }
    return [pscustomobject]@{
        Path = $Path; Name = $Name; Exists = $true; Kind = $key.GetValueKind($Name).ToString()
        Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
}

function Restore-RegistryValue {
    param([Parameter(Mandatory = $true)] $Snapshot)
    $current = Capture-RegistryValue -Path $Snapshot.Path -Name $Snapshot.Name
    if (-not $Snapshot.Exists -and -not $current.Exists) { return }
    if ($Snapshot.Exists -and $current.Exists -and $Snapshot.Kind -eq $current.Kind -and
        [object]::Equals($Snapshot.Value, $current.Value)) { return }
    if (-not $Snapshot.Exists) {
        Remove-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -ErrorAction SilentlyContinue
        return
    }
    Set-RegistrySnapshotValue -Path $Snapshot.Path -Name $Snapshot.Name `
        -Value $Snapshot.Value -Kind $Snapshot.Kind
}

$integrationRegistryRoots = @(
    "$classesRoot\$progId",
    "$classesRoot\SystemFileAssociations\.wav\shell\ClipPlayer",
    "$classesRoot\SystemFileAssociations\.mp3\shell\ClipPlayer",
    "$classesRoot\SystemFileAssociations\.flac\shell\ClipPlayer",
    $capabilityRoot
)
$integrationRegistryValues = @(
    [pscustomobject]@{ Path = "$classesRoot\.wav\OpenWithProgids"; Name = $progId },
    [pscustomobject]@{ Path = "$classesRoot\.mp3\OpenWithProgids"; Name = $progId },
    [pscustomobject]@{ Path = "$classesRoot\.flac\OpenWithProgids"; Name = $progId },
    [pscustomobject]@{ Path = $registeredApplications; Name = 'ClipPlayer' }
)
$stageDirectory = $null; $backupDirectory = $null; $rollbackDirectory = $null; $backupMoved = $false
$newTreeInstalled = $false; $hadPreviousInstallation = $false; $integrationSnapshotDirectory = $null
$integrationSnapshots = @(); $integrationValueSnapshots = @(); $shortcutSnapshotPath = $null; $shortcutSnapshotExists = $false; $shortcutSnapshotAttributes = $null
$oldTreeSnapshot = @(); $committed = $false; $integrationTouched = $false; $shortcutTouched = $false
try {
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    if ((Get-AuthenticodeSignature -LiteralPath $powershellExe).Status -ne 'Valid') { throw 'The Windows PowerShell host is not validly Microsoft-signed.' }
    $parentDirectory = Split-Path $InstallDirectory -Parent; if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $parentDirectory -Force }
    $suffix = [Guid]::NewGuid().ToString('N'); $stageDirectory = Join-Path $parentDirectory ".ClipPlayer.stage.$suffix"; $backupDirectory = Join-Path $parentDirectory ".ClipPlayer.backup.$suffix"; $rollbackDirectory = Join-Path $parentDirectory ".ClipPlayer.rollback.$suffix"; $hadPreviousInstallation = Test-Path -LiteralPath $InstallDirectory -PathType Container
    if ($hadPreviousInstallation) { $oldTreeSnapshot = @(Get-TreeSnapshot $InstallDirectory) }
    if (-not $SkipWindowsIntegration) {
        $integrationSnapshotDirectory = Join-Path $parentDirectory ".ClipPlayer.integration.$suffix"
        $null = New-Item -ItemType Directory -Path $integrationSnapshotDirectory -Force
        foreach ($registryRoot in $integrationRegistryRoots) { $integrationSnapshots += Capture-RegistryTree $registryRoot }
        foreach ($registryValue in $integrationRegistryValues) {
            $integrationValueSnapshots += Capture-RegistryValue -Path $registryValue.Path -Name $registryValue.Name
        }
        $shortcutSnapshotPath = Join-Path $integrationSnapshotDirectory 'ClipPlayer.lnk'
        if (Test-Path -LiteralPath $integrationShortcutPath -PathType Leaf) { Copy-Item -LiteralPath $integrationShortcutPath -Destination $shortcutSnapshotPath -Force; $shortcutSnapshotAttributes = (Get-Item -LiteralPath $integrationShortcutPath -Force).Attributes; $shortcutSnapshotExists = $true }
    }
    $sourceHashes = @{}
    foreach ($asset in $assetManifest) { if (-not (Test-Path -LiteralPath $asset.Source -PathType Leaf)) { throw "Required asset is missing: $($asset.Source)" }; $sourceHashes[$asset.Name] = Get-AssetHash $asset.Source }
    $null = New-Item -ItemType Directory -Path $stageDirectory -Force; Invoke-FaultInjection 'StageCreated'
    foreach ($asset in $assetManifest) { Copy-Item -LiteralPath $asset.Source -Destination (Join-Path $stageDirectory $asset.Name) -Force }; Invoke-FaultInjection 'AssetsCopied'
    foreach ($asset in $assetManifest) { if ((Get-AssetHash $asset.Source) -ne $sourceHashes[$asset.Name]) { throw "Source asset changed during staging: $($asset.Name)" } }
    Assert-AssetSet -Directory $stageDirectory -Manifest $assetManifest -ExpectedHashes $sourceHashes; Invoke-FaultInjection 'AssetsValidated'
    if ($hadPreviousInstallation) { [IO.Directory]::Move($InstallDirectory, $backupDirectory); $backupMoved = $true; Assert-TreeSnapshot $backupDirectory $oldTreeSnapshot }; Invoke-FaultInjection 'BackupRenamed'
    [IO.Directory]::Move($stageDirectory, $InstallDirectory); $newTreeInstalled = $true; $stageDirectory = $null; Invoke-FaultInjection 'StageSwapped'
    Assert-AssetSet -Directory $InstallDirectory -Manifest $assetManifest -ExpectedHashes $sourceHashes; Invoke-FaultInjection 'FinalValidated'
    if (-not $SkipWindowsIntegration) {
        # Set the marker before the first write so a partial function failure
        # is rolled back, while failures in earlier staging phases never
        # overwrite integration state changed concurrently by another actor.
        $integrationTouched = $true
        Register-ClipPlayerIntegration -LauncherPath (Join-Path $InstallDirectory 'ClipPlayerLauncher.ps1')
    }
    Invoke-FaultInjection 'RegistryUpdated'
    if (-not $SkipWindowsIntegration) {
        $shortcutTouched = $true
        Register-ClipPlayerShortcut -LauncherPath (Join-Path $InstallDirectory 'ClipPlayerLauncher.ps1') -WorkingDirectory $InstallDirectory
    }
    Invoke-FaultInjection 'ShortcutUpdated'
    if ($backupMoved) {
        Copy-Item -LiteralPath $backupDirectory -Destination $rollbackDirectory -Recurse -Force
        Assert-TreeSnapshot $rollbackDirectory $oldTreeSnapshot
        Remove-BackupForCommit $backupDirectory
        $backupMoved = $false
    }
    Invoke-FaultInjection 'BackupRemoved'
    # No rollback-requiring operation is allowed after this commit point.
    # Cleanup errors retain hidden recovery artifacts but do not invalidate the installed product.
    $committed = $true
    Remove-PostCommitArtifact $rollbackDirectory
    Remove-PostCommitArtifact $integrationSnapshotDirectory
    Write-Output "Installed ClipPlayer to $(Join-Path $InstallDirectory 'ClipPlayer.ps1')"; if (-not $SkipWindowsIntegration) { Write-Output 'Windows integration registered for WAV, MP3 and FLAC without changing the current default app.' }; if ($OpenDefaultAppSettings) { Start-Process 'ms-settings:defaultapps' }
}
catch {
    $failure = $_
    $rollbackErrors = New-Object 'Collections.Generic.List[string]'
    Invoke-RollbackStep 'remove new installation' {
        if ($newTreeInstalled -and (Test-Path -LiteralPath $InstallDirectory)) { Remove-Item -LiteralPath $InstallDirectory -Recurse -Force }
    } $rollbackErrors
    Invoke-RollbackStep 'restore previous installation' {
        if ($hadPreviousInstallation) {
            if (Test-Path -LiteralPath $InstallDirectory -PathType Container) {
                if ($newTreeInstalled) { throw 'New installation could not be removed.' }
            } else {
                $restoreSource = if (Test-Path -LiteralPath $rollbackDirectory -PathType Container) { $rollbackDirectory } else { $backupDirectory }
                if (-not (Test-Path -LiteralPath $restoreSource -PathType Container)) { throw 'No complete recovery tree is available.' }
                [IO.Directory]::Move($restoreSource, $InstallDirectory)
            }
            Assert-TreeSnapshot $InstallDirectory $oldTreeSnapshot
        }
    } $rollbackErrors
    if (-not $SkipWindowsIntegration -and $integrationTouched) {
        foreach ($registrySnapshot in $integrationSnapshots) {
            $snapshot = $registrySnapshot
            Invoke-RollbackStep "restore registry $($snapshot.Path)" { Restore-RegistryTree $snapshot } $rollbackErrors
        }
        foreach ($registryValueSnapshot in $integrationValueSnapshots) {
            $snapshot = $registryValueSnapshot
            Invoke-RollbackStep "restore registry value $($snapshot.Path)::$($snapshot.Name)" {
                Restore-RegistryValue $snapshot
            } $rollbackErrors
        }
    }
    if (-not $SkipWindowsIntegration -and $shortcutTouched) {
        Invoke-RollbackStep 'restore shortcut' {
            if ($shortcutSnapshotExists) {
                if (-not (Test-Path -LiteralPath $shortcutSnapshotPath -PathType Leaf)) { throw 'Shortcut snapshot is missing.' }
                $null = New-Item -ItemType Directory -Path (Split-Path $integrationShortcutPath -Parent) -Force
                Copy-Item -LiteralPath $shortcutSnapshotPath -Destination $integrationShortcutPath -Force
                (Get-Item -LiteralPath $integrationShortcutPath -Force).Attributes = $shortcutSnapshotAttributes
            } else { Remove-Item -LiteralPath $integrationShortcutPath -Force -ErrorAction SilentlyContinue }
        } $rollbackErrors
    }
    Invoke-RollbackStep 'remove staging tree' { if ($null -ne $stageDirectory -and (Test-Path -LiteralPath $stageDirectory)) { Remove-Item -LiteralPath $stageDirectory -Recurse -Force } } $rollbackErrors
    if ($rollbackErrors.Count -eq 0) {
        Remove-PostCommitArtifact $backupDirectory
        Remove-PostCommitArtifact $rollbackDirectory
        Remove-PostCommitArtifact $integrationSnapshotDirectory
        throw $failure
    }
    $details = [string]::Join('; ', $rollbackErrors.ToArray())
    throw "Installer failed: $($failure.Exception.Message) Rollback also reported: $details"
}
finally {
    if ($null -ne $stageDirectory -and (Test-Path -LiteralPath $stageDirectory -PathType Container)) { Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    if ($committed) { Remove-PostCommitArtifact $rollbackDirectory; Remove-PostCommitArtifact $integrationSnapshotDirectory }
}
