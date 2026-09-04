[CmdletBinding()]
param([int]$Maximum = 500)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$excluded = '\\(bin|obj|\.git|TestResults|artifacts|coverage)\\'
$violations = @(
    Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
        $_.FullName -notmatch $excluded -and $_.Extension -in @('.cs', '.csproj', '.props', '.targets', '.md', '.ps1', '.json', '.xml', '.config', '.editorconfig', '.sln')
    } | ForEach-Object {
        $count = (Get-Content -LiteralPath $_.FullName).Count
        if ($count -gt $Maximum) { [PSCustomObject]@{ File = $_.FullName; Lines = $count } }
    }
)
if ($violations.Count -gt 0) {
    $violations | Format-Table -AutoSize | Out-String | Write-Error
    exit 1
}
Write-Output "Line limit OK: <= $Maximum physical lines"
exit 0
