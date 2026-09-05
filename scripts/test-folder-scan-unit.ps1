[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$supportedExtensions = @('.wav', '.mp3', '.flac')
. (Join-Path $root 'src\ClipPlayer.Script\ClipPlayer.FolderMode.ps1')

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer folder scan-' + [Guid]::NewGuid().ToString('N'))
$literalFolder = Join-Path $fixtureRoot '%TEMP%'
$runspace = $null
$powerShell = $null
try {
    [IO.Directory]::CreateDirectory($literalFolder) | Out-Null
    foreach ($name in @('clip10.wav', 'clip2.mp3', 'notes.txt')) {
        $stream = [IO.File]::Create((Join-Path $literalFolder $name)); $stream.Dispose()
    }

    $resolved = Resolve-FolderPath $literalFolder
    if (-not [string]::Equals($resolved, [IO.Path]::GetFullPath($literalFolder),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Literal percent folder was changed to '$resolved'."
    }
    $expanded = Resolve-FolderPath '%TEMP%'
    $expectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not [string]::Equals($expanded.TrimEnd('\'), $expectedTemp,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Environment fallback did not resolve %TEMP%: '$expanded'."
    }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $powerShell = [PowerShell]::Create()
    $powerShell.Runspace = $runspace
    $null = $powerShell.AddScript($script:folderScanWorker.ToString()).
        AddArgument($literalFolder).AddArgument([string[]]$supportedExtensions).
        AddArgument('Name').AddArgument($false)
    $async = $powerShell.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw 'Folder scan worker timed out.' }
    $entries = @($powerShell.EndInvoke($async))
    if ($entries.Count -ne 2 -or ($entries | ForEach-Object Name) -join ',' -ne 'clip2.mp3,clip10.wav') {
        throw "Unexpected worker result: $(($entries | ForEach-Object Name) -join ',')"
    }
    Write-Output 'FOLDER SCAN UNIT PASS: literal paths, environment fallback, filtering and worker natural sort are valid.'
} finally {
    if ($null -ne $powerShell) { try { $powerShell.Dispose() } catch { } }
    if ($null -ne $runspace) { try { $runspace.Close(); $runspace.Dispose() } catch { } }
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedRoot = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if ($resolvedRoot -eq [IO.Path]::GetFullPath($fixtureRoot)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        }
    }
}

function Assert-FolderTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Wait-FolderTest {
    param([scriptblock] $Predicate, [int] $TimeoutMilliseconds = 30000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Predicate)) {
        Complete-FolderScanIfReady
        Complete-FolderSortIfReady
        if ($watch.ElapsedMilliseconds -gt $TimeoutMilliseconds) { throw 'Async folder test timed out.' }
        Start-Sleep -Milliseconds 10
    }
    $watch.Stop()
    return $watch.Elapsed.TotalMilliseconds
}

# Exercise the real UI-side handoff with small stand-ins. This verifies that a
# completed sort retains the selected entry, current playback path and status.
$selectedFolder = [PSCustomObject]@{ Name='folder'; Path='C:\fixture\folder'; IsFolder=$true }
$audioA = [PSCustomObject]@{ Name='a.wav'; Path='C:\fixture\a.wav'; IsFolder=$false }
$audioB = [PSCustomObject]@{ Name='b.wav'; Path='C:\fixture\b.wav'; IsFolder=$false }
$script:folderView = [PSCustomObject]@{ SelectedItem=$selectedFolder; ItemsSource=$null }
$script:folderView | Add-Member ScriptMethod ScrollIntoView { param($Item) }
$script:deleteButton = [PSCustomObject]@{ IsEnabled=$false }
$script:playlistControl = [PSCustomObject]@{ Items=[Collections.ArrayList]::new(); SelectedIndex=0 }
$script:folderModeEnabled = $true; $script:playlist = @($audioB.Path, $audioA.Path); $script:currentIndex = 0
$script:isPaused = $false; $script:statusText = [PSCustomObject]@{ Text='Folder sorting...' }
function Set-PreloadWindow { }
function Update-Controls { }
function Publish-Diagnostics { }
function Set-Status { param([string] $Text) $script:statusText.Text = $Text }
Apply-FolderSortResult @($selectedFolder, $audioA, $audioB) 'Playing b.wav'
Assert-FolderTest ((Get-CurrentPlaybackPath) -eq $audioB.Path) 'Sort handoff changed the current playback path.'
Assert-FolderTest ($script:currentIndex -eq 1) 'Sort handoff did not remap the current playback index.'
Assert-FolderTest ($script:folderView.SelectedItem.Path -eq $selectedFolder.Path) 'Sort handoff lost the selected folder.'
Assert-FolderTest ($script:statusText.Text -eq 'Playing b.wav') 'Sort handoff did not restore status.'

$script:appliedSorts = New-Object Collections.Generic.List[object]
function Apply-FolderSortResult {
    param([object[]] $Entries, [AllowNull()][string] $PreviousStatus)
    $script:folderEntries = @($Entries)
    $null = $script:appliedSorts.Add([PSCustomObject]@{
        Field=$script:folderSort; Descending=$script:folderDescending; Entries=@($Entries)
    })
    Set-Status $PreviousStatus
}
$script:folderPath = 'C:\fixture'; $script:folderScanGeneration = 7; $script:folderScan = $null
$script:folderWindowClosed = $false; $script:folderSort = 'Name'; $script:folderDescending = $false
$script:statusText.Text = 'Ready'; $script:folderSortTestDelayMilliseconds = 250
$largeEntries = foreach ($index in 5000..1) {
    [PSCustomObject]@{
        Name=('clip{0}.wav' -f $index); Path=('C:\fixture\clip{0}.wav' -f $index)
        IsFolder=$false; TypeSort='.wav'; Created=[datetime]::MinValue
        Modified=[datetime]::MinValue; Size=[long]$index
    }
}
$script:folderEntries = @($largeEntries)
$returnWatch = [Diagnostics.Stopwatch]::StartNew(); Start-FolderSort; $returnWatch.Stop()
$returnMilliseconds = $returnWatch.Elapsed.TotalMilliseconds
Assert-FolderTest ($returnMilliseconds -lt 500) "Starting a 5,000-entry sort blocked for $returnMilliseconds ms."
$largeWait = Wait-FolderTest { $script:appliedSorts.Count -eq 1 }
$largeResult = $script:appliedSorts[0].Entries
Assert-FolderTest ($largeResult.Count -eq 5000 -and $largeResult[0].Name -eq 'clip1.wav' -and
    $largeResult[-1].Name -eq 'clip5000.wav') 'Large async natural sort returned the wrong order.'
$metadataEntries = @(
    [PSCustomObject]@{Name='alpha.wav';IsFolder=$false;TypeSort='.wav';Created=[datetime]'2022-01-01';Modified=[datetime]'2025-01-01';Size=30},
    [PSCustomObject]@{Name='beta.mp3';IsFolder=$false;TypeSort='.mp3';Created=[datetime]'2020-01-01';Modified=[datetime]'2024-01-01';Size=20},
    [PSCustomObject]@{Name='gamma.flac';IsFolder=$false;TypeSort='.flac';Created=[datetime]'2021-01-01';Modified=[datetime]'2023-01-01';Size=10})
foreach ($sortProbe in @(
    [PSCustomObject]@{Field='Name';Descending=$true;Expected='gamma.flac'},
    [PSCustomObject]@{Field='Date created';Descending=$false;Expected='beta.mp3'},
    [PSCustomObject]@{Field='Date modified';Descending=$false;Expected='gamma.flac'},
    [PSCustomObject]@{Field='Type';Descending=$false;Expected='gamma.flac'},
    [PSCustomObject]@{Field='Size';Descending=$false;Expected='gamma.flac'})) {
    $probeResult = @(& $script:folderSortWorker $metadataEntries $sortProbe.Field $sortProbe.Descending 0)
    Assert-FolderTest ($probeResult[0].Name -eq $sortProbe.Expected) "Worker sort '$($sortProbe.Field)' ignored its primary key."
}

# Three rapid requests may finish in any worker order; only the last generation
# is allowed to reach the UI-side apply function.
$script:appliedSorts.Clear(); $script:folderEntries = @($largeEntries | Select-Object -First 250)
$script:folderSortTestDelayMilliseconds = 200
$script:folderSort='Name'; $script:folderDescending=$true; Start-FolderSort
$script:folderSort='Date modified'; $script:folderDescending=$false; Start-FolderSort
$script:folderSort='Size'; $script:folderDescending=$false; Start-FolderSort
$rapidWait = Wait-FolderTest { $script:appliedSorts.Count -eq 1 -and $null -eq $script:folderSortState }
Assert-FolderTest ($script:appliedSorts.Count -eq 1 -and $script:appliedSorts[0].Field -eq 'Size') `
    'A stale rapid-sort generation reached the apply function.'
Assert-FolderTest ($script:appliedSorts[0].Entries[0].Size -eq 4751) 'The last rapid sort did not determine the result.'
Assert-FolderTest ($script:statusText.Text -eq 'Ready') 'Rapid sort replacement lost the pre-sort status.'

# A real navigation request invalidates the delayed sort. Its late result must
# not replace the newly scanned folder content.
$navigationRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-sort-navigation-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $navigationRoot
    [IO.File]::WriteAllBytes((Join-Path $navigationRoot 'navigation.wav'), [byte[]](0, 1))
    $script:appliedSorts.Clear(); $script:folderEntries = @($largeEntries | Select-Object -First 250)
    $script:folderSortTestDelayMilliseconds = 350; Start-FolderSort
    $script:completedScanPath = $null
    function Complete-FolderScan {
        param([string] $Path, [object[]] $Entries, [AllowNull()][string] $InitialAudioPath)
        $script:completedScanPath = $Path; $script:folderPath = $Path; $script:folderEntries = @($Entries)
    }
    Start-FolderScan $navigationRoot
    $navigationWait = Wait-FolderTest { $script:completedScanPath -eq $navigationRoot -and $null -eq $script:folderScan }
    $null = Wait-FolderTest { $script:folderSortOrphans.Count -eq 0 }
    Assert-FolderTest ($script:appliedSorts.Count -eq 0) 'A pre-navigation sort rendered after navigation.'
    Assert-FolderTest ($script:folderEntries.Count -eq 1 -and $script:folderEntries[0].Name -eq 'navigation.wav') `
        'Navigation scan result was replaced or malformed.'
} finally {
    Stop-AllFolderWork
    if (Test-Path -LiteralPath $navigationRoot) { Remove-Item -LiteralPath $navigationRoot -Recurse -Force }
}

# The RunspacePool limits execution, not its submission queue. Reproduce the
# original 200-request/30-second worker burst and prove that only one retiring
# PowerShell plus one data-only latest request exist at any instant.
$originalScanWorker = $script:folderScanWorker
$script:completedScanPath = $null
$script:folderWindowClosed = $false
$null = Get-FolderRunspacePool
$testProcess = [Diagnostics.Process]::GetCurrentProcess(); $testProcess.Refresh()
$burstWarmHandles = $testProcess.HandleCount
$script:folderScanWorker = { param($ScanPath,$Extensions,$SortField,$Descending); Start-Sleep -Seconds 30 }
$burstWatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($request in 1..200) { Start-FolderScan ('C:\blocked\request-{0}' -f $request) }
$burstWatch.Stop(); $testProcess.Refresh()
$burstHandleGrowth = $testProcess.HandleCount - $burstWarmHandles
Assert-FolderTest ($burstWatch.ElapsedMilliseconds -lt 2000) "200 scan requests blocked for $($burstWatch.ElapsedMilliseconds) ms."
Assert-FolderTest ($script:folderScanOrphans.Count -le 1) "Scan retirement grew to $($script:folderScanOrphans.Count) states."
Assert-FolderTest ($null -eq $script:folderScan -and $null -ne $script:folderScanPending) `
    'A scan pipeline was submitted while the prior pipeline was still retiring.'
Assert-FolderTest ($script:folderScanPending.Path -eq 'C:\blocked\request-200') 'The scan queue did not retain only the latest request.'
Assert-FolderTest ($burstHandleGrowth -lt 100) "The bounded scan burst grew by $burstHandleGrowth handles."
$script:folderScanWorker = {
    param($ScanPath,$Extensions,$SortField,$Descending)
    [PSCustomObject]@{Name=[IO.Path]::GetFileName($ScanPath);Path=$ScanPath;IsFolder=$true}
}
$burstDrain = Wait-FolderTest { $script:completedScanPath -eq 'C:\blocked\request-200' -and
    $null -eq $script:folderScan -and $null -eq $script:folderScanPending -and $script:folderScanOrphans.Count -eq 0 }
$script:folderScanWorker = $originalScanWorker

# Sorting uses the same bounded latest-request-wins rule. A navigation then
# invalidates the outstanding sort, and shutdown drains every pipeline/pool.
$script:appliedSorts.Clear(); $script:folderEntries = @($metadataEntries)
$script:folderPath = 'C:\fixture'; $script:folderSortTestDelayMilliseconds = 30000
foreach ($request in 1..200) {
    $script:folderSort = if ($request -eq 200) { 'Size' } else { 'Name' }
    Start-FolderSort
}
Assert-FolderTest ($script:folderSortOrphans.Count -le 1) "Sort retirement grew to $($script:folderSortOrphans.Count) states."
Assert-FolderTest ($null -eq $script:folderSortState -and $null -ne $script:folderSortPending) `
    'A sort pipeline was submitted while the prior pipeline was still retiring.'
$script:folderSortTestDelayMilliseconds = 0
$script:folderSortPending.DelayMilliseconds = 0
$sortBurstDrain = Wait-FolderTest { $script:appliedSorts.Count -eq 1 -and $null -eq $script:folderSortState -and
    $null -eq $script:folderSortPending -and $script:folderSortOrphans.Count -eq 0 }
Assert-FolderTest ($script:appliedSorts[0].Field -eq 'Size') 'The rapid-sort queue did not apply only its latest request.'
$script:folderScanWorker = { param($ScanPath,$Extensions,$SortField,$Descending); Start-Sleep -Seconds 30 }
Start-FolderScan 'C:\blocked\window-close'
$shutdownWatch = [Diagnostics.Stopwatch]::StartNew(); Stop-AllFolderWork; $shutdownWatch.Stop()
$script:folderScanWorker = $originalScanWorker
Assert-FolderTest ($shutdownWatch.ElapsedMilliseconds -lt 2000) "Window-close drain blocked for $($shutdownWatch.ElapsedMilliseconds) ms."
Assert-FolderTest ($null -eq $script:folderScan -and $null -eq $script:folderScanPending -and
    $script:folderScanOrphans.Count -eq 0 -and $null -eq $script:folderSortState -and
    $null -eq $script:folderSortPending -and $script:folderSortOrphans.Count -eq 0 -and
    $null -eq $script:folderRunspacePool) 'Window-close drain retained folder work or the runspace pool.'
[GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 100
$testProcess.Refresh(); $burstClosedGrowth = $testProcess.HandleCount - $burstWarmHandles
Assert-FolderTest ($burstClosedGrowth -lt 50) "Burst shutdown retained $burstClosedGrowth handles."

# Regression guard for the runspace leak found by the 60-second E2E soak.
# A warm shared pool must remain bounded across repeated completed requests.
$script:folderEntries = @($metadataEntries); $script:folderScan = $null
$script:folderSortTestDelayMilliseconds = 0; $script:statusText.Text = 'Ready'
Start-FolderSort; $null = Wait-FolderTest { $null -eq $script:folderSortState }
$testProcess = [Diagnostics.Process]::GetCurrentProcess(); $testProcess.Refresh()
$warmHandles = $testProcess.HandleCount
foreach ($request in 1..50) {
    $script:folderDescending = ($request % 2 -eq 0)
    Start-FolderSort
    $null = Wait-FolderTest { $null -eq $script:folderSortState }
}
$testProcess.Refresh(); $activeHandleGrowth = $testProcess.HandleCount - $warmHandles
Stop-AllFolderWork; [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 100
$testProcess.Refresh(); $closedHandleGrowth = $testProcess.HandleCount - $warmHandles
Assert-FolderTest ($activeHandleGrowth -lt 80) "Shared folder pool leaked $activeHandleGrowth handles across 50 requests."
Assert-FolderTest ($closedHandleGrowth -lt 40) "Folder pool shutdown retained $closedHandleGrowth handles."

$sortSummary = ("FOLDER SORT ASYNC PASS: baseline-sync=7499.5ms/5000 (recorded repro), start-return={0:n1}ms, " +
    "large-completion={1:n1}ms, rapid-final-only={2:n1}ms, navigation-wins={3:n1}ms, " +
    "burst200={4:n1}ms/handles+{5}/drain={6:n1}ms, sort-burst-drain={7:n1}ms, handles50={8}; selection/playback/status preserved.") -f `
    $returnMilliseconds,$largeWait,$rapidWait,$navigationWait,$burstWatch.Elapsed.TotalMilliseconds,
    $burstHandleGrowth,$burstDrain,$sortBurstDrain,$activeHandleGrowth
Write-Output $sortSummary
