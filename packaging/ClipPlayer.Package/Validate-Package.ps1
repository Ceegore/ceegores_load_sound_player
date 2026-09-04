param(
    [string]$ProjectDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Packaging-Gate: $Message" }
}

$manifestPath = Join-Path $ProjectDirectory 'Package.appxmanifest'
$projectPath = Join-Path $ProjectDirectory 'ClipPlayer.Package.wapproj'
$assetDirectory = Join-Path $ProjectDirectory 'Assets'
Assert-Condition (Test-Path -LiteralPath $manifestPath) 'Manifest fehlt.'
Assert-Condition (Test-Path -LiteralPath $projectPath) 'WAP-Projekt fehlt.'

[xml]$manifest = Get-Content -LiteralPath $manifestPath
$namespaces = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
$namespaces.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$namespaces.AddNamespace('u', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
$family = $manifest.SelectSingleNode('//f:TargetDeviceFamily', $namespaces)
Assert-Condition ($null -ne $family) 'TargetDeviceFamily fehlt.'
Assert-Condition ($family.Name -eq 'Windows.Desktop') 'Nur Windows.Desktop ist erlaubt.'
Assert-Condition ($family.MinVersion -eq '10.0.22621.0') 'Mindestversion ist nicht Windows 11 22H2 (22621).'

$association = $manifest.SelectSingleNode('//u:FileTypeAssociation', $namespaces)
Assert-Condition ($null -ne $association) 'FileTypeAssociation fehlt.'
$extensions = @($association.SelectNodes('./u:SupportedFileTypes/u:FileType', $namespaces) | ForEach-Object InnerText)
$expectedExtensions = @('.wav', '.mp3', '.flac')
Assert-Condition (($extensions.Count -eq 3) -and ((@($extensions | Sort-Object) -join '|') -ceq (@($expectedExtensions | Sort-Object) -join '|'))) 'Es müssen genau .wav, .mp3 und .flac registriert sein.'

$projectText = Get-Content -LiteralPath $projectPath -Raw
Assert-Condition ($projectText -match '<PlatformTarget>x64</PlatformTarget>') 'PlatformTarget x64 fehlt.'
Assert-Condition ($projectText -match '<AppxBundlePlatforms>x64</AppxBundlePlatforms>') 'AppxBundlePlatforms x64 fehlt.'
Assert-Condition ($projectText -match '<AppxPackageSigningEnabled>false</AppxPackageSigningEnabled>') 'Repository darf nicht signieren.'
Assert-Condition ($projectText -notmatch 'windows\.fileExplorerContextMenus|IExplorerCommand|com:Extension') 'Shell-COM-Kontextmenü ist nicht Bestandteil von V1.'

$svgFiles = @(Get-ChildItem -LiteralPath $assetDirectory -Filter '*.svg' -File -ErrorAction SilentlyContinue)
Assert-Condition ($svgFiles.Count -eq 0) 'SVG-Platzhalter sind unzulässig.'

$baseSizes = @{
    'StoreLogo' = 50
    'Square44x44Logo' = 44
    'Square150x150Logo' = 150
}
$scales = @{
    'scale-100' = 1.00
    'scale-125' = 1.25
    'scale-150' = 1.50
    'scale-200' = 2.00
    'scale-300' = 3.00
    'scale-400' = 4.00
}
foreach ($name in $baseSizes.Keys) {
    foreach ($suffix in @('', '.scale-100', '.scale-125', '.scale-150', '.scale-200', '.scale-300', '.scale-400')) {
        $assetPath = Join-Path $assetDirectory "$name$suffix.png"
        Assert-Condition (Test-Path -LiteralPath $assetPath) "$name$suffix.png fehlt."
        $bitmap = [Drawing.Bitmap]::new($assetPath)
        try {
            $expectedSize = if ($suffix -eq '') { $baseSizes[$name] } else { [int][Math]::Round($baseSizes[$name] * $scales[$suffix.TrimStart('.')]) }
            Assert-Condition (($bitmap.Width -eq $expectedSize) -and ($bitmap.Height -eq $expectedSize)) "$name$suffix.png hat falsche Pixelgröße."
            Assert-Condition ($bitmap.RawFormat.Guid -eq [Drawing.Imaging.ImageFormat]::Png.Guid) "$name$suffix.png ist kein PNG."
        } finally {
            $bitmap.Dispose()
        }
    }
}

$visualElements = $manifest.SelectSingleNode('//u:VisualElements', $namespaces)
$manifestPaths = @(
    $manifest.Package.Properties.Logo
    $visualElements.Square150x150Logo
    $visualElements.Square44x44Logo
    $association.Logo
)
foreach ($path in $manifestPaths) {
    Assert-Condition ($null -ne $path) 'Manifest verweist auf ein leeres Asset.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $ProjectDirectory ($path -replace '/', '\'))) "Manifest-Asset fehlt: $path"
}

Write-Output "Packaging static gate passed: $($baseSizes.Count * 7) PNG variants, XML and x64 configuration verified."
