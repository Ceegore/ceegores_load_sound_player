[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BuildDrop,
    [string]$Version = '0.1.0',
    [string]$PackageName = 'ClipPlayer',
    [string]$Namespace = 'https://sbom.clipplayer.invalid/',
    [string]$ToolPath
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$drop = (Resolve-Path $BuildDrop).Path
$toolVersion = '4.1.5'
$toolSha256 = '625767b371b7fdd58f40f618b8a86da0247a33c89e419039c86b4edba1dad4b5'
$toolUrl = "https://github.com/microsoft/sbom-tool/releases/download/v$toolVersion/sbom-tool-win-x64.exe"

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "SBOM-Gate: $Message" }
}

function Get-Sha256Hex {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Get-VerifiedTool {
    param([string]$RequestedPath)
    if ($RequestedPath) {
        $resolved = (Resolve-Path -LiteralPath $RequestedPath).Path
        Assert-Condition ((Get-Sha256Hex $resolved) -eq $toolSha256) "sbom-tool SHA-256 stimmt nicht mit v$toolVersion überein."
        return $resolved
    }
    $cache = Join-Path ([IO.Path]::GetTempPath()) "ClipPlayer\sbom-tool-v$toolVersion"
    $download = Join-Path $cache 'sbom-tool-win-x64.exe'
    $null = New-Item -ItemType Directory -Path $cache -Force
    if (-not (Test-Path -LiteralPath $download) -or (Get-Sha256Hex $download) -ne $toolSha256) {
        Invoke-WebRequest -Uri $toolUrl -OutFile $download -UseBasicParsing
    }
    Assert-Condition ((Get-Sha256Hex $download) -eq $toolSha256) "Download-Hash für sbom-tool v$toolVersion ist falsch."
    return $download
}

Assert-Condition (Test-Path -LiteralPath $drop -PathType Container) "Build-Drop fehlt: $drop"
Assert-Condition ($Namespace -match '^https?://') 'Namespace muss eine HTTPS/HTTP-URI sein.'
$tool = Get-VerifiedTool $ToolPath
$arguments = @('generate', '-b', $drop, '-bc', $root, '-pn', $PackageName, '-pv', $Version, '-ps', 'ClipPlayer', '-nsb', $Namespace, '-V', 'Verbose')
$quotedArguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
$process = Start-Process -FilePath $tool -ArgumentList $quotedArguments -WorkingDirectory $root -NoNewWindow -PassThru
try { $null = $process.Handle } catch { }
$deadline = [DateTime]::UtcNow.AddMinutes(10)
while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
if (-not $process.HasExited) {
    try { $process.Kill($true) } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    throw 'SBOM-Gate: sbom-tool überschritt das 10-Minuten-Timeout.'
}
$process.Refresh()
Assert-Condition ($process.ExitCode -eq 0) "sbom-tool v$toolVersion meldete Exit $($process.ExitCode)."

$manifests = @(Get-ChildItem -LiteralPath $drop -Recurse -Filter 'manifest.spdx.json' -File)
Assert-Condition ($manifests.Count -eq 1) "Erwartet genau eine manifest.spdx.json, gefunden: $($manifests.Count)."
$manifestPath = $manifests[0].FullName
try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { throw "SBOM-Gate: Manifest ist kein gültiges JSON: $manifestPath" }
Assert-Condition ($manifest.spdxVersion -in @('SPDX-2.2', 'SPDX-3.0')) 'SPDX-Version fehlt oder ist nicht unterstützt.'
Assert-Condition ($null -ne $manifest.creationInfo) 'creationInfo fehlt.'
Assert-Condition (@($manifest.packages).Count -gt 0) 'SBOM enthält keine Pakete.'
Write-Output "SBOM-Gate bestanden: $manifestPath (sbom-tool v$toolVersion, SHA-256 $toolSha256)"
