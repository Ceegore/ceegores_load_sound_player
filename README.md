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

Der Schalter `Folder mode` blendet eine Explorer-aehnliche Detailansicht ein. Sie zeigt
nur Ordner sowie WAV-, MP3- und FLAC-Dateien, kann ueber `This PC`, `Up` und die
Adresszeile navigieren und nach Name, Erstellungs-/Aenderungsdatum, Typ oder Groesse
auf- und absteigend sortieren. Ein Doppelklick oder Enter startet eine Datei; die
sichtbare Sortierung wird dabei zur Wiedergabereihenfolge und die naechsten drei
Sounds werden wie in der normalen Ansicht vorgeladen.

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
.\scripts\test-script-player-e2e.ps1 -DurationSeconds 60 -CpuWorkers 0 -ExerciseDelete
```

Der Test bedient das reale Fenster, erzeugt nur stumme temporaere WAVs, prueft auch
Ordnernavigation, alle Sortierfelder, Preloading, Loeschen, defekte Medien und Neustart
am Listenende und misst Wechsellatenzen gegen feste Budgets
und prueft das Code-Integrity-Protokoll. `-CpuWorkers 0` erzeugt keine zusaetzliche
Last; fuer einen dedizierten Lastrechner kann ein kleiner positiver Wert gesetzt werden.
Das Fenster wird dabei
minimiert und nicht aktiviert; der Test verwendet weder `SendKeys` noch `AppActivate`
und entzieht anderen Anwendungen nicht den Eingabefokus. Fuer die Release-Gates des
weiterhin vorhandenen .NET/MSIX-Pfads siehe `scripts\verify-release.ps1`.

Mit installiertem `ffmpeg` prueft der folgende optionale Entwicklungstest die wirklich
installierte Kopie mit stummen WAV-, MP3- und FLAC-Dateien:

```powershell
.\scripts\test-installed-formats-e2e.ps1
```
