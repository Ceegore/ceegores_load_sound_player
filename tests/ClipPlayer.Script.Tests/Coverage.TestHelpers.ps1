Set-StrictMode -Version 2.0

$root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
. (Join-Path $root 'scripts\coverage-helpers.ps1')

function New-CoberturaFixture {
    param(
        [string] $Directory,
        [int] $LinesValid = 4,
        [int] $LinesCovered = 3,
        [int] $BranchesValid = 2,
        [int] $BranchesCovered = 1,
        [string] $ConditionCoverage = '50% (1/2)',
        [string] $ReportedLineRate,
        [string] $ReportedBranchRate
    )
    $lineRate = ([double]$LinesCovered / $LinesValid).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    $branchRate = ([double]$BranchesCovered / $BranchesValid).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    if (-not [string]::IsNullOrWhiteSpace($ReportedLineRate)) { $lineRate = $ReportedLineRate }
    if (-not [string]::IsNullOrWhiteSpace($ReportedBranchRate)) { $branchRate = $ReportedBranchRate }
    $path = Join-Path $Directory 'coverage.cobertura.xml'
    $xml = @"
<?xml version="1.0"?>
<coverage line-rate="$lineRate" branch-rate="$branchRate" lines-covered="$LinesCovered" lines-valid="$LinesValid" branches-covered="$BranchesCovered" branches-valid="$BranchesValid">
  <packages><package><classes><class><methods><method><lines>
    <line number="1" hits="1" branch="true"><conditions><condition number="0" type="jump" coverage="$ConditionCoverage" /></conditions></line>
  </lines></method></methods></class></classes></package></packages>
</coverage>
"@
    Set-Content -LiteralPath $path -Value $xml -Encoding utf8
    return $path
}

function New-JaCoCoFixture {
    param(
        [string] $Directory,
        [string] $Name = 'ClipPlayer.ps1',
        [int] $LinesCovered = 8,
        [int] $LinesMissed = 2,
        [int] $BranchesCovered = 6,
        [int] $BranchesMissed = 4,
        [switch] $OmitBranches
    )
    $path = Join-Path $Directory 'powershell-coverage.xml'
    $branchCounter = if ($OmitBranches) { '' } else {
        "  <counter type=`"BRANCH`" missed=`"$BranchesMissed`" covered=`"$BranchesCovered`" />"
    }
    $xml = @"
<?xml version="1.0"?>
<report name="Pester"><package name="ClipPlayer"><sourcefile name="$Name">
$branchCounter
  <counter type="LINE" missed="$LinesMissed" covered="$LinesCovered" />
</sourcefile></package></report>
"@
    Set-Content -LiteralPath $path -Value $xml -Encoding utf8
    return $path
}
