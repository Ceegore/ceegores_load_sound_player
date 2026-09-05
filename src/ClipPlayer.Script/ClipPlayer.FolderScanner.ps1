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

# This scriptblock is self-contained so the runspace never evaluates a WPF object
# or accesses a script/UI scope. It returns only serializable folder-entry DTOs.
$script:folderScanWorker = {
    param(
        [AllowNull()][string] $ScanPath,
        [string[]] $Extensions,
        [string] $SortField,
        [bool] $Descending
    )
    function Test-WorkerSupportedPath {
        param([string] $Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        return $Extensions -contains ([IO.Path]::GetExtension($Path).ToLowerInvariant())
    }
    function Get-WorkerNaturalSortKey {
        param([string] $Name)
        return [regex]::Replace($Name, '\d+', {
            param($match)
            $digits = $match.Value.TrimStart('0')
            if ($digits.Length -eq 0) { $digits = '0' }
            return ('{0:D8}:{1}' -f $digits.Length, $digits)
        })
    }
    function Format-WorkerFileSize {
        param([long] $Bytes)
        if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
        return "$Bytes B"
    }
    function New-WorkerEntry {
        param($Info, [bool] $IsFolder, [bool] $IsDrive = $false)
        $created = try { $Info.CreationTime } catch { [DateTime]::MinValue }
        $modified = try { $Info.LastWriteTime } catch { [DateTime]::MinValue }
        $size = if ($IsFolder -or $IsDrive) { [long]0 } else { try { [long]$Info.Length } catch { [long]0 } }
        [PSCustomObject]@{
            Name = [string]$Info.Name; Path = [string]$Info.FullName; IsFolder = $IsFolder; IsDrive = $IsDrive
            Type = if ($IsFolder) { 'File folder' } else { ([IO.Path]::GetExtension($Info.FullName)).TrimStart('.').ToUpperInvariant() + ' audio' }
            TypeSort = if ($IsFolder) { '' } else { ([IO.Path]::GetExtension($Info.FullName)).ToLowerInvariant() }
            Created = $created; Modified = $modified; Size = $size
            CreatedText = if ($created -eq [DateTime]::MinValue) { '' } else { $created.ToString('g') }
            ModifiedText = if ($modified -eq [DateTime]::MinValue) { '' } else { $modified.ToString('g') }
            SizeText = if ($IsFolder -or $IsDrive) { '' } else { Format-WorkerFileSize $size }
        }
    }

    $entries = New-Object Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($ScanPath)) {
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            $driveSize = if ($drive.IsReady) { [long]$drive.TotalSize } else { [long]0 }
            $driveName = if ($drive.IsReady -and -not [string]::IsNullOrWhiteSpace($drive.VolumeLabel)) {
                $drive.VolumeLabel + ' (' + $drive.Name.TrimEnd('\') + ')'
            } else { $drive.Name }
            $entries.Add([PSCustomObject]@{
                Name = $driveName; Path = $drive.RootDirectory.FullName; IsFolder = $true; IsDrive = $true
                Type = $drive.DriveType.ToString() + ' drive'; TypeSort = $drive.DriveType.ToString()
                Created = [DateTime]::MinValue; Modified = [DateTime]::MinValue; Size = $driveSize
                CreatedText = ''; ModifiedText = ''; SizeText = ''
            })
        }
    } else {
        $directory = New-Object IO.DirectoryInfo $ScanPath
        foreach ($item in $directory.GetDirectories()) { $entries.Add((New-WorkerEntry $item $true)) }
        foreach ($item in $directory.GetFiles()) {
            if (Test-WorkerSupportedPath $item.FullName) { $entries.Add((New-WorkerEntry $item $false)) }
        }
    }
    @($entries.ToArray() | Sort-Object `
        @{ Expression = { if ($_.IsFolder) { 0 } else { 1 } } }, `
        @{ Expression = {
            $entry = $_
            switch ($SortField) {
                'Date created' { $entry.Created }
                'Date modified' { $entry.Modified }
                'Type' { $entry.TypeSort }
                'Size' { $entry.Size }
                default { Get-WorkerNaturalSortKey $entry.Name }
            }
        }; Descending = $Descending }, `
        @{ Expression = { Get-WorkerNaturalSortKey $_.Name } }, `
        @{ Expression = { $_.Name } })
}

# Sorting is deliberately independent of the scan worker. A sort of an already
# loaded directory must never execute Sort-Object on the WPF dispatcher.
$script:folderSortWorker = {
    param([object[]] $Entries, [string] $SortField, [bool] $Descending, [int] $DelayMilliseconds)
    function Get-WorkerNaturalSortKey {
        param([string] $Name)
        return [regex]::Replace($Name, '\d+', {
            param($match)
            $digits = $match.Value.TrimStart('0')
            if ($digits.Length -eq 0) { $digits = '0' }
            return ('{0:D8}:{1}' -f $digits.Length, $digits)
        })
    }
    if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
    @($Entries | Sort-Object `
        @{ Expression = { if ($_.IsFolder) { 0 } else { 1 } } }, `
        @{ Expression = {
            $entry = $_
            switch ($SortField) {
                'Date created' { $entry.Created }
                'Date modified' { $entry.Modified }
                'Type' { $entry.TypeSort }
                'Size' { $entry.Size }
                default { Get-WorkerNaturalSortKey $entry.Name }
            }
        }; Descending = $Descending }, `
        @{ Expression = { Get-WorkerNaturalSortKey $_.Name } }, `
        @{ Expression = { $_.Name } })
}

function Close-FolderScanState {
    param($State, [switch] $Stop)
    if ($null -eq $State) { return }
    if ($Stop) { try { $State.PowerShell.Stop() } catch { } }
    if ($null -ne $State.StopResult -and $State.StopResult.IsCompleted) {
        try { $State.PowerShell.EndStop($State.StopResult) } catch { }
    }
    if (-not $State.InvokeEnded -and $null -ne $State.AsyncResult -and $State.AsyncResult.IsCompleted) {
        try { $null = $State.PowerShell.EndInvoke($State.AsyncResult) } catch { }
        $State.InvokeEnded = $true
    }
    try { $State.PowerShell.Dispose() } catch { }
}

function Get-FolderRunspacePool {
    if ($null -eq $script:folderRunspacePool) {
        # At most two pipelines may execute: one stale/slow filesystem request
        # and the latest request. Reusing the pool avoids native handle growth
        # from creating and tearing down a runspace for every sort/navigation.
        $script:folderRunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2)
        $script:folderRunspacePool.Open()
    }
    return $script:folderRunspacePool
}

function Queue-FolderScanStop {
    param($State)
    if ($null -eq $State) { return }
    # BeginStop is non-blocking. Keeping exactly one retiring pipeline and one
    # data-only pending request prevents RunspacePool's internal queue (and its
    # PowerShell objects/handles) from growing during navigation bursts.
    if ($script:folderScanOrphans.Count -ne 0) { throw 'Folder scan retirement invariant violated.' }
    if ($null -ne $State.AsyncResult -and -not $State.AsyncResult.IsCompleted) {
        try { $State.StopResult = $State.PowerShell.BeginStop($null, $null) } catch { }
    }
    $null = $script:folderScanOrphans.Add($State)
}

function Stop-FolderScan {
    param([switch] $Invalidate)
    $state = $script:folderScan
    $script:folderScan = $null
    $script:folderScanPending = $null
    if ($Invalidate) { $script:folderScanGeneration++ }
    Queue-FolderScanStop $state
}

function Complete-OrphanScanDisposals {
    foreach ($state in @($script:folderScanOrphans.ToArray())) {
        $stopComplete = $null -eq $state.StopResult -or $state.StopResult.IsCompleted
        if ($null -ne $state.AsyncResult -and $state.AsyncResult.IsCompleted -and $stopComplete) {
            Close-FolderScanState $state
            $null = $script:folderScanOrphans.Remove($state)
        }
    }
    Start-PendingFolderScan
}

function Stop-AllFolderScans {
    Stop-FolderScan
    $script:folderScanPending = $null
    foreach ($state in @($script:folderScanOrphans.ToArray())) {
        try { if ($null -ne $state.AsyncResult -and -not $state.AsyncResult.IsCompleted) { $state.PowerShell.Stop() } } catch { }
        Close-FolderScanState $state
        $null = $script:folderScanOrphans.Remove($state)
    }
}

function Close-FolderSortState {
    param($State, [switch] $Stop)
    if ($null -eq $State) { return }
    if ($Stop) { try { $State.PowerShell.Stop() } catch { } }
    if ($null -ne $State.StopResult -and $State.StopResult.IsCompleted) {
        try { $State.PowerShell.EndStop($State.StopResult) } catch { }
    }
    if (-not $State.InvokeEnded -and $null -ne $State.AsyncResult -and $State.AsyncResult.IsCompleted) {
        try { $null = $State.PowerShell.EndInvoke($State.AsyncResult) } catch { }
        $State.InvokeEnded = $true
    }
    try { $State.PowerShell.Dispose() } catch { }
}

function Stop-FolderSort {
    param([switch] $Invalidate)
    $state = $script:folderSortState
    $previousStatus = if ($null -ne $state) { $state.PreviousStatus }
        elseif ($null -ne $script:folderSortPending) { $script:folderSortPending.PreviousStatus }
        elseif ($script:folderSortOrphans.Count -gt 0) { $script:folderSortOrphans[0].PreviousStatus }
        else { $null }
    $script:folderSortState = $null
    $script:folderSortPending = $null
    if ($Invalidate) { $script:folderSortGeneration++ }
    if ($null -ne $previousStatus -and $script:statusText.Text -eq 'Folder sorting...') {
        Set-Status $previousStatus
    }
    if ($null -ne $state) {
        if ($script:folderSortOrphans.Count -ne 0) { throw 'Folder sort retirement invariant violated.' }
        if ($null -ne $state.AsyncResult -and -not $state.AsyncResult.IsCompleted) {
            try { $state.StopResult = $state.PowerShell.BeginStop($null, $null) } catch { }
        }
        $null = $script:folderSortOrphans.Add($state)
    }
}

function Complete-OrphanSortDisposals {
    foreach ($state in @($script:folderSortOrphans.ToArray())) {
        $stopComplete = $null -eq $state.StopResult -or $state.StopResult.IsCompleted
        if ($null -ne $state.AsyncResult -and $state.AsyncResult.IsCompleted -and $stopComplete) {
            Close-FolderSortState $state
            $null = $script:folderSortOrphans.Remove($state)
        }
    }
    Start-PendingFolderSort
}

function Start-FolderSort {
    $previousStatus = if ($null -ne $script:folderSortPending) { [string]$script:folderSortPending.PreviousStatus }
        elseif ($null -ne $script:folderSortState) { [string]$script:folderSortState.PreviousStatus }
        elseif ($script:folderSortOrphans.Count -gt 0) { [string]$script:folderSortOrphans[0].PreviousStatus }
        else { [string]$script:statusText.Text }
    $script:folderSortGeneration++
    $generation = $script:folderSortGeneration
    Stop-FolderSort
    Set-Status 'Folder sorting...'
    $script:folderSortPending = [PSCustomObject]@{
        Generation = $generation; ScanGeneration = $script:folderScanGeneration; Path = $script:folderPath
        PreviousStatus = $previousStatus; Entries = [object[]]@($script:folderEntries)
        SortField = [string]$script:folderSort; Descending = [bool]$script:folderDescending
        DelayMilliseconds = [int]$script:folderSortTestDelayMilliseconds
    }
    Start-PendingFolderSort
}

function Start-PendingFolderSort {
    if ($null -ne $script:folderSortState -or $script:folderSortOrphans.Count -gt 0 -or
        $null -eq $script:folderSortPending -or $script:folderWindowClosed) { return }
    $request = $script:folderSortPending; $script:folderSortPending = $null
    $powerShell = [PowerShell]::Create()
    $powerShell.RunspacePool = Get-FolderRunspacePool
    $null = $powerShell.AddScript($script:folderSortWorker.ToString()).AddArgument($request.Entries).
        AddArgument($request.SortField).AddArgument($request.Descending).AddArgument($request.DelayMilliseconds)
    $state = [PSCustomObject]@{
        Generation = $request.Generation; ScanGeneration = $request.ScanGeneration; Path = $request.Path
        PreviousStatus = $request.PreviousStatus; PowerShell = $powerShell; AsyncResult = $null
        StopResult = $null; InvokeEnded = $false
    }
    $script:folderSortState = $state
    try { $state.AsyncResult = $powerShell.BeginInvoke() }
    catch { Close-FolderSortState $state; $script:folderSortState = $null; throw }
}

function Complete-FolderSortIfReady {
    Complete-OrphanSortDisposals
    $state = $script:folderSortState
    if ($null -eq $state -or $null -eq $state.AsyncResult -or -not $state.AsyncResult.IsCompleted) { return }
    $script:folderSortState = $null
    $entries = @(); $errorText = $null
    try { $entries = @($state.PowerShell.EndInvoke($state.AsyncResult)) }
    catch { $errorText = $_.Exception.Message }
    $state.InvokeEnded = $true
    try {
        $samePath = [string]::Equals([string]$state.Path, [string]$script:folderPath,
            [StringComparison]::OrdinalIgnoreCase)
        if (-not $script:folderWindowClosed -and $null -eq $script:folderScan -and $samePath -and
            $state.Generation -eq $script:folderSortGeneration -and
            $state.ScanGeneration -eq $script:folderScanGeneration) {
            if ($null -ne $errorText) { Set-Status ('Folder sort failed: ' + $errorText); Publish-Diagnostics }
            else { Apply-FolderSortResult $entries $state.PreviousStatus }
        }
    } finally { Close-FolderSortState $state }
}

function Stop-AllFolderWork {
    Stop-AllFolderScans
    Stop-FolderSort
    $script:folderSortPending = $null
    foreach ($state in @($script:folderSortOrphans.ToArray())) {
        try { if ($null -ne $state.AsyncResult -and -not $state.AsyncResult.IsCompleted) { $state.PowerShell.Stop() } } catch { }
        Close-FolderSortState $state
        $null = $script:folderSortOrphans.Remove($state)
    }
    if ($null -ne $script:folderRunspacePool) {
        try { $script:folderRunspacePool.Close() } catch { }
        try { $script:folderRunspacePool.Dispose() } catch { }
        $script:folderRunspacePool = $null
    }
}

function Complete-FolderScan {
    param([string] $Path, [object[]] $Entries, [AllowNull()][string] $InitialAudioPath)
    $selectedPath = if ($null -eq $script:folderView.SelectedItem) { $null }
        else { [string]$script:folderView.SelectedItem.Path }
    $script:folderPath = $Path
    $script:folderEntries = @($Entries)
    $script:folderAddress.Text = if ($null -eq $Path) { 'This PC' } else { $Path }
    # Assigning a ready DTO array lets WPF virtualize item containers.  Adding
    # thousands of items one-by-one in this dispatcher tick freezes the UI.
    $script:folderView.ItemsSource = $script:folderEntries
    $selectionExists = $selectedPath -and
        @($script:folderEntries | Where-Object { Test-SamePath $_.Path $selectedPath }).Count -gt 0
    Sync-FolderSelection $(if ($selectionExists) { $selectedPath } else { Get-CurrentPlaybackPath })
    Update-FolderDeleteButton
    if ($script:currentIndex -lt 0) {
        $audioCount = @($script:folderEntries | Where-Object { -not $_.IsFolder }).Count
        Set-Status ("Folder: $audioCount supported audio file(s)")
    } else {
        $currentPath = Get-CurrentPlaybackPath
        if ($null -ne $currentPath -and $script:playerFailures.ContainsKey($currentPath)) {
            Set-Status ('Playback error: ' + $script:playerFailures[$currentPath])
        } elseif ($null -ne $currentPath -and $script:isPaused) {
            Set-Status ('Paused: ' + [IO.Path]::GetFileName($currentPath))
        } elseif ($null -ne $currentPath) {
            Set-Status ([IO.Path]::GetFileName($currentPath))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($InitialAudioPath)) {
        $currentPath = Get-CurrentPlaybackPath
        if ($script:playlist.Count -eq 1 -and (Test-SamePath $currentPath $InitialAudioPath)) {
            $audioPaths = @($script:folderEntries | Where-Object { -not $_.IsFolder } |
                ForEach-Object { [string]$_.Path })
            $initialIndex = [Array]::IndexOf([object[]]$audioPaths, [object]$InitialAudioPath)
            if ($initialIndex -lt 0) {
                for ($index = 0; $index -lt $audioPaths.Count; $index++) {
                    if (Test-SamePath $audioPaths[$index] $InitialAudioPath) { $initialIndex = $index; break }
                }
            }
            $initialPlayer = if ($script:players.ContainsKey($InitialAudioPath)) { $script:players[$InitialAudioPath] } else { $null }
            $initialPosition = if ($null -eq $initialPlayer) { [TimeSpan]::Zero } else { $initialPlayer.Position }
            $initialPaused = [bool]$script:isPaused
            Set-Playlist $audioPaths ([Math]::Max(0, $initialIndex)) -PreserveOrder
            $restoredPath = Get-CurrentPlaybackPath
            if ($null -ne $restoredPath -and (Test-SamePath $restoredPath $InitialAudioPath) -and
                $script:players.ContainsKey($restoredPath)) {
                $restoredPlayer = $script:players[$restoredPath]
                $restoredPlayer.Position = $initialPosition
                if ($initialPaused) { $restoredPlayer.Pause() } else { $restoredPlayer.Play() }
                $script:isPaused = $initialPaused
                Set-Status $(if ($initialPaused) { 'Paused: ' + [IO.Path]::GetFileName($restoredPath) } else { [IO.Path]::GetFileName($restoredPath) })
            }
        }
    }
    Publish-Diagnostics
}

function Start-FolderScan {
    param([AllowNull()][string] $Path, [AllowNull()][string] $InitialAudioPath)
    $script:folderScanGeneration++
    $generation = $script:folderScanGeneration
    Stop-FolderScan
    Stop-FolderSort -Invalidate
    Set-Status 'Folder loading...'
    Publish-Diagnostics
    $script:folderScanPending = [PSCustomObject]@{
        Generation = $generation; Path = $Path; InitialAudioPath = $InitialAudioPath
    }
    Start-PendingFolderScan
}

function Start-PendingFolderScan {
    if ($null -ne $script:folderScan -or $script:folderScanOrphans.Count -gt 0 -or
        $null -eq $script:folderScanPending -or $script:folderWindowClosed) { return }
    $request = $script:folderScanPending; $script:folderScanPending = $null
    $powerShell = [PowerShell]::Create()
    $powerShell.RunspacePool = Get-FolderRunspacePool
    $null = $powerShell.AddScript($script:folderScanWorker.ToString()).AddArgument($request.Path).AddArgument([string[]]$supportedExtensions).
        AddArgument([string]$script:folderSort).AddArgument([bool]$script:folderDescending)
    $state = [PSCustomObject]@{
        Generation = $request.Generation; Path = $request.Path; PowerShell = $powerShell
        InitialAudioPath = $request.InitialAudioPath; AsyncResult = $null; StopResult = $null; InvokeEnded = $false
    }
    $script:folderScan = $state
    try {
        $state.AsyncResult = $powerShell.BeginInvoke()
    }
    catch { Close-FolderScanState $state; $script:folderScan = $null; throw }
}

function Complete-FolderScanIfReady {
    Complete-OrphanScanDisposals
    $state = $script:folderScan
    if ($null -eq $state -or $null -eq $state.AsyncResult -or -not $state.AsyncResult.IsCompleted) { return }
    $script:folderScan = $null
    $entries = @(); $errorText = $null
    try { $entries = @($state.PowerShell.EndInvoke($state.AsyncResult)) }
    catch { $errorText = $_.Exception.Message }
    $state.InvokeEnded = $true
    try {
        if (-not $script:folderWindowClosed -and $state.Generation -eq $script:folderScanGeneration) {
            if ($null -ne $errorText) {
                Set-Status ('Folder unavailable: ' + $errorText)
                Publish-Diagnostics
            } else { Complete-FolderScan $state.Path $entries $state.InitialAudioPath }
        }
    } finally { Close-FolderScanState $state }
}
