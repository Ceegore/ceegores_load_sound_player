Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Describe 'Harness command acknowledgement regression' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        . (Join-Path $root 'scripts\test-script-player-helpers.ps1')
        function New-TrackCommandState {
            param([long] $Id, [string] $Name, [int] $Before, [int] $After)
            $paths = @('C:\fixture\clip-1.wav', 'C:\fixture\clip-2.wav', 'C:\fixture\clip-3.wav')
            return [PSCustomObject]@{
                CurrentIndex = $After; CurrentPath = $paths[$After]; PlaylistCount = $paths.Count; PlaylistPaths = $paths
                IsPaused = $false; Status = 'clip-3.wav'; PositionMilliseconds = 100; DurationMilliseconds = 30000
                LastAutomationCommandId = $Id; LastAutomationCommandName = $Name
                LastAutomationCommandBeforeIndex = $Before; LastAutomationCommandBeforePath = $paths[$Before]
                LastAutomationCommandBeforeIsPaused = $false
                LastAutomationCommandAfterIndex = $After; LastAutomationCommandAfterPath = $paths[$After]
                LastAutomationCommandAfterIsPaused = $false; CompletedPaths = @()
            }
        }
    }

    It 'accepts Next when auto-advance occurs after the external sample but before command processing' {
        $external = New-TrackCommandState 859 'Previous' 1 0
        $external.PositionMilliseconds = 999; $external.DurationMilliseconds = 1000
        $acknowledgement = New-TrackCommandState 860 'Next' 1 2
        $result = & {
            function Read-State { param([int] $TimeoutMilliseconds = 3000) return $external }
            function Send-BackgroundCommand { param([string] $Command) if ($Command -ne 'Next') { throw 'Unexpected command' }; return 860 }
            function Wait-State {
                param([scriptblock] $Predicate, [int] $TimeoutMilliseconds, [string] $Description,
                    [long] $ExpectedCommandId, $BeforeState, [string] $ExpectedCommand)
                if (-not (& $Predicate $acknowledgement)) { throw 'Simulated false timeout' }
                return $acknowledgement
            }
            Ensure-PauseResumeBaseline 'C:\fixture\invalid.wav'
        }
        $result.CurrentIndex | Should -Be 2
        (Test-TrackSwitchInvariant $result 1 860) | Should -Be $true
    }

    It 'rejects a missing, wrongly named, or ineffective command acknowledgement' {
        $valid = New-TrackCommandState 860 'Next' 1 2
        (Test-TrackSwitchInvariant $valid 1 861) | Should -Be $false
        $valid.LastAutomationCommandName = 'Previous'
        (Test-TrackSwitchInvariant $valid 1 860) | Should -Be $false
        $ineffective = New-TrackCommandState 860 'Next' 1 1
        (Test-TrackSwitchInvariant $ineffective 1 860) | Should -Be $false
    }

    It 'validates Previous against its dispatcher Before and After boundary' {
        $acknowledgement = New-TrackCommandState 861 'Previous' 2 1
        (Test-TrackSwitchInvariant $acknowledgement -1 861) | Should -Be $true
        $acknowledgement.LastAutomationCommandAfterPath = 'C:\fixture\clip-3.wav'
        (Test-TrackSwitchInvariant $acknowledgement -1 861) | Should -Be $false
    }

    It 'accepts a short target that naturally completes after an autoplay acknowledgement' {
        $finished = New-TrackCommandState 862 'Next' 1 2
        $finished.IsPaused = $true
        $finished.PositionMilliseconds = 0
        $finished.Status = 'Finished: clip-3.wav'
        $finished.CompletedPaths = @($finished.LastAutomationCommandAfterPath)
        (Test-TrackAutoplayOutcome $finished 'C:\fixture\invalid.wav') | Should -Be $true
        $finished.LastAutomationCommandAfterIsPaused = $true
        (Test-TrackAutoplayOutcome $finished 'C:\fixture\invalid.wav') | Should -Be $false
    }
}
