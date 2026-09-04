# ClipPlayer MSIX

Das Windows Application Packaging Project baut ausschließlich x64 und führt die
.NET-Runtime selbstenthaltend mit. `AppxPackageSigningEnabled` bleibt im Repository
deaktiviert: Store-Signierung oder ein CA-vertrauenswürdiges RSA-Zertifikat erfolgt
erst in der Release-Pipeline und wird nicht als Geheimnis eingecheckt. Das Manifest
zielt auf Windows 11 (`Windows.Desktop`, Mindestversion 10.0.22621.0).

Das Manifest registriert nur `.wav`, `.mp3` und `.flac`. Es setzt keine Standard-App
und enthält keine Explorer-COM-Erweiterung. Ein eigener Kontextmenü-COM-Handler ist
bewusst nicht Bestandteil von Version 1; Windows' „Öffnen mit“ nutzt die Association.

## Assets

Die drei neutralen Icons sind selbst erzeugte geometrische PNGs ohne externe
Marken- oder Codecs. `StoreLogo`, `Square44x44Logo` und `Square150x150Logo` liegen
als unqualifizierte Fallback-Datei sowie in den MSIX-Skalierungen 100, 125, 150,
200, 300 und 400 vor. Die Dateien werden mit
`Assets/Generate-PackageAssets.ps1` reproduzierbar erzeugt; das Skript wird nicht
in den Paketinhalt aufgenommen.

## Lokale statische Prüfung

Aus dem Repository-Root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\packaging\ClipPlayer.Package\Validate-Package.ps1
```

Der Validator prüft alle Manifestpfade, PNG-Dateien als PNG, die erwarteten
Pixelgrößen, die drei und nur drei Associations, x64 und das Fehlen von SVG-/Shell-
COM-Assets. Das kann ohne Visual Studio/MSIX-Targets geprüft
werden; ein erfolgreicher XML-/Asset-Check ist ausdrücklich kein Paket- oder
Signaturerfolg.

Der direkte CLI-Versuch
`dotnet msbuild packaging/ClipPlayer.Package/ClipPlayer.Package.wapproj
/t:Build /p:Configuration=Release /p:Platform=x64` wurde in der aktuellen
Umgebung ausgeführt und endet mit `MSB4057` (Target `Build` nicht vorhanden),
weil `Microsoft.AppXPackage.Targets` aus Visual Studio nicht installiert ist.
Dieser Exitcode bleibt ein nicht erfülltes Packaging-Gate; der Validator oben darf
ihn nicht ersetzen.

## Visual-Studio-/MSIX-Gate für Releases

1. Visual Studio 2022 17.x mit Workload „.NET-Desktopentwicklung“ und
   „Windows-Anwendungsentwicklung“ sowie Windows 11 SDK 22621+ installieren.
2. `ClipPlayer.sln` in Visual Studio öffnen, `Release | x64` wählen und das
   WAP-Projekt `ClipPlayer.Package` erstellen. Falls `Microsoft.AppXPackage.Targets`
   fehlt, ist dies ein Umgebungsfehler; nicht als grünen MSIX-Build melden.
3. Im erzeugten Paket manifestbezogene Warnungen prüfen; insbesondere müssen alle
   Dateien aus `Assets\*.png` enthalten sein und keine SVG-/unbekannten DLL- oder
   Codec-Dateien auftauchen.
4. Für den Store die von Partner Center vorgegebenen `Identity`-Werte verwenden.
   Für direkten Download ausschließlich ein CA-vertrauenswürdiges Zertifikat mit
   Zeitstempel einsetzen. Niemals ein Zertifikat, ein Kennwort oder Store-Secrets
   committen; Selbstsignierung ist kein SAC-/SmartScreen-Release-Gate.
5. `signtool verify /pa /all /v <Paket>` ausführen und danach das exakt signierte
   Artefakt auf einem Windows-11-SAC-Enforcement-Rechner installieren. Installation,
   WAV/MP3/FLAC-Dateiaktivierung, Wiedergabe, Deinstallation und CodeIntegrity-
   Ereignisse 3033/3077 gehören in denselben Abnahmelauf.

Das Repository behauptet ohne diese Schritte weder erfolgreiche MSIX-Erzeugung noch
Store-Freigabe, Signaturvertrauen oder SAC-Kompatibilität. Host-Sicherheitsrichtlinien
werden zu keinem Zeitpunkt verändert.
