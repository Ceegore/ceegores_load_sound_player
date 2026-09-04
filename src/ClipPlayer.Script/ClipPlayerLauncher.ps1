[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $AudioPath,
    [string] $DiagnosticsPath,
    [string] $AutomationCommandPath,
    [switch] $BackgroundTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal }
catch { }

$playerScript = Join-Path $PSScriptRoot 'ClipPlayer.ps1'
if (-not (Test-Path -LiteralPath $playerScript -PathType Leaf)) { throw "Player script missing: $playerScript" }

& $playerScript -AudioPath $AudioPath -DiagnosticsPath $DiagnosticsPath `
    -AutomationCommandPath $AutomationCommandPath -BackgroundTest:$BackgroundTest
