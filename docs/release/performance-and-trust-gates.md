# Release-Gates für Performance und Vertrauen

Stand: 2026-09-04. Dieses Dokument ergänzt `docs/SAC.md` und den Implementierungsplan.

## Automatischer, hardwarefreier Gate-Lauf

Der reproduzierbare lokale Lauf führt locked Restore, Release-Builds der .NET-
Projekte, SAC-sichere ausgewählte Tests, symbolfreies self-contained x64-Publish,
statische Paketprüfung und SBOM-Prüfung aus. Das WAP/MSIX-Projekt wird wegen der
Visual-Studio-Targets separat als externes Gate gebaut:

```powershell
powershell -NoProfile -File .\scripts\verify-release.ps1
```

Optional kann der Performance-Satz in denselben Lauf aufgenommen werden:

```powershell
powershell -NoProfile -File .\scripts\verify-release.ps1 -IncludePerformance
```

Ein Fehler der Host-ExecutionPolicy wird nicht umgangen; der Lauf ist dann nach
Unternehmensvorgabe auf einem erlaubten/signierten Checkout zu wiederholen.

Der Harness verwendet ausschließlich normale Prozess-/Job-Priorität. Er ändert weder
SAC, Defender, WDAC, AppLocker noch Execution Policy und setzt keine Affinität oder
Echtzeit-/High-Priority-Klasse. Die CPU-Worker werden standardmäßig aus der CPU-Anzahl
abgeleitet (`max(1, ProcessorCount - 1)`) und durch den expliziten, änderbaren Cap
`-CpuWorkerCap 4` begrenzt. Mit `-CpuWorkers N` kann ein niedrigerer Wert gewählt
werden; Werte über den Cap werden abgelehnt. Die Worker enden nach dem konfigurierten
Zeitfenster. Ergebnislogs und `metrics.json` liegen unter
`%TEMP%\ClipPlayer\stress-*` und werden nicht versioniert.

Beispiel für einen Rechner mit eigener Lastgrenze:

```powershell
powershell -NoProfile -File .\scripts\run-audio-stress.ps1 -CpuWorkerCap 8 -CpuWorkers 3
```

Die Performance-Tests prüfen 1.000 deterministisch wechselnde Selection-Befehle durch
den Cache-Port sowie 1.000 Preload-Anfragen am echten `PcmCache`. Geprüft werden
Provider-/Cache-Hits, maximal vier Einträge, Cachebudget, Decoder-Wiederverwendung,
kein veralteter Track und p95 <= 50 ms für den hardwarefreien Selection-Pfad.

## Coverage ist ein separates Qualitäts-Gate

`verify-release.ps1` behauptet keine Coverage. Instrumentierung mit Coverlet verändert
die Test-Binaries, erhöht Laufzeit und Speicherbedarf deutlich und kann SAC/CodeIntegrity
erneut triggern; außerdem ist im Repository kein einheitlicher, fachlich freigegebener
Schwellenwert für alle drei Testprojekte definiert. Coverage wird daher nur in einer
dafür freigegebenen CI-/Nicht-SAC-Umgebung einmalig erzeugt, mit einem versionierten
Schwellenwert geprüft und als Release-Anhang archiviert. Fehlt dieser Anhang, bleibt
das Qualitäts-Gate offen; ein grüner lokaler Release-Gate-Lauf ersetzt ihn nicht.

`run-audio-stress.ps1` liefert Exit 0 bei bestandenem Gate, Exit 1 bei echtem Test-/Build-
Fehler, Exit 3 bei leerem Filter, Exit 124 bei Timeout und Exit 42 bei erkannter SAC-
Umgebungsblockade (`0x800711C7` oder CodeIntegrity 3033/3077 mit ClipPlayer-Bezug).
Exit 42 ist ausdrücklich kein Testergebnis. Ein solches Ergebnis darf keine Codeänderung
oder einen Revert auslösen.

## SBOM-Gate

`scripts/generate-sbom.ps1` verwendet keine neue NuGet-Abhängigkeit. Es lädt, falls kein
Werkzeugpfad angegeben ist, ausschließlich die exakt gepinnte Windows-x64-Datei
`microsoft/sbom-tool` **v4.1.5** aus dem versionierten GitHub-Release und verifiziert
vor der Ausführung den SHA-256-Hash:

`625767b371b7fdd58f40f618b8a86da0247a33c89e419039c86b4edba1dad4b5`

Die Release-Asset-URL und der Digest sind in `scripts/generate-sbom.ps1` fest verdrahtet;
`latest` wird nicht verwendet. Der offizielle Release-Digest ist zusätzlich in der
GitHub-API/Asset-Metadaten nachvollziehbar. Ein lokal bereitgestelltes Tool muss denselben
Hash haben. Download und Cache erfolgen nur unter `%TEMP%\ClipPlayer\`.

Beispiel nach dem Publish:

```powershell
dotnet publish .\src\ClipPlayer.App\ClipPlayer.App.csproj -c Release -r win-x64 `
  --self-contained true --no-restore -o .\artifacts\publish
powershell -NoProfile -File .\scripts\generate-sbom.ps1 `
  -BuildDrop .\artifacts\publish -Version 0.1.0
```

Das Script verlangt genau ein gültiges `manifest.spdx.json`, eine SPDX-Version,
`creationInfo` und mindestens ein Paket. Der SBOM-Ausgabepfad unter `artifacts/` ist
lokal/CI-Ausgabe und bleibt durch `.gitignore` unversioniert.

## Nicht vortäuschbare manuelle Release-Gates

Die folgenden Nachweise benötigen ein echtes Windows-11-x64-System mit funktionierendem
Audio-Endpunkt und können in einer headless Entwicklungsumgebung nicht ehrlich als
bestanden markiert werden:

1. Installiere exakt das signierte MSIX-Kandidatenartefakt auf Windows 11 (Build >=22621)
   bei unverändert aktivem SAC. Prüfe anschließend `signtool verify /pa /all /v` und
   `Get-AuthenticodeSignature` für alle PE-Dateien.
2. Starte File Activation für `.wav`, `.mp3` und `.flac`, teste Öffnen mit, Löschen in
   den Papierkorb, Deinstallation und Wiederherstellung der Standard-App-Auswahl.
3. Starte Wiedergabe über WASAPI Shared/Event Sync und Loopback-Aufzeichnung. Führe je
   100/150/200 ms Puffergröße mindestens 15 Minuten mit dokumentierter synthetischer
   Konkurrenzlast aus. Erfasse Discontinuities/Audioaussetzer, Wechsel-p95/p99,
   Working Set, GC und Handlezahl.
4. Vor und nach jedem Lauf: `Get-WinEvent` im
   `Microsoft-Windows-CodeIntegrity/Operational`-Log auf Events 3033/3077 filtern;
   bei Block oder `0x800711C7` ist der Lauf **Umgebung blockiert**, nicht bestanden.

Nur ein vollständig signiertes Artefakt auf einem SAC-enforcing System kann das
Distribution-Trust-Gate schließen. Ein hardwarefreier Test oder Windows-Sandbox-Lauf
beweist dieses Gate nicht. Rohdaten (ETW/Loopback/Signaturprotokolle) werden außerhalb
des Quelltrees als Release-Anhang archiviert.
