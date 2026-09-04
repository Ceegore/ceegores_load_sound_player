[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$supportedExtensions = @('.wav', '.mp3', '.flac')
. (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.FolderMode.ps1')

function New-ProbeEntry {
    param(
        [string] $Name,
        [bool] $IsFolder,
        [DateTime] $Created,
        [DateTime] $Modified,
        [string] $TypeSort,
        [long] $Size
    )
    return [PSCustomObject]@{
        Name = $Name; Path = Join-Path $root $Name; IsFolder = $IsFolder; IsDrive = $false
        Type = if ($IsFolder) { 'File folder' } else { 'Audio' }; TypeSort = $TypeSort
        Created = $Created; Modified = $Modified; Size = $Size
        CreatedText = ''; ModifiedText = ''; SizeText = ''
    }
}

function Assert-Order {
    param([string] $Field, [bool] $Descending, [string] $Expected)
    $script:folderSort = $Field
    $script:folderDescending = $Descending
    $actual = (Get-SortedFolderEntries $script:probeEntries | ForEach-Object Name) -join ','
    if ($actual -ne $Expected) { throw "$Field descending=$Descending order was '$actual', expected '$Expected'." }
}

$script:probeEntries = @(
    New-ProbeEntry 'folder-z' $true ([DateTime]'2025-01-01') ([DateTime]'2025-01-01') '' 0
    New-ProbeEntry 'clip10.wav' $false ([DateTime]'2020-01-01') ([DateTime]'2024-01-01') '.wav' 100
    New-ProbeEntry 'clip2.mp3' $false ([DateTime]'2022-01-01') ([DateTime]'2022-01-01') '.mp3' 300
    New-ProbeEntry 'clip1.flac' $false ([DateTime]'2021-01-01') ([DateTime]'2023-01-01') '.flac' 200
)

Assert-Order 'Name' $false 'folder-z,clip1.flac,clip2.mp3,clip10.wav'
Assert-Order 'Name' $true 'folder-z,clip10.wav,clip2.mp3,clip1.flac'
Assert-Order 'Date created' $false 'folder-z,clip10.wav,clip1.flac,clip2.mp3'
Assert-Order 'Date modified' $false 'folder-z,clip2.mp3,clip1.flac,clip10.wav'
Assert-Order 'Type' $false 'folder-z,clip1.flac,clip2.mp3,clip10.wav'
Assert-Order 'Size' $false 'folder-z,clip10.wav,clip1.flac,clip2.mp3'
if (-not (Test-SupportedPath 'sound.FLAC') -or (Test-SupportedPath 'notes.txt')) {
    throw 'Supported extension filtering failed.'
}
if ((Format-FileSize 1536) -notmatch 'KB') { throw 'File-size formatting failed.' }
Write-Output 'FOLDER UNIT PASS: filtering, natural order, metadata sorts and folder grouping are valid.'
