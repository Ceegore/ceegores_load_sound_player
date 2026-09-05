Set-StrictMode -Version 2.0

function ConvertTo-InvariantCoverageNumber {
    param([Parameter(Mandatory = $true)] [string] $Value, [string] $Name = 'coverage value')
    $parsed = 0.0
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "Cobertura $Name is not a valid invariant number: '$Value'."
    }
    return $parsed
}

function ConvertTo-CoberturaCount {
    param([Parameter(Mandatory = $true)] $Coverage, [Parameter(Mandatory = $true)] [string] $Name)
    $attribute = $Coverage.Attributes[$Name]
    $parsed = 0L
    if ($null -eq $attribute -or -not [long]::TryParse($attribute.Value,
            [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        throw "Cobertura root attribute '$Name' is missing or invalid."
    }
    return $parsed
}

function Get-CoberturaCoverageSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Project,
        [ValidateRange(0, 100)] [double] $MinimumLinePercent,
        [ValidateRange(0, 100)] [double] $MinimumBranchPercent
    )

    [xml]$report = Get-Content -LiteralPath $Path -Raw
    $coverage = $report.coverage
    if ($null -eq $coverage) { throw "Cobertura root element is missing: $Path" }

    $lineTotal = ConvertTo-CoberturaCount $coverage 'lines-valid'
    $lineHit = ConvertTo-CoberturaCount $coverage 'lines-covered'
    $branchTotal = ConvertTo-CoberturaCount $coverage 'branches-valid'
    $branchHit = ConvertTo-CoberturaCount $coverage 'branches-covered'
    if ($lineTotal -le 0 -or $lineHit -le 0 -or $lineHit -gt $lineTotal -or
        $branchTotal -le 0 -or $branchHit -le 0 -or $branchHit -gt $branchTotal) {
        throw "Coverage report is invalid or 0/0: $Path (lines=$lineHit/$lineTotal branches=$branchHit/$branchTotal)."
    }

    $reportedLineRate = ConvertTo-InvariantCoverageNumber ([string]$coverage.'line-rate') 'line-rate'
    $reportedBranchRate = ConvertTo-InvariantCoverageNumber ([string]$coverage.'branch-rate') 'branch-rate'
    $calculatedLineRate = [double]$lineHit / $lineTotal
    $calculatedBranchRate = [double]$branchHit / $branchTotal
    # Coverlet rounds the root rates to four decimals.  Reject internally
    # inconsistent reports instead of silently trusting either representation.
    if ([Math]::Abs($reportedLineRate - $calculatedLineRate) -gt 0.00011 -or
        [Math]::Abs($reportedBranchRate - $calculatedBranchRate) -gt 0.00011) {
        throw "Cobertura root rates disagree with covered/valid counts: $Path."
    }

    $linePercent = [Math]::Round(100 * $calculatedLineRate, 2)
    $branchPercent = [Math]::Round(100 * $calculatedBranchRate, 2)
    if ((100 * $calculatedLineRate) -lt $MinimumLinePercent) {
        throw "Coverage gate failed for $Project`: line coverage $linePercent% is below $MinimumLinePercent%."
    }
    if ((100 * $calculatedBranchRate) -lt $MinimumBranchPercent) {
        throw "Coverage gate failed for $Project`: branch coverage $branchPercent% is below $MinimumBranchPercent%."
    }

    return [PSCustomObject]@{
        project = $Project; report = $Path
        linesHit = $lineHit; linesTotal = $lineTotal; linePercent = $linePercent
        minimumLinePercent = $MinimumLinePercent
        branchesHit = $branchHit; branchesTotal = $branchTotal; branchPercent = $branchPercent
        minimumBranchPercent = $MinimumBranchPercent
    }
}

function Get-JaCoCoCount {
    param(
        [Parameter(Mandatory = $true)] $Counter,
        [Parameter(Mandatory = $true)] [ValidateSet('covered', 'missed')] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Context
    )
    $attribute = $Counter.Attributes[$Name]
    $parsed = 0L
    if ($null -eq $attribute -or -not [long]::TryParse($attribute.Value,
            [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed) -or $parsed -lt 0) {
        throw "JaCoCo $Context attribute '$Name' is missing, invalid, or negative."
    }
    return $parsed
}

function Get-PowerShellCoverageSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string[]] $ExpectedFiles,
        [ValidateRange(0, 100)] [double] $MinimumLinePercent = 10,
        [ValidateRange(0, 100)] [double] $MinimumBranchPercent = 5,
        [Collections.IDictionary] $FileMinimums = @{}
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "NOT-MEASURED: Pester did not produce a coverage report: $Path"
    }
    [xml]$report = Get-Content -LiteralPath $Path -Raw
    $sourceFiles = @($report.SelectNodes('//sourcefile'))
    if ($sourceFiles.Count -eq 0) { throw "NOT-MEASURED: Pester report has no source files: $Path" }
    $fileReports = New-Object Collections.Generic.List[object]
    $allLineHit = 0L; $allLineTotal = 0L; $allBranchHit = 0L; $allBranchTotal = 0L
    $allFilesHaveBranchCounters = $true
    foreach ($expected in $ExpectedFiles) {
        $name = [IO.Path]::GetFileName($expected)
        $source = @($sourceFiles | Where-Object {
            [string]::Equals([IO.Path]::GetFileName([string]$_.name), $name,
                [StringComparison]::OrdinalIgnoreCase)
        })
        if ($source.Count -ne 1) { throw "NOT-MEASURED: Pester report omitted or duplicated $name." }
        $lineCounter = $source[0].SelectSingleNode("./counter[@type='LINE']")
        $branchCounter = $source[0].SelectSingleNode("./counter[@type='BRANCH']")
        if ($null -eq $lineCounter) { throw "NOT-MEASURED: Pester report lacks a JaCoCo line counter for $name." }
        $lineHit = Get-JaCoCoCount $lineCounter covered "$name LINE"
        $lineMissed = Get-JaCoCoCount $lineCounter missed "$name LINE"
        $lineTotal = $lineHit + $lineMissed
        if ($lineTotal -le 0 -or $lineHit -le 0) {
            throw "NOT-MEASURED: PowerShell coverage for $name lacks non-zero line evidence (lines=$lineHit/$lineTotal)."
        }
        $fileLineMinimum = 1.0; $fileBranchMinimum = 1.0
        if ($FileMinimums.Contains($name)) {
            $floor = $FileMinimums[$name]
            $fileLineMinimum = [double]$floor.Line
            $fileBranchMinimum = [double]$floor.Branch
        }
        $rawLinePercent = 100.0 * $lineHit / $lineTotal
        if ($rawLinePercent -lt $fileLineMinimum) {
            throw "PowerShell coverage gate failed for $name`: lines $([Math]::Round($rawLinePercent, 2))%/$fileLineMinimum%."
        }
        $branchHit = $null; $branchTotal = $null; $rawBranchPercent = $null
        $branchStatus = 'NOT-MEASURED (Pester JaCoCo export has no BRANCH counter)'
        if ($null -ne $branchCounter) {
            $branchHit = Get-JaCoCoCount $branchCounter covered "$name BRANCH"
            $branchMissed = Get-JaCoCoCount $branchCounter missed "$name BRANCH"
            $branchTotal = $branchHit + $branchMissed
            if ($branchTotal -le 0 -or $branchHit -le 0) {
                throw "NOT-MEASURED: PowerShell branch coverage for $name lacks non-zero evidence (branches=$branchHit/$branchTotal)."
            }
            $rawBranchPercent = 100.0 * $branchHit / $branchTotal
            if ($rawBranchPercent -lt $fileBranchMinimum) {
                throw "PowerShell coverage gate failed for $name`: branches $([Math]::Round($rawBranchPercent, 2))%/$fileBranchMinimum%."
            }
            $branchStatus = 'MEASURED'
            $allBranchHit += $branchHit; $allBranchTotal += $branchTotal
        } else { $allFilesHaveBranchCounters = $false }
        $fileReports.Add([PSCustomObject]@{
            file = $expected; linesHit = $lineHit; linesTotal = $lineTotal
            linePercent = [Math]::Round($rawLinePercent, 2); minimumLinePercent = $fileLineMinimum
            branchesHit = $branchHit; branchesTotal = $branchTotal
            branchPercent = if ($null -eq $rawBranchPercent) { $null } else { [Math]::Round($rawBranchPercent, 2) }
            minimumBranchPercent = if ($null -eq $rawBranchPercent) { $null } else { $fileBranchMinimum }
            branchStatus = $branchStatus
        })
        $allLineHit += $lineHit; $allLineTotal += $lineTotal
    }
    $overallLinePercent = 100.0 * $allLineHit / $allLineTotal
    if ($overallLinePercent -lt $MinimumLinePercent) {
        throw "PowerShell coverage gate failed overall: lines $([Math]::Round($overallLinePercent, 2))%/$MinimumLinePercent%."
    }
    $overallBranchPercent = $null
    $overallBranchStatus = 'NOT-MEASURED (Pester JaCoCo export has no BRANCH counters)'
    if ($allFilesHaveBranchCounters) {
        $overallBranchPercent = 100.0 * $allBranchHit / $allBranchTotal
        if ($overallBranchPercent -lt $MinimumBranchPercent) {
            throw "PowerShell coverage gate failed overall: branches $([Math]::Round($overallBranchPercent, 2))%/$MinimumBranchPercent%."
        }
        $overallBranchStatus = 'MEASURED'
    }
    return [PSCustomObject]@{
        report = $Path; provider = 'Pester JaCoCo line coverage'
        linesHit = $allLineHit; linesTotal = $allLineTotal
        linePercent = [Math]::Round($overallLinePercent, 2); minimumLinePercent = $MinimumLinePercent
        branchesHit = if ($allFilesHaveBranchCounters) { $allBranchHit } else { $null }
        branchesTotal = if ($allFilesHaveBranchCounters) { $allBranchTotal } else { $null }
        branchPercent = if ($null -eq $overallBranchPercent) { $null } else { [Math]::Round($overallBranchPercent, 2) }
        minimumBranchPercent = if ($null -eq $overallBranchPercent) { $null } else { $MinimumBranchPercent }
        branchStatus = $overallBranchStatus
        files = @($fileReports.ToArray())
    }
}
