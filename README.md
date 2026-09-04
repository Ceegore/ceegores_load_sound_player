# ClipPlayer

ClipPlayer ist ein kleiner Windows-Soundplayer fuer WAV, MP3 und FLAC. Auf diesem
SAC-erzwungenen Entwicklungsrechner ist der primaere Laufweg das reine WPF-Skript im
Microsoft-signierten Windows-PowerShell-5.1-Host.

## Direkt starten

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoLogo -NoProfile -STA -File ".\src\ClipPlayer.Script\ClipPlayerLauncher.ps1" ".\sound.wav"
```

Es werden keine Sicherheitsrichtlinien veraendert und kein `ExecutionPolicy Bypass`
verwendet. Pfeil links/rechts wechselt mit Autoplay, Space pausiert oder setzt fort,
Delete verschiebt nach Rueckfrage in den Papierkorb.

## Fuer den aktuellen Benutzer installieren

```powershell
.\scripts\install-script-player.ps1
```

Dies installiert nach `%LOCALAPPDATA%\Programs\ClipPlayer`, legt einen
Startmenueeintrag an und registriert ClipPlayer unter "Oeffnen mit" sowie im
Explorer-Kontextmenue. Die bestehende Standard-App wird nicht veraendert; die Auswahl
erfolgt weiterhin ueber die Windows-Einstellungen.

Rueckgaengig machen:

```powershell
.\scripts\uninstall-script-player.ps1
```

## Tests

```powershell
.\scripts\test-script-player-e2e.ps1 -DurationSeconds 60 -CpuWorkers 4 -ExerciseDelete
```

Der Test bedient das reale Fenster, erzeugt nur stumme temporaere WAVs, misst
Wechsellatenzen und prueft das Code-Integrity-Protokoll. Das Fenster wird dabei
minimiert und nicht aktiviert; der Test verwendet weder `SendKeys` noch `AppActivate`
und entzieht anderen Anwendungen nicht den Eingabefokus. Fuer die Release-Gates des
weiterhin vorhandenen .NET/MSIX-Pfads siehe `scripts\verify-release.ps1`.
