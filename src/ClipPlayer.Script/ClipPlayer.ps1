[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $AudioPath,
    [string] $DiagnosticsPath,
    [string] $AutomationCommandPath,
    [switch] $BackgroundTest,
    [switch] $SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal }
catch { }

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName Microsoft.VisualBasic

$supportedExtensions = @('.wav', '.mp3', '.flac')
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClipPlayer" Width="640" Height="520" MinWidth="420" MinHeight="360"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="*" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <Button x:Name="OpenButton" DockPanel.Dock="Right" Content="Open..." MinWidth="80"
              MinHeight="34" Padding="10,4" AutomationProperties.Name="Open audio files" />
      <TextBlock Text="ClipPlayer" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center" />
    </DockPanel>
    <ListBox x:Name="Playlist" Grid.Row="1" AutomationProperties.Name="Audio files"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled" />
    <DockPanel Grid.Row="2" Margin="0,12,0,0">
      <TextBlock x:Name="PositionText" DockPanel.Dock="Left" Text="0:00" Width="48"
                 VerticalAlignment="Center" />
      <TextBlock x:Name="DurationText" DockPanel.Dock="Right" Text="0:00" Width="48"
                 TextAlignment="Right" VerticalAlignment="Center" />
      <Slider x:Name="PositionSlider" Minimum="0" Maximum="1" IsEnabled="False"
              AutomationProperties.Name="Position" />
    </DockPanel>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,8">
      <Button x:Name="PreviousButton" Content="Previous" MinWidth="78" MinHeight="34" Margin="3"
              AutomationProperties.Name="Play previous sound" />
      <Button x:Name="PauseButton" Content="Play / Pause" MinWidth="92" MinHeight="34" Margin="3"
              AutomationProperties.Name="Pause or resume playback" />
      <Button x:Name="NextButton" Content="Next" MinWidth="78" MinHeight="34" Margin="3"
              AutomationProperties.Name="Play next sound" />
      <Button x:Name="DeleteButton" Content="Delete" MinWidth="78" MinHeight="34" Margin="3"
              AutomationProperties.Name="Move sound to Recycle Bin" />
    </StackPanel>
    <DockPanel Grid.Row="4" LastChildFill="True">
      <TextBlock DockPanel.Dock="Left" Text="Volume" VerticalAlignment="Center" Margin="3,0,10,0" />
      <Slider x:Name="VolumeSlider" Minimum="0" Maximum="1" Value="1"
              AutomationProperties.Name="Volume" />
      <TextBlock x:Name="StatusText" DockPanel.Dock="Bottom" Text="No file opened"
                 Margin="3,8,3,0" TextTrimming="CharacterEllipsis"
                 AutomationProperties.LiveSetting="Polite" />
    </DockPanel>
  </Grid>
</Window>
'@

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

if ($SelfTest) {
    $probeWindow = New-WindowFromXaml
    $requiredNames = @(
        'Playlist', 'OpenButton', 'PreviousButton', 'PauseButton', 'NextButton',
        'DeleteButton', 'PositionSlider', 'VolumeSlider', 'StatusText'
    )
    foreach ($name in $requiredNames) {
        if ($null -eq $probeWindow.FindName($name)) { throw "Missing UI element: $name" }
    }
    if ($supportedExtensions.Count -ne 3 -or -not (Test-SupportedPath 'probe.wav')) {
        throw 'Supported file rules are invalid.'
    }
    $names = @('clip10.wav', 'clip2.wav', 'clip1.wav' | Sort-Object { Get-NaturalSortKey $_ })
    if (($names -join ',') -ne 'clip1.wav,clip2.wav,clip10.wav') { throw 'Natural file ordering is invalid.' }
    $probeWindow.Close()
    Write-Output 'SELFTEST PASS: trusted-host XAML and file rules are valid.'
    return
}

$script:window = New-WindowFromXaml
$script:playlistControl = $window.FindName('Playlist')
$script:openButton = $window.FindName('OpenButton')
$script:previousButton = $window.FindName('PreviousButton')
$script:pauseButton = $window.FindName('PauseButton')
$script:nextButton = $window.FindName('NextButton')
$script:deleteButton = $window.FindName('DeleteButton')
$script:positionSlider = $window.FindName('PositionSlider')
$script:volumeSlider = $window.FindName('VolumeSlider')
$script:positionText = $window.FindName('PositionText')
$script:durationText = $window.FindName('DurationText')
$script:statusText = $window.FindName('StatusText')
$script:playlist = @()
$script:currentIndex = -1
$script:players = @{}
$script:playerFailures = @{}
$script:isPaused = $false
$script:internalSelection = $false
$script:seeking = $false
$script:diagnosticTick = 0
$script:lastAutomationCommandId = 0
$script:lastAutomationCommandDurationMilliseconds = 0

function Publish-Diagnostics {
    if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) { return }
    try {
        $currentPath = $null
        if ($script:currentIndex -ge 0 -and $script:currentIndex -lt $script:playlist.Count) {
            $currentPath = $script:playlist[$script:currentIndex]
        }
        $state = [ordered]@{
            ProcessId = $PID
            CurrentIndex = $script:currentIndex
            CurrentPath = $currentPath
            IsPaused = $script:isPaused
            PositionMilliseconds = if ($currentPath -and $script:players.ContainsKey($currentPath)) {
                [Math]::Round($script:players[$currentPath].Position.TotalMilliseconds)
            } else { 0 }
            DurationMilliseconds = if ($currentPath -and $script:players.ContainsKey($currentPath) -and
                $script:players[$currentPath].NaturalDuration.HasTimeSpan) {
                [Math]::Round($script:players[$currentPath].NaturalDuration.TimeSpan.TotalMilliseconds)
            } else { 0 }
            CachedPlayerCount = $script:players.Count
            CachedPaths = @($script:players.Keys)
            Status = $script:statusText.Text
            LastAutomationCommandId = $script:lastAutomationCommandId
            LastAutomationCommandDurationMilliseconds = $script:lastAutomationCommandDurationMilliseconds
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText($DiagnosticsPath, ($state | ConvertTo-Json -Compress))
    } catch { }
}

function Set-Status {
    param([string] $Text)
    $script:statusText.Text = $Text
}

function Update-Controls {
    $hasCurrent = $script:currentIndex -ge 0 -and $script:currentIndex -lt $script:playlist.Count
    $script:previousButton.IsEnabled = $hasCurrent -and $script:currentIndex -gt 0
    $script:nextButton.IsEnabled = $hasCurrent -and $script:currentIndex -lt ($script:playlist.Count - 1)
    $script:pauseButton.IsEnabled = $hasCurrent
    $script:deleteButton.IsEnabled = $hasCurrent
}

function Close-Player {
    param([string] $Path)
    if ($script:players.ContainsKey($Path)) {
        try { $script:players[$Path].Close() } catch { }
        $null = $script:players.Remove($Path)
    }
    $null = $script:playerFailures.Remove($Path)
}

function Invoke-MediaEvent {
    param([string] $Kind, [string] $Path, $Player, $EventArgs)
    if (-not $script:players.ContainsKey($Path) -or
        -not ([object]::ReferenceEquals($script:players[$Path], $Player))) { return }
    $isCurrent = $script:currentIndex -ge 0 -and $script:playlist[$script:currentIndex] -eq $Path
    switch ($Kind) {
        'Failed' {
            $message = if ($null -ne $EventArgs.ErrorException) { $EventArgs.ErrorException.Message }
                else { 'Audio could not be opened.' }
            $script:playerFailures[$Path] = $message
            if ($isCurrent) { $script:isPaused = $true; Set-Status ("Playback error: " + $message); Publish-Diagnostics }
        }
        'Opened' {
            $null = $script:playerFailures.Remove($Path)
            if ($isCurrent -and -not $script:isPaused) {
                $Player.Play(); Set-Status ([IO.Path]::GetFileName($Path)); Publish-Diagnostics
            }
        }
        'Ended' {
            if (-not $isCurrent) { return }
            if ($script:currentIndex -lt ($script:playlist.Count - 1)) { Select-Track ($script:currentIndex + 1) }
            else {
                $Player.Position = [TimeSpan]::Zero; $script:isPaused = $true
                Set-Status ("Finished: " + [IO.Path]::GetFileName($Path)); Publish-Diagnostics
            }
        }
    }
}

function Get-Player {
    param([string] $Path)
    if ($script:players.ContainsKey($Path)) { return $script:players[$Path] }

    $player = New-Object System.Windows.Media.MediaPlayer
    $player.Volume = [double]$script:volumeSlider.Value
    $eventPath = $Path
    $eventPlayer = $player
    $eventCallback = ${function:Invoke-MediaEvent}
    $player.add_MediaFailed(({ param($sender, $failureArgs); & $eventCallback 'Failed' $eventPath $eventPlayer $failureArgs }).GetNewClosure())
    $player.add_MediaOpened(({ & $eventCallback 'Opened' $eventPath $eventPlayer $null }).GetNewClosure())
    $player.add_MediaEnded(({ & $eventCallback 'Ended' $eventPath $eventPlayer $null }).GetNewClosure())
    $script:players[$Path] = $player
    $player.Open((New-Object Uri($Path, [UriKind]::Absolute)))
    return $player
}

function Set-PreloadWindow {
    if ($script:currentIndex -lt 0) { return }
    $first = [Math]::Max(0, $script:currentIndex - 1)
    $last = [Math]::Min($script:playlist.Count - 1, $script:currentIndex + 3)
    $wanted = @{}
    for ($index = $first; $index -le $last; $index++) {
        $path = $script:playlist[$index]
        $wanted[$path] = $true
        $null = Get-Player $path
    }
    foreach ($cachedPath in @($script:players.Keys)) {
        if (-not $wanted.ContainsKey($cachedPath)) { Close-Player $cachedPath }
    }
    Publish-Diagnostics
}

function Select-Track {
    param([int] $Index)
    if ($Index -lt 0 -or $Index -ge $script:playlist.Count) { return }

    if ($script:currentIndex -ge 0) {
        $oldPath = $script:playlist[$script:currentIndex]
        if ($script:players.ContainsKey($oldPath)) {
            $script:players[$oldPath].Pause()
            $script:players[$oldPath].Position = [TimeSpan]::Zero
        }
    }

    $script:currentIndex = $Index
    $script:isPaused = $false
    $script:internalSelection = $true
    $script:playlistControl.SelectedIndex = $Index
    $script:playlistControl.ScrollIntoView($script:playlistControl.SelectedItem)
    $script:internalSelection = $false
    Set-PreloadWindow

    $path = $script:playlist[$Index]
    Set-Status ("Opening: " + [IO.Path]::GetFileName($path))
    if ($script:playerFailures.ContainsKey($path)) { Close-Player $path }
    $player = Get-Player $path
    $player.Volume = [double]$script:volumeSlider.Value
    $player.Position = [TimeSpan]::Zero
    $player.Play()
    if ($player.NaturalDuration.HasTimeSpan) { Set-Status ([IO.Path]::GetFileName($path)) }
    Update-Controls
    Publish-Diagnostics
}

function Set-Playlist {
    param([string[]] $Paths, [int] $SelectedIndex = 0)
    foreach ($cachedPath in @($script:players.Keys)) { Close-Player $cachedPath }
    $script:playlist = @($Paths | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and (Test-SupportedPath $_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Sort-Object @{ Expression = { Get-NaturalSortKey $_ } }, @{ Expression = { $_ } })
    $script:playlistControl.Items.Clear()
    foreach ($path in $script:playlist) { $null = $script:playlistControl.Items.Add([IO.Path]::GetFileName($path)) }
    if ($script:playlist.Count -eq 0) {
        $script:currentIndex = -1
        Set-Status 'No supported files found'
        Update-Controls
        return
    }
    Select-Track ([Math]::Max(0, [Math]::Min($SelectedIndex, $script:playlist.Count - 1)))
}

function Open-AudioFiles {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Open audio files'
    $dialog.Filter = 'Audio files (*.wav;*.mp3;*.flac)|*.wav;*.mp3;*.flac|All files (*.*)|*.*'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog($script:window)) { Set-Playlist $dialog.FileNames 0 }
}

function Toggle-Pause {
    if ($script:currentIndex -lt 0) { return }
    $path = $script:playlist[$script:currentIndex]
    if ($script:playerFailures.ContainsKey($path)) { Close-Player $path }
    $player = Get-Player $path
    if ($script:isPaused) {
        if ($player.NaturalDuration.HasTimeSpan -and
            $player.Position -ge ($player.NaturalDuration.TimeSpan - [TimeSpan]::FromMilliseconds(50))) {
            $player.Position = [TimeSpan]::Zero
        }
        $player.Play()
        $script:isPaused = $false
        Set-Status $(if ($player.NaturalDuration.HasTimeSpan) { [IO.Path]::GetFileName($path) }
            else { "Opening: " + [IO.Path]::GetFileName($path) })
    } else {
        $player.Pause()
        $script:isPaused = $true
        Set-Status ("Paused: " + [IO.Path]::GetFileName($path))
    }
    Publish-Diagnostics
}

function Remove-CurrentTrack {
    param([switch] $SkipConfirmation)
    if ($script:currentIndex -lt 0) { return }
    $path = $script:playlist[$script:currentIndex]
    if ($SkipConfirmation) {
        $diagnosticFolder = if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) { '' }
            else { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DiagnosticsPath)) }
        if (-not $BackgroundTest -or [string]::IsNullOrWhiteSpace($AutomationCommandPath) -or
            [IO.Path]::GetDirectoryName($path) -ne $diagnosticFolder -or
            [IO.Path]::GetFileName($path) -notmatch '^clip-[1-5]\.wav$') {
            throw 'Unconfirmed deletion is restricted to generated background-test fixtures.'
        }
    } else {
        $answer = [Windows.MessageBox]::Show(
            "Move '$([IO.Path]::GetFileName($path))' to the Recycle Bin?",
            'ClipPlayer', [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }

    Close-Player $path
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    } catch {
        Select-Track $script:currentIndex
        Set-Status ("Delete failed: " + $_.Exception.Message)
        return
    }
    $remaining = @($script:playlist | Where-Object { $_ -ne $path })
    if ($remaining.Count -eq 0) { Set-Playlist @(); return }
    Set-Playlist $remaining ([Math]::Min($script:currentIndex, $remaining.Count - 1))
}

function Invoke-PlayerCommand {
    param([string] $Command)
    switch ($Command) {
        'Previous' { Select-Track ($script:currentIndex - 1) }
        'Next' { Select-Track ($script:currentIndex + 1) }
        'TogglePause' { Toggle-Pause }
        'Delete' { Remove-CurrentTrack }
        'DeleteConfirmedTestFixture' { Remove-CurrentTrack -SkipConfirmation }
        'Close' { $script:window.Close() }
        default { throw "Unknown player command: $Command" }
    }
}

function Read-AutomationCommand {
    if (-not $BackgroundTest -or [string]::IsNullOrWhiteSpace($AutomationCommandPath) -or
        -not (Test-Path -LiteralPath $AutomationCommandPath -PathType Leaf)) { return }
    try {
        $raw = [IO.File]::ReadAllText($AutomationCommandPath)
        $separator = $raw.IndexOf('|')
        if ($separator -le 0) { return }
        $commandId = [long]::Parse($raw.Substring(0, $separator), [Globalization.CultureInfo]::InvariantCulture)
        if ($commandId -le $script:lastAutomationCommandId) { return }
        $commandWatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-PlayerCommand $raw.Substring($separator + 1)
        $commandWatch.Stop()
        $script:lastAutomationCommandDurationMilliseconds = $commandWatch.Elapsed.TotalMilliseconds
        $script:lastAutomationCommandId = $commandId
        Publish-Diagnostics
    } catch [IO.IOException] { return }
    catch {
        Set-Status ("Automation error: " + $_.Exception.Message)
    }
}

$script:openButton.Add_Click({ Open-AudioFiles })
$script:previousButton.Add_Click({ Invoke-PlayerCommand 'Previous' })
$script:nextButton.Add_Click({ Invoke-PlayerCommand 'Next' })
$script:pauseButton.Add_Click({ Invoke-PlayerCommand 'TogglePause' })
$script:deleteButton.Add_Click({ Invoke-PlayerCommand 'Delete' })
$script:volumeSlider.Add_ValueChanged({
    foreach ($player in $script:players.Values) { $player.Volume = [double]$script:volumeSlider.Value }
})
$script:playlistControl.Add_SelectionChanged({
    if (-not $script:internalSelection -and $script:playlistControl.SelectedIndex -ge 0 -and
        $script:playlistControl.SelectedIndex -ne $script:currentIndex) {
        Select-Track $script:playlistControl.SelectedIndex
    }
})
$script:window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None) { return }
    switch ($eventArgs.Key) {
        ([Windows.Input.Key]::Left) { Invoke-PlayerCommand 'Previous'; $eventArgs.Handled = $true }
        ([Windows.Input.Key]::Right) { Invoke-PlayerCommand 'Next'; $eventArgs.Handled = $true }
        ([Windows.Input.Key]::Space) { Invoke-PlayerCommand 'TogglePause'; $eventArgs.Handled = $true }
        ([Windows.Input.Key]::Delete) { Invoke-PlayerCommand 'Delete'; $eventArgs.Handled = $true }
    }
})
function Complete-Seek {
    if ($script:currentIndex -ge 0) {
        $path = $script:playlist[$script:currentIndex]
        $player = Get-Player $path
        if ($player.NaturalDuration.HasTimeSpan) {
            $seconds = $player.NaturalDuration.TimeSpan.TotalSeconds * [double]$script:positionSlider.Value
            $player.Position = [TimeSpan]::FromSeconds($seconds)
        }
    }
    $script:seeking = $false
}
$script:positionSlider.Add_PreviewMouseDown({ $script:seeking = $true })
$script:positionSlider.Add_PreviewMouseUp({ Complete-Seek })
$script:positionSlider.Add_LostMouseCapture({ if ($script:seeking) { Complete-Seek } })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($(if ($BackgroundTest) { 50 } else { 200 }))
$timer.Add_Tick({
    Read-AutomationCommand
    if ($script:currentIndex -lt 0) { return }
    $path = $script:playlist[$script:currentIndex]
    if (-not $script:players.ContainsKey($path)) { return }
    $player = $script:players[$path]
    $script:positionText.Text = Convert-TimeText $player.Position
    if ($player.NaturalDuration.HasTimeSpan) {
        $duration = $player.NaturalDuration.TimeSpan
        $script:durationText.Text = Convert-TimeText $duration
        $script:positionSlider.IsEnabled = $true
        if (-not $script:seeking -and $duration.TotalSeconds -gt 0) {
            $script:positionSlider.Value = [Math]::Min(1, $player.Position.TotalSeconds / $duration.TotalSeconds)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
        $script:diagnosticTick++
        if ($BackgroundTest -or $script:diagnosticTick -ge 5) {
            $script:diagnosticTick = 0
            Publish-Diagnostics
        }
    }
})
$script:window.Add_Closed({
    $timer.Stop()
    foreach ($cachedPath in @($script:players.Keys)) { Close-Player $cachedPath }
    Publish-Diagnostics
})

Update-Controls
if ($BackgroundTest) {
    $script:window.ShowActivated = $false
    $script:window.ShowInTaskbar = $false
    $script:window.WindowState = [Windows.WindowState]::Minimized
}
if (Test-SupportedPath $AudioPath -and (Test-Path -LiteralPath $AudioPath -PathType Leaf)) {
    $fullPath = [IO.Path]::GetFullPath($AudioPath)
    $folder = [IO.Path]::GetDirectoryName($fullPath)
    $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object { Test-SupportedPath $_.FullName } |
        Sort-Object @{ Expression = { Get-NaturalSortKey $_.FullName } }, FullName |
        ForEach-Object { $_.FullName })
    $selected = -1
    for ($index = 0; $index -lt $files.Count; $index++) {
        if ([string]::Equals($files[$index], $fullPath, [StringComparison]::OrdinalIgnoreCase)) { $selected = $index; break }
    }
    Set-Playlist $files ([Math]::Max(0, $selected))
}

$timer.Start()
$null = $script:window.ShowDialog()
