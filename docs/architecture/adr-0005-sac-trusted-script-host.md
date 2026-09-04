# ADR-0005: SAC-kompatibler Primaerstart ueber Windows PowerShell

## Status

Accepted

## Date

2026-09-04

## Context

### Problem Statement

Der selbstenthaltene .NET/WPF-Apphost wurde auf dem Zielrechner vor Prozessstart durch
Code Integrity 3033/3077 blockiert. ClipPlayer muss dort ohne Abschalten oder Umgehen
von SAC, WDAC, Defender oder Execution Policy nutzbar sein. Eine CA- oder
Store-Signatur steht nicht zur Verfuegung.

### Constraints

- Der Host bleibt unveraendert SAC-erzwungen.
- Keine selbstsignierten Binaerdateien, Policy-Aenderungen oder `ExecutionPolicy Bypass`.
- Keine dynamisch kompilierten benutzerdefinierten Assemblies.
- Jede Datei bleibt unter 500 Zeilen.
- Lokale Wiedergabe muss auch unter CPU-Last reaktionsfaehig bleiben.

### Requirements

- WAV, MP3 und FLAC ueber vorhandene Windows-Codecs.
- Autoplay, Pause/Resume, Vor/Zurueck, Papierkorb und Lautstaerke.
- Pfeil links/rechts und Leertaste funktionieren unabhaengig vom fokussierten Steuerelement.
- Aktueller, vorheriger und bis zu drei folgende Titel bleiben als MediaPlayer geoeffnet.
- Windows-Integration erfolgt benutzerbezogen und setzt nie ungefragt den Standard.

## Decision

Der primaere lokale Laufweg ist ein reines PowerShell-5.1-WPF-Skript. Es laeuft im
gueltig Microsoft-signierten Windows-PowerShell-Host und verwendet nur mit Windows
gelieferte WPF-, MediaPlayer- und Papierkorb-APIs. Der bestehende .NET-Code bleibt als
getestete Referenz und spaeterer signierter Distributionsweg bestehen.

### Architecture Diagram

```text
Explorer / Startmenue
        |
Microsoft-signiertes powershell.exe
        |
ClipPlayer.ps1 -- XAML + Zustandssteuerung
        |
Windows WPF MediaPlayer / Media Foundation / Audio Endpoint
```

### Key Interfaces

- `ClipPlayer.ps1 [-AudioPath <file>]`: Start und optionales Autoplay.
- `ClipPlayerLauncher.ps1`: hebt die Hostprioritaet vor dem Parsen des Hauptskripts an.
- `install-script-player.ps1`: Kopie nach LocalAppData, Open-With, Kontextmenue und Startmenue.
- `test-script-player-e2e.ps1`: UI-Automation, Last, Latenz und Code-Integrity-Gate.
  Dauerlaeufe steuern einen minimierten, nicht aktivierten Testmodus ueber temporaere
  Dateien und greifen niemals wiederholt auf den globalen Eingabefokus zu.

## Alternatives Considered

### Alternative 1: Unsignierter self-contained .NET/WPF-Apphost

- **Description**: Bestehende Anwendung direkt starten.
- **Pros**: Beste Wartbarkeit und vorhandene Tests.
- **Cons**: Auf dem Zielrechner deterministisch blockiert.
- **Rejection Reason**: Reale Code-Integrity-Events 3033 und 3077.

### Alternative 2: Selbstsignierung oder Richtlinienausnahme

- **Description**: Lokales Zertifikat oder Lockerung der Sicherheitsrichtlinie.
- **Pros**: Bestehende Binaerarchitektur bliebe erhalten.
- **Cons**: Nicht von SAC vertraut oder sicherheitskritische Host-Aenderung.
- **Rejection Reason**: Verboten und keine verlaessliche Produktloesung.

### Alternative 3: Microsoft Store oder CA-signiertes MSIX

- **Description**: Vertrauenswuerdig signierter Binaerrelease.
- **Pros**: Beste Endkundenverteilung und nativer Appstart.
- **Cons**: Erfordert externes Signatur-/Store-Verfahren.
- **Rejection Reason**: Aktuell nicht verfuegbar; bleibt spaetere Distributionsoption.

## Consequences

### Positive

- Auf dem gemessenen Zielrechner ohne SAC-Ausnahme startbar.
- Keine Drittanbieter-Laufzeit oder Codec-Bibliothek im Skriptmodus.
- Per-User-Installation ohne Administratorrechte und vollstaendig entfernbar.

### Negative

- Langsamerer Kaltstart als ein vertraut signierter nativer Apphost.
- Codec-Verfuegbarkeit folgt dem installierten Windows-Medienstapel.
- Richtlinien koennen Skriptausfuehrung in anderen Unternehmen abweichend beschraenken.

### Risks

- Ein aus dem Internet markiertes Skript kann unter `RemoteSigned` blockiert werden;
  Mitigation: kein `Unblock-File`, sondern signierte Distribution oder lokale Installation.
- PowerShell-Argumentquoting ist fehleranfaellig; Mitigation: leerraumfreier Installationspfad
  und automatisierter registrierter Starttest.

## Performance Implications

- **CPU**: GUI-Timer 200 ms; eigener Prozess wird auf AboveNormal gesetzt.
- **Memory**: maximal vorheriger, aktueller und drei folgende MediaPlayer.
- **Load Time**: XAML- und PowerShell-Kaltstart; Autoplay wird erst in `MediaOpened` ausgeloest.
- **Network**: keine Netzwerkzugriffe.

## Migration Plan

1. Skriptmodus und per-User-Installer bereitstellen.
2. Selftest, Blackbox-UI-Test und Dauerlasttest auf dem SAC-Host ausfuehren.
3. Skriptmodus als lokalen Primaerweg dokumentieren.
4. .NET/MSIX fuer einen zukuenftig signierten Release beibehalten.

## Validation Criteria

- Fensterstart ohne Code Integrity 3033/3077.
- Medienposition steigt nach Argumentstart ohne weitere Eingabe.
- Space friert Position ein und setzt sie fort.
- Pfeile wechseln mit Autoplay; Preload-Fenster umfasst bis zu vier Folgetitelkontexte.
- Papierkorbtest entfernt nur die generierte Testdatei.
- 15-Minuten-Lauf unter CPU-Last ohne Exit oder Wiedergabefehler.
- Ein Langlauf verwendet weder `AppActivate`, `SendKeys`, `SetFocus` noch UI-Klicks.

## Related Decisions

- `docs/adr/0001-runtime-and-boundaries.md`
- `docs/adr/0004-distribution-and-trust.md`
- `C:\Projects\SACsolutions.md`
