$script:folderModeEnabled = $false
$script:folderPath = $null
$script:folderEntries = @()
$script:folderSort = 'Name'
$script:folderDescending = $false

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

function New-FolderEntry {
    param([IO.FileSystemInfo] $Info, [bool] $IsFolder)
    $created = try { $Info.CreationTime } catch { [DateTime]::MinValue }
    $modified = try { $Info.LastWriteTime } catch { [DateTime]::MinValue }
    $size = if ($IsFolder) { [long]0 } else { try { [long]$Info.Length } catch { [long]0 } }
    return [PSCustomObject]@{
        Name = $Info.Name; Path = $Info.FullName; IsFolder = $IsFolder; IsDrive = $false
        Type = if ($IsFolder) { 'File folder' } else { $Info.Extension.TrimStart('.').ToUpperInvariant() + ' audio' }
        TypeSort = if ($IsFolder) { '' } else { $Info.Extension.ToLowerInvariant() }
        Created = $created; Modified = $modified; Size = $size
        CreatedText = if ($created -eq [DateTime]::MinValue) { '' } else { $created.ToString('g') }
        ModifiedText = if ($modified -eq [DateTime]::MinValue) { '' } else { $modified.ToString('g') }
        SizeText = if ($IsFolder) { '' } else { Format-FileSize $size }
    }
}

function Get-FolderEntries {
    param([AllowNull()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @([IO.DriveInfo]::GetDrives() | ForEach-Object {
            [PSCustomObject]@{
                Name = if ($_.IsReady -and -not [string]::IsNullOrWhiteSpace($_.VolumeLabel)) {
                    $_.VolumeLabel + ' (' + $_.Name.TrimEnd('\') + ')'
                } else { $_.Name }
                Path = $_.RootDirectory.FullName; IsFolder = $true; IsDrive = $true
                Type = $_.DriveType.ToString() + ' drive'; TypeSort = $_.DriveType.ToString()
                Created = [DateTime]::MinValue; Modified = [DateTime]::MinValue
                Size = if ($_.IsReady) { [long]$_.TotalSize } else { [long]0 }
                CreatedText = ''; ModifiedText = ''; SizeText = ''
            }
        })
    }

    $directory = New-Object IO.DirectoryInfo $Path
    $entries = New-Object Collections.Generic.List[object]
    foreach ($item in $directory.GetDirectories()) { $entries.Add((New-FolderEntry $item $true)) }
    foreach ($item in $directory.GetFiles()) {
        if (Test-SupportedPath $item.FullName) { $entries.Add((New-FolderEntry $item $false)) }
    }
    return @($entries.ToArray())
}

function Get-SortedFolderEntries {
    param([object[]] $Entries)
    $sortField = $script:folderSort
    $descending = $script:folderDescending
    return @($Entries | Sort-Object `
        @{ Expression = { if ($_.IsFolder) { 0 } else { 1 } } }, `
        @{ Expression = {
            $entry = $_
            switch ($sortField) {
                'Date created' { $entry.Created }
                'Date modified' { $entry.Modified }
                'Type' { $entry.TypeSort }
                'Size' { $entry.Size }
                default { Get-NaturalSortKey $entry.Name }
            }
        }; Descending = $descending }, `
        @{ Expression = { Get-NaturalSortKey $_.Name } }, `
        @{ Expression = { $_.Name } })
}

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

function Render-FolderEntries {
    $selectedPath = if ($null -eq $script:folderView.SelectedItem) { $null }
        else { [string]$script:folderView.SelectedItem.Path }
    $script:folderEntries = @(Get-SortedFolderEntries $script:folderEntries)
    $script:folderView.Items.Clear()
    foreach ($entry in $script:folderEntries) { $null = $script:folderView.Items.Add($entry) }
    $selectionExists = $selectedPath -and
        @($script:folderEntries | Where-Object { Test-SamePath $_.Path $selectedPath }).Count -gt 0
    Sync-FolderSelection $(if ($selectionExists) { $selectedPath } else { Get-CurrentPlaybackPath })
    Update-FolderDeleteButton
}

function Show-Folder {
    param([AllowNull()][string] $Path)
    try {
        $resolvedPath = if ([string]::IsNullOrWhiteSpace($Path)) { $null }
            else { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)) }
        if ($null -ne $resolvedPath -and -not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw "Folder does not exist: $resolvedPath"
        }
        $entries = @(Get-FolderEntries $resolvedPath)
    } catch {
        Set-Status ('Folder unavailable: ' + $_.Exception.Message)
        return $false
    }
    $script:folderPath = $resolvedPath
    $script:folderEntries = $entries
    $script:folderAddress.Text = if ($null -eq $resolvedPath) { 'This PC' } else { $resolvedPath }
    Render-FolderEntries
    if ($script:currentIndex -lt 0) {
        $audioCount = @($entries | Where-Object { -not $_.IsFolder }).Count
        Set-Status ("Folder: $audioCount supported audio file(s)")
    }
    Publish-Diagnostics
    return $true
}

function Set-FolderPlaybackOrder {
    $paths = @($script:folderEntries | Where-Object { -not $_.IsFolder } | ForEach-Object { $_.Path })
    $currentPath = Get-CurrentPlaybackPath
    if ($paths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($currentPath) -or
        -not (@($paths | Where-Object { Test-SamePath $_ $currentPath }).Count)) { return }
    $script:playlist = $paths
    $script:playlistControl.Items.Clear()
    foreach ($path in $paths) { $null = $script:playlistControl.Items.Add([IO.Path]::GetFileName($path)) }
    for ($index = 0; $index -lt $paths.Count; $index++) {
        if (Test-SamePath $paths[$index] $currentPath) { $script:currentIndex = $index; break }
    }
    $script:internalSelection = $true
    $script:playlistControl.SelectedIndex = $script:currentIndex
    $script:internalSelection = $false
    Set-PreloadWindow
    Update-Controls
}

function Set-FolderSort {
    param([string] $Field, [bool] $Descending)
    $script:folderSort = $Field
    $script:folderDescending = $Descending
    Render-FolderEntries
    Set-FolderPlaybackOrder
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
    Set-Playlist $paths ([Math]::Max(0, $selectedIndex)) -PreserveOrder
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
    } else { Update-Controls; Publish-Diagnostics }
}

function Invoke-FolderDelete {
    param([switch] $SkipConfirmation)
    if (-not $script:folderModeEnabled) { return $false }
    $entry = $script:folderView.SelectedItem
    if ($null -eq $entry -or $entry.IsFolder) { Set-Status 'Select an audio file to delete'; return $true }
    $path = [string]$entry.Path
    if (Test-SamePath $path (Get-CurrentPlaybackPath)) {
        Remove-CurrentTrack -SkipConfirmation:$SkipConfirmation
        $null = Show-Folder $script:folderPath
        return $true
    }
    if ($SkipConfirmation) { throw 'Background deletion requires the currently playing test fixture.' }
    $answer = [Windows.MessageBox]::Show(
        "Move '$([IO.Path]::GetFileName($path))' to the Recycle Bin?", 'ClipPlayer',
        [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning,
        [Windows.MessageBoxResult]::No)
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { return $true }
    Close-Player $path
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        $null = Show-Folder $script:folderPath
        Set-FolderPlaybackOrder
    } catch {
        Set-Status ('Delete failed: ' + $_.Exception.Message)
        Set-PreloadWindow
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
        $state = [ordered]@{
            ProcessId = $PID; CurrentIndex = $script:currentIndex; CurrentPath = $currentPath
            PlaylistCount = $script:playlist.Count
            IsPaused = $script:isPaused
            PositionMilliseconds = if ($currentPath -and $script:players.ContainsKey($currentPath)) {
                [Math]::Round($script:players[$currentPath].Position.TotalMilliseconds)
            } else { 0 }
            DurationMilliseconds = if ($currentPath -and $script:players.ContainsKey($currentPath) -and
                $script:players[$currentPath].NaturalDuration.HasTimeSpan) {
                [Math]::Round($script:players[$currentPath].NaturalDuration.TimeSpan.TotalMilliseconds)
            } else { 0 }
            CachedPlayerCount = $script:players.Count; CachedPaths = @($script:players.Keys)
            Status = $script:statusText.Text
            LastAutomationCommandId = $script:lastAutomationCommandId
            LastAutomationCommandDurationMilliseconds = $script:lastAutomationCommandDurationMilliseconds
            FolderMode = $script:folderModeEnabled; FolderPath = $script:folderPath
            FolderItemCount = $script:folderEntries.Count
            FolderAudioCount = @($script:folderEntries | Where-Object { -not $_.IsFolder }).Count
            FolderSort = $script:folderSort; FolderDescending = $script:folderDescending
            FolderSelectedPath = if ($null -eq $selectedEntry) { $null } else { $selectedEntry.Path }
            FolderItemNames = @($script:folderEntries | ForEach-Object Name)
            PositionText = $script:positionText.Text; DurationText = $script:durationText.Text
            PositionSliderEnabled = $script:positionSlider.IsEnabled
            PositionSliderValue = [Math]::Round([double]$script:positionSlider.Value, 4)
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText($DiagnosticsPath, ($state | ConvertTo-Json -Compress -Depth 3))
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
