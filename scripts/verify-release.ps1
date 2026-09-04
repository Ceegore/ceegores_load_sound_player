[CmdletBinding()]
param(
    [ValidateSet('Core', 'Audio', 'App')]
    [string[]]$TestSuites = @('Core', 'Audio', 'App'),
    [switch]$IncludePerformance,
    [switch]$SkipTests,
    [string]$SbomToolPath,
    [string]$Version = '0.1.0'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runId = "{0:yyyyMMdd-HHmmss}-{1}" -f [DateTime]::UtcNow, $PID
$releaseRoot = Join-Path ([IO.Path]::GetTempPath()) "ClipPlayer\release-$runId"
$publish = Join-Path $releaseRoot 'publish'
$null = New-Item -ItemType Directory -Path $publish -Force
$sacBlocked = $false

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Release-Gate: $Message" }
}

function Invoke-NativeChecked {
    param([string]$FilePath, [string[]]$Arguments, [string]$Label)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Label fehlgeschlagen (Exit $LASTEXITCODE)." }
}

function Invoke-TestSuite {
    param([string]$Name)
    $filters = @{
        Core = 'FullyQualifiedName~ClipPlayer.Core.Tests'
        Audio = 'FullyQualifiedName~ClipPlayer.Audio.Windows.Tests'
        App = 'FullyQualifiedName~ClipPlayer.App.Tests'
    }
    $wrapper = Join-Path $root 'scripts\run-tests-sac-safe.ps1'
    $args = @('-NoProfile', '-File', $wrapper, '-Filter', $filters[$Name], '-SkipBuild')
    & powershell.exe @args
    $code = $LASTEXITCODE
    if ($code -eq 42) {
        Write-Warning "$Name-Testlauf ist wegen SAC/CodeIntegrity ein Umgebungs-Nicht-Ergebnis (Exit 42)."
        return 42
    }
    if ($code -eq 125) { throw "$Name-Testlauf ist inconclusive (kein verwertbarer ExitCode, Exit 125)." }
    if ($code -eq 3) { throw "$Name-Testfilter passte zu keinem Test (Exit 3)." }
    if ($code -ne 0) { throw "$Name-Testlauf fehlgeschlagen (Exit $code)." }
    return 0
}

function Invoke-StaticScriptChecks {
    $wrapperText = Get-Content (Join-Path $root 'scripts\run-tests-sac-safe.ps1') -Raw
    $stressText = Get-Content (Join-Path $root 'scripts\run-audio-stress.ps1') -Raw
    Assert-Condition ($wrapperText -match '\$null -eq \$exitCode') 'SAC-Wrapper muss null ExitCode als inconclusive behandeln.'
    Assert-Condition ($wrapperText -match 'exit 42') 'SAC-Wrapper benötigt den eindeutigen Exit 42.'
    Assert-Condition ($wrapperText -match '\[switch\]\$SkipBuild') 'SAC-Wrapper benötigt SkipBuild für einen einzelnen Build-Zyklus.'
    Assert-Condition ($stressText -match '\[Environment\]::ProcessorCount') 'Stress-Harness muss CPU-Anzahl berücksichtigen.'
    Assert-Condition ($stressText -match '\$CpuWorkerCap') 'Stress-Harness muss einen expliziten Worker-Cap besitzen.'
    $packageReadme = Get-Content (Join-Path $root 'packaging\ClipPlayer.Package\README.md') -Raw
    Assert-Condition ($packageReadme -notmatch '(?i)-ExecutionPolicy\s+Bypass') 'Dokumentation darf keinen ExecutionPolicy-Bypass empfehlen.'
    $releaseDocs = Get-Content (Join-Path $root 'docs\release\performance-and-trust-gates.md') -Raw
    Assert-Condition ($releaseDocs -match '(?i)Coverage ist ein separates Qualitäts-Gate') 'Coverage-Gate muss ausdrücklich getrennt dokumentiert sein.'
    Assert-Condition ($releaseDocs -match '(?i)behauptet keine Coverage') 'Release-Gate darf Coverage nicht als bestanden vortäuschen.'
    $scriptStress = Get-Content (Join-Path $root 'scripts\test-script-player-e2e.ps1') -Raw
    Assert-Condition ($scriptStress -notmatch 'AppActivate|SendKeys|SetFocus|InvokePattern') 'Skriptplayer-Dauerlauf darf den globalen Eingabefokus nicht verwenden.'
}

Invoke-StaticScriptChecks
Write-Output 'Release-Gate: source-only Skriptplayer-Selftest'
& powershell.exe -NoLogo -NoProfile -STA -File (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.ps1') -SelfTest
if ($LASTEXITCODE -ne 0) { throw "Skriptplayer-Selftest fehlgeschlagen (Exit $LASTEXITCODE)." }
Write-Output 'Release-Gate: locked restore'
Invoke-NativeChecked 'dotnet' @('restore', 'ClipPlayer.sln', '--locked-mode', '--nologo') 'Locked Restore'

$projects = [System.Collections.Generic.List[string]]::new()
$projects.Add('src\ClipPlayer.App\ClipPlayer.App.csproj')
$suiteProjects = @{
    Core = 'tests\ClipPlayer.Core.Tests\ClipPlayer.Core.Tests.csproj'
    Audio = 'tests\ClipPlayer.Audio.Windows.Tests\ClipPlayer.Audio.Windows.Tests.csproj'
    App = 'tests\ClipPlayer.App.Tests\ClipPlayer.App.Tests.csproj'
}
if (-not $SkipTests) { foreach ($suite in $TestSuites) { $projects.Add($suiteProjects[$suite]) } }
if ($IncludePerformance) { $projects.Add('tests\ClipPlayer.Performance.Tests\ClipPlayer.Performance.Tests.csproj') }

Write-Output 'Release-Gate: x64-orientierter Release-Build (WAP wird separat durch VS gebaut)'
foreach ($project in ($projects | Select-Object -Unique)) {
    $buildArgs = @('build', (Join-Path $root $project), '--configuration', 'Release', '--no-restore', '--nologo')
    if ($project -eq 'src\ClipPlayer.App\ClipPlayer.App.csproj') { $buildArgs += @('--runtime', 'win-x64') }
    # Test lockfiles intentionally remain RID-less; only the app/publish uses win-x64.
    Invoke-NativeChecked 'dotnet' $buildArgs "Release-Build $project"
}

if (-not $SkipTests) {
    foreach ($suite in $TestSuites) {
        if ((Invoke-TestSuite $suite) -eq 42) { $sacBlocked = $true }
    }
    if ($IncludePerformance) {
        & powershell.exe -NoProfile -File (Join-Path $root 'scripts\run-audio-stress.ps1') -Configuration Release -SkipBuild
        $performanceCode = $LASTEXITCODE
        if ($performanceCode -eq 42) { $sacBlocked = $true }
        elseif ($performanceCode -ne 0) { throw "Performance-Gate fehlgeschlagen (Exit $performanceCode)." }
    }
}

Write-Output 'Release-Gate: x64 self-contained publish ohne Symbole'
Invoke-NativeChecked 'dotnet' @('publish', (Join-Path $root 'src\ClipPlayer.App\ClipPlayer.App.csproj'), '--configuration', 'Release', '--runtime', 'win-x64', '--self-contained', 'true', '--no-restore', '--nologo', '-o', $publish, '-p:DebugSymbols=false', '-p:DebugType=None', '-p:IncludeSymbols=false', '-p:IncludeSource=false', '-p:PublishSymbols=false') 'Self-contained Publish'
Assert-Condition (Test-Path (Join-Path $publish 'ClipPlayer.App.exe')) 'Publish-Drop enthält keine ClipPlayer.App.exe.'
$forbidden = @(Get-ChildItem $publish -Recurse -File | Where-Object { $_.Extension -in @('.pdb', '.nupkg', '.snupkg', '.pfx', '.cer', '.key') })
Assert-Condition ($forbidden.Count -eq 0) ("Kundenartefakt enthält unerlaubte Dateien: " + (($forbidden | ForEach-Object FullName) -join ', '))

Write-Output 'Release-Gate: statische MSIX-/Asset-Prüfung'
& powershell.exe -NoProfile -File (Join-Path $root 'packaging\ClipPlayer.Package\Validate-Package.ps1')
if ($LASTEXITCODE -ne 0) { throw "MSIX-Static-Gate fehlgeschlagen (Exit $LASTEXITCODE)." }

Write-Output 'Release-Gate: SBOM erzeugen und validieren'
$sbomArgs = @('-NoProfile', '-File', (Join-Path $root 'scripts\generate-sbom.ps1'), '-BuildDrop', $publish, '-Version', $Version)
if ($SbomToolPath) { $sbomArgs += @('-ToolPath', $SbomToolPath) }
& powershell.exe @sbomArgs
if ($LASTEXITCODE -ne 0) { throw "SBOM-Gate fehlgeschlagen (Exit $LASTEXITCODE)." }
$remainingPdb = @(Get-ChildItem $publish -Recurse -Filter '*.pdb' -File -ErrorAction SilentlyContinue)
Assert-Condition ($remainingPdb.Count -eq 0) 'SBOM-Lauf darf keine PDB in den Kunden-Drop einbringen.'

Write-Warning 'Externe Gates bleiben offen, bis sie auf echter Windows-11-x64-Hardware geschlossen wurden:'
Write-Output '  MSIX: Visual Studio 2022 + Windows App SDK/MSIX-Targets, Release|x64 paketieren.'
Write-Output '  Trust: exakt signiertes MSIX mit CA-/Store-Vertrauen und signtool verify /pa /all.'
Write-Output '  SAC: signiertes Artefakt auf SAC-Enforcement-Rechner installieren und CodeIntegrity prüfen.'
Write-Output '  Hardware: WASAPI/Loopback, 15-Minuten-Lastlauf, Discontinuities und Wechsel-p95/p99 messen.'
Write-Output "Lokale Release-Gates bestanden; Drop: $publish"
if ($sacBlocked) {
    Write-Warning 'Lokale Tests waren wegen SAC blockiert; Exit 42 bedeutet inconclusive, nicht bestanden oder fehlgeschlagen.'
    exit 42
}
exit 0
