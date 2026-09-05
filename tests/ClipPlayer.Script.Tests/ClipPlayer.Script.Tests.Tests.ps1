Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Describe 'ClipPlayer PowerShell runtime coverage targets' {
    BeforeAll {
        $scriptRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        $productRoot = Join-Path $scriptRoot 'src\ClipPlayer.Script'
        $productFiles = @(
            'ClipPlayer.ps1', 'ClipPlayer.FolderMode.ps1', 'ClipPlayer.PlaybackState.ps1',
            'ClipPlayer.FolderScanner.ps1', 'ClipPlayer.PlaylistPaths.ps1', 'ClipPlayerLauncher.ps1'
        ) | ForEach-Object { Join-Path $productRoot $_ }
    }

    It 'discovers every productive script module' {
        foreach ($path in $productFiles) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -Be $true
            $tokens = $null; $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }
    }

    It 'executes folder and scanner code against a real fixture' {
        $supportedExtensions = @('.wav', '.mp3', '.flac')
        . (Join-Path $productRoot 'ClipPlayer.FolderMode.ps1')
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('ClipPlayer-pester-' + [Guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Path $fixture
            [IO.File]::WriteAllBytes((Join-Path $fixture 'clip10.wav'), [byte[]](0, 1))
            [IO.File]::WriteAllBytes((Join-Path $fixture 'clip2.mp3'), [byte[]](0, 1))
            [IO.File]::WriteAllText((Join-Path $fixture 'ignored.txt'), 'ignored')
            $entries = @(Get-FolderEntries $fixture)
            @($entries | Where-Object { -not $_.IsFolder }).Count | Should -Be 2
            (@($entries | ForEach-Object Name) -join ',') | Should -Match 'clip10|clip2'
            $worker = [PowerShell]::Create()
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.Open(); $worker.Runspace = $runspace
            $null = $worker.AddScript($script:folderScanWorker.ToString()).AddArgument($fixture).
                AddArgument([string[]]$supportedExtensions).AddArgument('Name').AddArgument($false)
            $async = $worker.BeginInvoke()
            $async.AsyncWaitHandle.WaitOne(5000) | Should -Be $true
            @($worker.EndInvoke($async)).Count | Should -Be 2
            $worker.Dispose(); $runspace.Close(); $runspace.Dispose()
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }

    It 'loads playback-state helpers and runs the main self-test' {
        . (Join-Path $productRoot 'ClipPlayer.PlaybackState.ps1')
        (Get-Command Restore-PlaybackSnapshot -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        . (Join-Path $productRoot 'ClipPlayer.ps1') -SelfTest
    }

    It 'executes the playback snapshot restore helper' {
        . (Join-Path $productRoot 'ClipPlayer.PlaybackState.ps1')
        $script:players = @{}
        $script:playlist = @()
        $script:currentIndex = -1
        $script:isPaused = $true
        $script:internalSelection = $false
        $script:playlistControl = [PSCustomObject]@{
            Items = [Collections.ArrayList]::new(); SelectedIndex = -1
        }
        function Close-Player { param([string]$Path) }
        function Update-Controls { }
        function Publish-Diagnostics { }
        function Sync-FolderSelection { param([string]$Path) }
        $snapshot = [PSCustomObject]@{
            Playlist = @((Join-Path $env:TEMP 'restore.wav')); Index = 0; Path = $null
            Position = [TimeSpan]::FromMilliseconds(25); Paused = $true; CachedPaths = @()
            Failures = @{}; SelectionIndex = 0; FolderSelectionPath = $null
        }
        Restore-PlaybackSnapshot $snapshot
        $script:currentIndex | Should -Be 0
        $script:isPaused | Should -Be $true
        $script:playlistControl.SelectedIndex | Should -Be 0
    }

    It 'returns exactly one player and preserves a queued seek when Open loses a pause race' {
        . (Join-Path $productRoot 'ClipPlayer.PlaybackState.ps1')
        $path = Join-Path $env:TEMP 'clipplayer-pending-open.wav'
        $position = [TimeSpan]::FromMilliseconds(1234)
        $script:fakePlayer = [PSCustomObject]@{
            Volume = 0.0; Position = [TimeSpan]::Zero; PlayCount = 0
            NaturalDuration = [PSCustomObject]@{ HasTimeSpan = $true }
        }
        $script:fakePlayer | Add-Member -MemberType ScriptMethod -Name Play -Value { $this.PlayCount++ }
        $script:pendingPlayback = @{}
        $script:volumeSlider = [PSCustomObject]@{ Value = 0.5 }
        function Get-Player { param([string]$Path) return $script:fakePlayer }

        $result = @(Start-PlayerPlayback $path $position)
        $result.Count | Should -Be 1
        [object]::ReferenceEquals($result[0], $script:fakePlayer) | Should -Be $true
        $script:fakePlayer.Position | Should -Be $position
        $script:fakePlayer.PlayCount | Should -Be 1
        $script:pendingPlayback.Count | Should -Be 0

        $script:fakePlayer.Position = [TimeSpan]::Zero
        $script:fakePlayer.PlayCount = 0
        $script:players = @{ $path = $script:fakePlayer }
        $script:playlist = @($path); $script:currentIndex = 0; $script:isPaused = $true
        $script:pendingPlayback = @{ $path = $position }
        $script:playerFailures = @{}; $script:completedPlayback = @{}
        $script:raceFixtureExpectedPosition = 0; $script:raceFixtureAppliedPosition = 0
        function Set-Status { param([string]$Text) }
        function Publish-Diagnostics { }

        Invoke-MediaEvent 'Opened' $path $script:fakePlayer $null
        $script:pendingPlayback.Count | Should -Be 0
        $script:fakePlayer.Position | Should -Be $position
        $script:fakePlayer.PlayCount | Should -Be 0
    }

    It 'parses and validates the launcher contract' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $productRoot 'ClipPlayerLauncher.ps1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($paramNames -contains 'AudioPath') | Should -Be $true
        @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)).Count |
            Should -BeGreaterThan 0
        (& (Join-Path $productRoot 'ClipPlayerLauncher.ps1') -SelfTest | Out-String) |
            Should -Match 'SELFTEST PASS'
    }

    It 'enforces async folder navigation, nonactive-delete cleanup, and bounded UI handoff' {
        $folderText = Get-Content -LiteralPath (Join-Path $productRoot 'ClipPlayer.FolderMode.ps1') -Raw
        $scannerText = Get-Content -LiteralPath (Join-Path $productRoot 'ClipPlayer.FolderScanner.ps1') -Raw
        $playerText = Get-Content -LiteralPath (Join-Path $productRoot 'ClipPlayer.ps1') -Raw
        $folderText | Should -Match 'Stop-FolderScan\s+-Invalidate'
        $folderText | Should -Match 'Remove-PlaylistPath\s+\$path'
        $playerText | Should -Match 'initialFolderScanPath'
        $scannerText | Should -Match 'ItemsSource\s*=\s*\$script:folderEntries'
        $scannerText | Should -Match 'Complete-OrphanScanDisposals'
        $scannerText | Should -Match 'Stop-AllFolderScans'
        $scannerText | Should -Match 'folderScanPending'
        $scannerText | Should -Match 'BeginStop'
        $scannerText | Should -Match 'folderSortWorker'
        $scannerText | Should -Match 'Complete-FolderSortIfReady'
        $scannerText | Should -Not -Match 'folderView\.Items\.Add'
        $folderText | Should -Not -Match 'Get-SortedFolderEntries\s+\$script:folderEntries'
    }

    It 'uses explicit completion state for the ended restart race' {
        $playerText = Get-Content -LiteralPath (Join-Path $productRoot 'ClipPlayer.ps1') -Raw
        $playbackText = Get-Content -LiteralPath (Join-Path $productRoot 'ClipPlayer.PlaybackState.ps1') -Raw
        @((Get-Content -LiteralPath (Join-Path $productRoot 'ClipPlayer.ps1')).Count) | Should -BeLessThan 501
        $playbackText | Should -Match 'completedPlayback'
        $playbackText | Should -Match 'Test-PlaybackCompleted'
        $playbackText | Should -Match 'Close-Player \$path'
        $playbackText | Should -Match 'Invoke-EndedRestartRaceTestFixture'
        $playbackText | Should -Match 'raceFixtureAppliedPosition'
        $playbackText | Should -Not -Match 'Invoke-MediaEvent ''Ended'' \$path \$newPlayer'
        $playbackText | Should -Not -Match 'Position -lt.*NaturalDuration'
        $playerText | Should -Match 'InjectEndedRestartRaceTestFixture'
        $playerText | Should -Match 'Reset-PlaybackCompletion'
    }

    It 'removes a nonactive path without resetting the current index' {
        $supportedExtensions = @('.wav', '.mp3', '.flac')
        . (Join-Path $productRoot 'ClipPlayer.FolderMode.ps1')
        $items = New-Object Collections.Generic.List[object]
        $script:playlistControl = [PSCustomObject]@{ Items = $items; SelectedIndex = 0 }
        $script:playlist = @(
            (Join-Path $env:TEMP 'clipplayer-a.wav'),
            (Join-Path $env:TEMP 'clipplayer-b.wav'),
            (Join-Path $env:TEMP 'clipplayer-c.wav'))
        $script:currentIndex = 2; $script:isPaused = $false; $script:players = @{}
        function Set-PreloadWindow { }
        function Update-Controls { }
        function Publish-Diagnostics { }
        Remove-PlaylistPath $script:playlist[0]
        $script:playlist.Count | Should -Be 2
        $script:currentIndex | Should -Be 1
        $script:playlistControl.SelectedIndex | Should -Be 1
    }

    It 'invalidates an in-flight scan when navigation is rejected' {
        $supportedExtensions = @('.wav', '.mp3', '.flac')
        . (Join-Path $productRoot 'ClipPlayer.FolderMode.ps1')
        $script:statusText = [PSCustomObject]@{ Text = '' }
        $script:folderScanGeneration = 4
        $script:folderScan = [PSCustomObject]@{ AsyncResult = $null }
        function Stop-FolderScan {
            param([switch]$Invalidate)
            if ($Invalidate) { $script:folderScanGeneration++; $script:folderScan = $null }
        }
        function Set-Status { param([string]$Text) $script:statusText.Text = $Text }
        (Show-Folder (Join-Path ([IO.Path]::GetTempPath()) 'clipplayer-folder-that-does-not-exist')) | Should -Be $false
        $script:folderScanGeneration | Should -Be 5
        $script:folderScan | Should -Be $null
        $script:statusText.Text | Should -Match 'Folder unavailable:'
    }
}
