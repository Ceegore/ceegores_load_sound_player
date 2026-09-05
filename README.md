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

Fuer einen SAC-erzwungenen Rechner ist der lokale Git-Checkout der gemessene
Installationsweg. Beispiel fuer Release `v1.0.2`:

```powershell
git clone --depth 1 --branch v1.0.2 https://github.com/Ceegore/ceegores_load_sound_player.git ClipPlayer
Set-Location .\ClipPlayer
.\scripts\install-script-player.ps1
```

### WAV im Windows Explorer per Doppelklick

Nach der Installation funktioniert **Rechtsklick auf eine WAV > `Play with
ClipPlayer`** sofort. Damit WAVs direkt per Doppelklick starten, fuehre einmal
Folgendes aus:

```powershell
.\scripts\install-script-player.ps1 -OpenDefaultAppSettings
```

Windows oeffnet die Default-Apps-Einstellungen. Dort nach `ClipPlayer` suchen
und `.wav` zuweisen (optional auch `.mp3` und `.flac`). Falls ClipPlayer dort
nicht direkt erscheint: Rechtsklick auf eine WAV > **Oeffnen mit** > **Andere
App auswaehlen** > `ClipPlayer`, dann **Immer diese App zum Oeffnen von
.wav-Dateien verwenden** aktivieren. Windows schuetzt diese Wahl; der Installer
registriert ClipPlayer, ersetzt aber keine bestehende Standard-App heimlich.

Jeder so geoeffnete Sound startet sofort. Parallel liest ClipPlayer nur den
direkten Ordner ein (keine Unterordner), baut daraus die Geschwister-Playlist
und laedt den aktuellen sowie die naechsten drei Sounds vor. **Next** bzw.
Pfeil rechts spielt die naechste Datei in der sichtbaren Reihenfolge. Endet ein
sehr kurzes angeklicktes WAV noch waehrend der Ordner eingelesen wird, setzt
ClipPlayer nach dem Laden mit dem naechsten Geschwistersound fort, statt den
fertigen Sound erneut zu starten.

### Browser-ZIP unter RemoteSigned

Ein per Browser geladenes ZIP kann Mark-of-the-Web tragen und deshalb als
"nicht digital signiert" abgelehnt werden. Fuer das **gepruefte** Release-ZIP
ist dies der kurze, gemessene Ablauf. Den Ordner nur verwenden, wenn er neu/leer
ist und nur die Dateien dieses Releases enthaelt:

```powershell
$zip = "$env:USERPROFILE\Downloads\ClipPlayer-source-1.0.2.zip"
$release = "C:\Tools\ClipPlayer-1.0.2"
$expected = ((Get-Content -LiteralPath "${zip}.sha256" -TotalCount 1) -split '\s+')[0]
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
  throw "Release-ZIP stimmt nicht mit der mitgelieferten SHA-256-Datei ueberein."
}
Expand-Archive -LiteralPath $zip -DestinationPath $release
Get-ChildItem -LiteralPath $release -Recurse -File | Unblock-File
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile `
  -File "$release\scripts\install-script-player.ps1"
Start-Process "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\ClipPlayer.lnk"
```

`Unblock-File` entfernt hier nur die Internet-Markierung nach erfolgreicher
Hash-Pruefung; es aendert weder Execution Policy noch SAC/Defender. Es ist keine
Loesung fuer eine echte WDAC-/AppLocker-Skriptregel. In diesem Fall den
organisatorisch signierten/freigegebenen Verteilweg verwenden. Ein lokaler
Git-Checkout hat normalerweise keine Internet-Markierung und braucht diesen
Schritt nicht.

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
