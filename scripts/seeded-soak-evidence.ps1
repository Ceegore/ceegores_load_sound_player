Set-StrictMode -Version 2.0

function Test-SeededSoakPathWithin {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [string] $Root)
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SeededSoakDiagnosticTail {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [ValidateRange(1, 65536)] [int] $MaximumCharacters = 16384
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $content = [IO.File]::ReadAllText($Path)
    if ($content.Length -le $MaximumCharacters) { return $content }
    return $content.Substring($content.Length - $MaximumCharacters)
}

function Resolve-SeededSoakSummaryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RunRoot,
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [string] $RequestedPath,
        [Parameter(Mandatory = $true)] [string] $RunId,
        [switch] $KeepArtifacts
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidate = if ([IO.Path]::IsPathRooted($RequestedPath)) { $RequestedPath }
            else { Join-Path $RepositoryRoot $RequestedPath }
        $resolved = [IO.Path]::GetFullPath($candidate)
    } elseif ($KeepArtifacts) {
        $resolved = Join-Path ([IO.Path]::GetFullPath($RunRoot)) 'seeded-soak-summary.json'
    } else {
        $resolved = Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) `
            ("artifacts\seeded-soak\seeded-soak-summary-$RunId.json")
    }
    if (-not $KeepArtifacts -and (Test-SeededSoakPathWithin $resolved $RunRoot)) {
        throw 'SummaryPath must be outside the disposable run directory unless KeepArtifacts is set.'
    }
    return $resolved
}
