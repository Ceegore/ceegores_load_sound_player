Set-StrictMode -Version 2.0

function Resolve-PlaylistPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $BasePath
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Playlist path is empty.' }
    if ([string]::IsNullOrWhiteSpace($BasePath)) { throw 'Playlist path base is empty.' }
    $fullBase = [IO.Path]::GetFullPath($BasePath)
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { [IO.Path]::Combine($fullBase, $Path) }
    return [IO.Path]::GetFullPath($candidate)
}

function Get-UniqueExistingPlaylistPaths {
    [CmdletBinding()]
    param(
        [string[]] $Paths,
        [Parameter(Mandatory = $true)] [string] $BasePath,
        [Parameter(Mandatory = $true)] [string[]] $SupportedExtensions
    )
    $extensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $SupportedExtensions) { $null = $extensions.Add($extension) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unique = [Collections.Generic.List[string]]::new()
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            $fullPath = Resolve-PlaylistPath $path $BasePath
            if (-not $extensions.Contains([IO.Path]::GetExtension($fullPath))) { continue }
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            if ($seen.Add($fullPath)) { $null = $unique.Add($fullPath) }
        } catch { continue }
    }
    return @($unique.ToArray())
}
