$script:folderModeEnabled = $false
$script:folderPath = $null
$script:folderEntries = @()
$script:folderAudioCount = 0
$script:folderSort = 'Name'
$script:folderDescending = $false
$script:folderScanGeneration = 0
$script:folderScan = $null
$script:folderScanPending = $null
$script:folderWindowClosed = $false
$script:folderScanOrphans = New-Object Collections.Generic.List[object]
$script:folderSortGeneration = 0
$script:folderSortState = $null
$script:folderSortPending = $null
$script:folderSortOrphans = New-Object Collections.Generic.List[object]
$script:folderSortTestDelayMilliseconds = 0
$script:folderRunspacePool = $null

function Test-SupportedPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return $supportedExtensions -contains [IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Convert-TimeText {
    param([TimeSpan] $Value)
    if ($Value.TotalHours -ge 1) { return $Value.ToString('h\:mm\:ss') }
    return $Value.ToString('m\:ss')
}

function Get-NaturalSortKey {
    param([string] $Path)
    return [regex]::Replace([IO.Path]::GetFileName($Path), '\d+', {
        param($match)
        $digits = $match.Value.TrimStart('0'); if ($digits.Length -eq 0) { $digits = '0' }
        return ('{0:D8}:{1}' -f $digits.Length, $digits)
    })
}

function New-WindowFromXaml {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    try { return [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
}

function Format-FileSize {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Set-PlaylistDisplay {
    param([string[]] $Paths)
    $labels = [string[]]@($Paths | ForEach-Object { [IO.Path]::GetFileName($_) })
    $itemsSourceProperty = $script:playlistControl.PSObject.Properties['ItemsSource']
    if ($null -ne $itemsSourceProperty) {
        $wasInternal = $script:internalSelection; $script:internalSelection = $true
        try {
            $script:playlistControl.ItemsSource = $null
            $script:playlistControl.ItemsSource = $labels
        } finally { $script:internalSelection = $wasInternal }
        return
    }
    $script:playlistControl.Items.Clear()
    foreach ($label in $labels) { $null = $script:playlistControl.Items.Add($label) }
}

$folderScannerScript = Join-Path $PSScriptRoot 'ClipPlayer.FolderScanner.ps1'
if (-not (Test-Path -LiteralPath $folderScannerScript -PathType Leaf)) {
    throw "Folder scanner module missing: $folderScannerScript"
}
. $folderScannerScript

function Test-SamePath {
    param([AllowNull()][string] $Left, [AllowNull()][string] $Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return [string]::Equals([IO.Path]::GetFullPath($Left).TrimEnd('\'),
        [IO.Path]::GetFullPath($Right).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Get-CurrentPlaybackPath {
    if ($script:currentIndex -ge 0 -and $script:currentIndex -lt $script:playlist.Count) {
        return $script:playlist[$script:currentIndex]
    }
    return $null
}

function Sync-FolderSelection {
    param([AllowNull()][string] $Path)
    if (-not $script:folderModeEnabled -or [string]::IsNullOrWhiteSpace($Path)) { return }
    $match = @($script:folderEntries | Where-Object { Test-SamePath $_.Path $Path } | Select-Object -First 1)
    if ($match.Count -eq 1) {
        $script:folderView.SelectedItem = $match[0]
        $script:folderView.ScrollIntoView($match[0])
    }
}

function Update-FolderDeleteButton {
    if (-not $script:folderModeEnabled) { return }
    $entry = $script:folderView.SelectedItem
    $script:deleteButton.IsEnabled = $null -ne $entry -and -not $entry.IsFolder
}

function Apply-FolderSortResult {
    param([object[]] $Entries, [AllowNull()][string] $PreviousStatus)
    $selectedPath = if ($null -eq $script:folderView.SelectedItem) { $null }
        else { [string]$script:folderView.SelectedItem.Path }
    $script:folderEntries = @($Entries)
    $script:folderAudioCount = @($script:folderEntries | Where-Object { -not $_.IsFolder }).Count
    $script:folderView.ItemsSource = $script:folderEntries
    $selectionExists = $selectedPath -and
        @($script:folderEntries | Where-Object { Test-SamePath $_.Path $selectedPath }).Count -gt 0
    Sync-FolderSelection $(if ($selectionExists) { $selectedPath } else { Get-CurrentPlaybackPath })
    Update-FolderDeleteButton
    Set-FolderPlaybackOrder
    if ($script:statusText.Text -eq 'Folder sorting...') { Set-Status $PreviousStatus }
    Publish-Diagnostics
}

function Resolve-FolderPath {
    param([AllowNull()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $candidatePath = $Path
    # An existing literal path wins; expansion is only a fallback for tokens.
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($candidatePath)
        if (($expandedPath -ne $candidatePath) -and
            (Test-Path -LiteralPath $expandedPath -PathType Container)) {
            $candidatePath = $expandedPath
        }
    }
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        throw "Folder does not exist: $candidatePath"
    }
    return [IO.Path]::GetFullPath($candidatePath)
}

function Show-Folder {
    param([AllowNull()][string] $Path)
    try {
        $resolvedPath = Resolve-FolderPath $Path
    } catch {
        # An invalid navigation must invalidate and retire any older scan;
        # otherwise its late completion can replace the last valid folder.
        Stop-FolderScan -Invalidate
        Stop-FolderSort -Invalidate
        Set-Status ('Folder unavailable: ' + $_.Exception.Message)
        return $false
    }
    Start-FolderScan $resolvedPath
    return $true
}

function Set-FolderPlaybackOrder {
    $paths = @($script:folderEntries | Where-Object { -not $_.IsFolder } | ForEach-Object { $_.Path })
    $currentPath = Get-CurrentPlaybackPath
    if ($paths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($currentPath) -or
        -not (@($paths | Where-Object { Test-SamePath $_ $currentPath }).Count)) { return }
    $script:playlist = $paths
    Set-PlaylistDisplay $paths
    for ($index = 0; $index -lt $paths.Count; $index++) {
        if (Test-SamePath $paths[$index] $currentPath) { $script:currentIndex = $index; break }
    }
    $script:internalSelection = $true
    $script:playlistControl.SelectedIndex = $script:currentIndex
    $script:internalSelection = $false
    Set-PreloadWindow
    Update-Controls
}

function Remove-PlaylistPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $remaining = @($script:playlist | Where-Object { -not (Test-SamePath $_ $Path) })
    if ($remaining.Count -eq $script:playlist.Count) { return }
    $currentPath = Get-CurrentPlaybackPath
    $script:playlist = @($remaining)
    $newIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        for ($index = 0; $index -lt $script:playlist.Count; $index++) {
            if (Test-SamePath $script:playlist[$index] $currentPath) { $newIndex = $index; break }
        }
    }
    if ($newIndex -lt 0) { $script:currentIndex = -1; $script:isPaused = $true }
    else { $script:currentIndex = $newIndex }
    Set-PlaylistDisplay $script:playlist
    $script:internalSelection = $true
    $script:playlistControl.SelectedIndex = $script:currentIndex
    $script:internalSelection = $false
    if ($script:currentIndex -ge 0) { Set-PreloadWindow }
    Update-Controls
    Publish-Diagnostics
}

function Set-FolderSort {
    param([string] $Field, [bool] $Descending)
    $script:folderSort = $Field
    $script:folderDescending = $Descending
    $scanRequest = if ($null -ne $script:folderScanPending) { $script:folderScanPending }
        elseif ($null -ne $script:folderScan) { $script:folderScan } else { $null }
    if ($null -ne $scanRequest) {
        $pendingPath = $scanRequest.Path
        $initialAudioPath = $scanRequest.InitialAudioPath
        Start-FolderScan $pendingPath $initialAudioPath
    } else { Start-FolderSort }
    Publish-Diagnostics
}

function Open-FolderSelection {
    $entry = $script:folderView.SelectedItem
    if ($null -eq $entry) { return }
    if ($entry.IsFolder) { $null = Show-Folder $entry.Path; return }
    if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
        Set-Status 'The selected audio file is no longer available'
        $null = Show-Folder $script:folderPath
        return
    }
    $paths = @($script:folderEntries | Where-Object { -not $_.IsFolder } | ForEach-Object { $_.Path })
    $selectedIndex = [Array]::IndexOf([object[]]$paths, [object]$entry.Path)
    Set-Playlist $paths ([Math]::Max(0, $selectedIndex)) -PreserveOrder -KnownExisting
    Sync-FolderSelection $entry.Path
}

function Open-FolderAddress {
    $value = $script:folderAddress.Text.Trim()
    $null = Show-Folder $(if ($value -eq 'This PC') { $null } else { $value })
}

function Open-ParentFolder {
    if ([string]::IsNullOrWhiteSpace($script:folderPath)) { return }
    $parent = [IO.Directory]::GetParent($script:folderPath)
    $null = Show-Folder $(if ($null -eq $parent) { $null } else { $parent.FullName })
}

function Set-FolderMode {
    param([bool] $Enabled)
    if ($script:folderModeToggle.IsChecked -ne $Enabled) {
        $script:folderModeToggle.IsChecked = $Enabled
        return
    }
    $script:folderModeEnabled = $Enabled
    $script:playlistControl.Visibility = if ($Enabled) { 'Collapsed' } else { 'Visible' }
    $script:folderPanel.Visibility = if ($Enabled) { 'Visible' } else { 'Collapsed' }
    if ($Enabled) {
        $target = $script:folderPath
        if ([string]::IsNullOrWhiteSpace($target)) {
            $currentPath = Get-CurrentPlaybackPath
            $target = if ($currentPath) { [IO.Path]::GetDirectoryName($currentPath) }
                else { [Environment]::GetFolderPath([Environment+SpecialFolder]::MyMusic) }
        }
        if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Container)) {
            $target = $null
        }
        if (-not (Show-Folder $target)) { $null = Show-Folder $null }
        if (-not $BackgroundTest) { $script:folderView.Focus() | Out-Null }
    } else {
        Stop-FolderScan -Invalidate
        Stop-FolderSort -Invalidate
        Update-Controls
        Publish-Diagnostics
    }
}

function Invoke-FolderDelete {
    param([switch] $SkipConfirmation)
    if (-not $script:folderModeEnabled) { return $false }
    $entry = $script:folderView.SelectedItem
    if ($null -eq $entry -or $entry.IsFolder) { Set-Status 'Select an audio file to delete'; return $true }
    $path = [string]$entry.Path
    if (Test-SamePath $path (Get-CurrentPlaybackPath)) {
        $deleted = Remove-CurrentTrack -SkipConfirmation:$SkipConfirmation
        if ($deleted) { $null = Show-Folder $script:folderPath }
        return $true
    }
    if ($SkipConfirmation) { throw 'Background deletion requires the currently playing test fixture.' }
    $answer = [Windows.MessageBox]::Show(
        "Move '$([IO.Path]::GetFileName($path))' to the Recycle Bin?", 'ClipPlayer',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning,
        [Windows.MessageBoxResult]::No)
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { return $true }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        Close-Player $path
        Remove-PlaylistPath $path
        $null = Show-Folder $script:folderPath
    } catch {
        Set-Status ('Delete failed: ' + $_.Exception.Message)
        Publish-Diagnostics
    }
    return $true
}

function Invoke-FolderAutomationCommand {
    param([string] $Command)
    switch ($Command) {
        'FolderModeOn' { Set-FolderMode $true; return $true }
        'FolderModeOff' { Set-FolderMode $false; return $true }
        'FolderOpenFirstFolder' {
            $entry = @($script:folderEntries | Where-Object IsFolder | Select-Object -First 1)
            if ($entry.Count -eq 0) { throw 'No folder is available for the automation check.' }
            $null = Show-Folder $entry[0].Path; return $true
        }
        'FolderUp' { Open-ParentFolder; return $true }
        'FolderSelectFirstFolder' {
            $entry = @($script:folderEntries | Where-Object IsFolder | Select-Object -First 1)
            if ($entry.Count -eq 0) { throw 'No folder is available for the selection check.' }
            $script:folderView.SelectedItem = $entry[0]
            return $true
        }
        'FolderSortNameDescending' {
            $script:folderSortControl.SelectedItem = 'Name'
            $script:folderDirectionControl.SelectedItem = 'Descending'
            return $true
        }
        'FolderSortNameAscending' {
            $script:folderSortControl.SelectedItem = 'Name'
            $script:folderDirectionControl.SelectedItem = 'Ascending'
            return $true
        }
        'FolderSortDateCreated' {
            $script:folderDirectionControl.SelectedItem = 'Ascending'
            $script:folderSortControl.SelectedItem = 'Date created'
            return $true
        }
        'FolderSortDateModified' {
            $script:folderDirectionControl.SelectedItem = 'Ascending'
            $script:folderSortControl.SelectedItem = 'Date modified'
            return $true
        }
        'FolderSortType' {
            $script:folderDirectionControl.SelectedItem = 'Ascending'
            $script:folderSortControl.SelectedItem = 'Type'
            return $true
        }
        'FolderSortSize' {
            $script:folderDirectionControl.SelectedItem = 'Ascending'
            $script:folderSortControl.SelectedItem = 'Size'
            return $true
        }
        'FolderPlayFirstAudio' {
            $entry = @($script:folderEntries | Where-Object { -not $_.IsFolder } | Select-Object -First 1)
            if ($entry.Count -eq 0) { throw 'No audio file is available for the automation check.' }
            $script:folderView.SelectedItem = $entry[0]
            Open-FolderSelection
            return $true
        }
        'ReplacePlaylistWithFirstAudioTest' {
            $entry = @($script:folderEntries | Where-Object { -not $_.IsFolder } | Select-Object -First 1)
            if ($entry.Count -eq 0) { throw 'No audio file is available for the replacement check.' }
            Set-Playlist @($entry[0].Path) 0 -PreserveOrder
            return $true
        }
        'FolderDeleteSelectedTestFixture' {
            if (-not $BackgroundTest -or [string]::IsNullOrWhiteSpace($AutomationCommandPath)) {
                throw 'Folder deletion automation is restricted to background tests.'
            }
            $null = Invoke-FolderDelete -SkipConfirmation
            return $true
        }
        'ClearPlaylistTest' { Set-Playlist @(); return $true }
        default { return $false }
    }
}

function Publish-Diagnostics {
    if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) { return }
    try {
        $currentPath = Get-CurrentPlaybackPath
        $selectedEntry = if ($null -ne $script:folderView) { $script:folderView.SelectedItem } else { $null }
        # The automation protocol is a state probe, not a second copy of a
        # large audio library. Serializing tens of thousands of paths on every
        # dispatcher tick starves the very UI path the probe is meant to test.
        $diagnosticListLimit = 2048
        $playlistPaths = if ($script:playlist.Count -le $diagnosticListLimit) { @($script:playlist) } else { @() }
        $folderItemNames = if ($script:folderEntries.Count -le $diagnosticListLimit) {
            @($script:folderEntries | ForEach-Object Name)
        } else { @() }
        $failureMap = [ordered]@{}
        foreach ($failurePath in $script:playerFailures.Keys) {
            $failureMap[$failurePath] = $script:playerFailures[$failurePath]
        }
        $state = [ordered]@{
            ProcessId = $PID; CurrentIndex = $script:currentIndex; PlaylistSelectedIndex = $script:playlistControl.SelectedIndex; CurrentPath = $currentPath
            PlaylistCount = $script:playlist.Count; PlaylistPaths = $playlistPaths
            IsPaused = $script:isPaused
            PositionMilliseconds = if ($currentPath -and $script:players.ContainsKey($currentPath)) {
                [Math]::Round($script:players[$currentPath].Position.TotalMilliseconds)
            } else { 0 }
            DurationMilliseconds = if ($currentPath -and $script:players.ContainsKey($currentPath) -and
                $script:players[$currentPath].NaturalDuration.HasTimeSpan) {
                [Math]::Round($script:players[$currentPath].NaturalDuration.TimeSpan.TotalMilliseconds)
            } else { 0 }
            CachedPlayerCount = $script:players.Count; CachedPaths = @($script:players.Keys)
            PendingPlaybackCount = $script:pendingPlayback.Count; PendingPlaybackPaths = @($script:pendingPlayback.Keys)
            PlayerHandlerCount = $script:playerHandlers.Count
            RaceFixtureExpectedPositionMilliseconds = $script:raceFixtureExpectedPosition
            RaceFixtureAppliedPositionMilliseconds = $script:raceFixtureAppliedPosition
            CompletedPaths = @($script:completedPlayback.Keys)
            PlayerFailureCount = $script:playerFailures.Count; FailureMap = $failureMap
            Status = $script:statusText.Text
            LastAutomationCommandId = $script:lastAutomationCommandId
            LastAutomationCommandDurationMilliseconds = $script:lastAutomationCommandDurationMilliseconds
            LastAutomationCommandName = $script:lastAutomationCommandName
            LastAutomationCommandBeforeIndex = $script:lastAutomationCommandBeforeIndex
            LastAutomationCommandBeforePath = $script:lastAutomationCommandBeforePath
            LastAutomationCommandBeforeIsPaused = $script:lastAutomationCommandBeforeIsPaused
            LastAutomationCommandAfterIndex = $script:lastAutomationCommandAfterIndex
            LastAutomationCommandAfterPath = $script:lastAutomationCommandAfterPath
            LastAutomationCommandAfterIsPaused = $script:lastAutomationCommandAfterIsPaused
            FolderMode = $script:folderModeEnabled; FolderPath = $script:folderPath
            FolderScanGeneration = $script:folderScanGeneration
            FolderScanPending = $null -ne $script:folderScan -or $null -ne $script:folderScanPending -or $script:folderScanOrphans.Count -gt 0
            FolderScanPath = if ($null -ne $script:folderScanPending) { $script:folderScanPending.Path }
                elseif ($null -ne $script:folderScan) { $script:folderScan.Path } else { $null }
            FolderSortGeneration = $script:folderSortGeneration
            FolderSortPending = $null -ne $script:folderSortState -or $null -ne $script:folderSortPending -or $script:folderSortOrphans.Count -gt 0
            FolderItemCount = $script:folderEntries.Count
            FolderAudioCount = $script:folderAudioCount
            FolderSort = $script:folderSort; FolderDescending = $script:folderDescending
            FolderSelectedPath = if ($null -eq $selectedEntry) { $null } else { $selectedEntry.Path }
            FolderItemNames = $folderItemNames
            PositionText = $script:positionText.Text; DurationText = $script:durationText.Text
            PositionSliderEnabled = $script:positionSlider.IsEnabled
            PositionSliderValue = [Math]::Round([double]$script:positionSlider.Value, 4)
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
        }
        # Publish a complete snapshot in one rename so the harness never observes
        # a half-written JSON document while the dispatcher is ticking.
        $diagnosticTempPath = "$DiagnosticsPath.$PID.tmp"
        $diagnosticBackupPath = "$DiagnosticsPath.$PID.bak"
        [IO.File]::WriteAllText($diagnosticTempPath, ($state | ConvertTo-Json -Compress -Depth 3))
        if ([IO.File]::Exists($DiagnosticsPath)) {
            if ([IO.File]::Exists($diagnosticBackupPath)) { Remove-Item -LiteralPath $diagnosticBackupPath -Force }
            [IO.File]::Replace($diagnosticTempPath, $DiagnosticsPath, $diagnosticBackupPath)
            Remove-Item -LiteralPath $diagnosticBackupPath -Force -ErrorAction SilentlyContinue
        } else { [IO.File]::Move($diagnosticTempPath, $DiagnosticsPath) }
    } catch { }
}

function Initialize-FolderMode {
    $script:folderModeToggle = $script:window.FindName('FolderModeToggle')
    $script:folderPanel = $script:window.FindName('FolderPanel')
    $script:folderNavigationBar = $script:window.FindName('FolderNavigationBar')
    $script:folderView = $script:window.FindName('FolderView')
    $script:folderAddress = $script:window.FindName('FolderAddress')
    $script:folderSortControl = $script:window.FindName('FolderSort')
    $script:folderDirectionControl = $script:window.FindName('FolderDirection')
    foreach ($item in @('Name', 'Date created', 'Date modified', 'Type', 'Size')) {
        $null = $script:folderSortControl.Items.Add($item)
    }
    foreach ($item in @('Ascending', 'Descending')) { $null = $script:folderDirectionControl.Items.Add($item) }
    $script:folderSortControl.SelectedItem = 'Name'
    $script:folderDirectionControl.SelectedItem = 'Ascending'

    $setMode = ${function:Set-FolderMode}; $up = ${function:Open-ParentFolder}
    $go = ${function:Open-FolderAddress}; $open = ${function:Open-FolderSelection}
    $applySort = ${function:Set-FolderSort}; $updateDelete = ${function:Update-FolderDeleteButton}
    $script:folderModeToggle.Add_Checked(({ & $setMode $true }).GetNewClosure())
    $script:folderModeToggle.Add_Unchecked(({ & $setMode $false }).GetNewClosure())
    $script:window.FindName('FolderUpButton').Add_Click(({ & $up }).GetNewClosure())
    $script:window.FindName('FolderGoButton').Add_Click(({ & $go }).GetNewClosure())
    $script:folderAddress.Add_KeyDown(({ param($sender, $args); if ($args.Key -eq 'Enter') {
        & $go; $args.Handled = $true } }).GetNewClosure())
    $view = $script:folderView
    $script:folderView.Add_MouseDoubleClick(({ param($sender, $args)
        if ($null -ne $view.ContainerFromElement($args.OriginalSource)) { & $open }
    }).GetNewClosure())
    $script:folderView.Add_KeyDown(({ param($sender, $args); if ($args.Key -eq 'Enter') {
        & $open; $args.Handled = $true } }).GetNewClosure())
    $script:folderView.Add_SelectionChanged(({ & $updateDelete }).GetNewClosure())
    $sortControl = $script:folderSortControl; $directionControl = $script:folderDirectionControl
    $sortChanged = ({
        if ($null -ne $sortControl.SelectedItem -and $null -ne $directionControl.SelectedItem) {
            & $applySort ([string]$sortControl.SelectedItem) ([string]$directionControl.SelectedItem -eq 'Descending')
        }
    }).GetNewClosure()
    $script:folderSortControl.Add_SelectionChanged($sortChanged)
    $script:folderDirectionControl.Add_SelectionChanged($sortChanged)
}
