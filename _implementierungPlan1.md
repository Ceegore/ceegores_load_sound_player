# Implementierungsplan 1: ClipPlayer für Windows

Stand: 2026-09-04  
Zielausführer: Luna  
Status: freigegebene Planungsgrundlage, noch keine Implementierung  
Arbeitsname: `ClipPlayer` (bewusst nicht `SoundPlayer`, um Verwechslungen mit .NET-Typen zu vermeiden)

## 1. Zielbild

Eine kleine, schnelle Windows-11-x64-Anwendung spielt lokale Kurz-Audiodateien ab. Sie startet die ausgewählte Datei automatisch, wechselt mit Links/Rechts sofort zur vorherigen/nächsten Datei, schaltet mit Leertaste zwischen Pause und Wiedergabe um und verschiebt Dateien nach Bestätigung in den Papierkorb. Die aktuelle Datei und bis zu drei folgende Dateien werden so vorbereitet, dass beim Wechsel weder Dateizugriff noch Dekodierung im Audiopfad stattfinden.

Die Anwendung soll kommerziell vertreibbar, mit Standard-Windows-Mitteln bedienbar, als Standard-App auswählbar und über „Öffnen mit“ erreichbar sein. Der primäre Vertriebsweg ist ein vom Microsoft Store signiertes MSIX. Ein direkter Download ist nur als durchgängig CA-signierte Alternative zulässig.

„Ruckelfrei bei dauerhaft 100 % CPU“ ist kein physikalisch garantierbares Versprechen. Das Release-Kriterium ist daher messbar: null festgestellte Aussetzer im definierten Lasttest, schnelle Warmwechsel und ein kontrollierter Fallback bei Speicherdruck, Gerätewechsel oder nicht rechtzeitig gefülltem Puffer.

## 2. Verbindliche Rahmenbedingungen

- Zielsystem: Windows 11 x64, Mindestbuild 22621; ARM64 und Windows 10 sind nicht Teil von Version 1.
- Laufzeit/UI: .NET 10 LTS und WPF. .NET 10 ist bis 2028-11-14 unterstützt; SDK und Runtime werden auf aktuelle 10.0-Patches festgelegt.
- Ausgabe: WASAPI Shared Mode, eventgesteuert; kein exklusiver Zugriff auf das Audiogerät.
- Version-1-Formate: `.wav` (PCM und IEEE Float), `.mp3` und `.flac`. Beschädigte, verschlüsselte oder vom installierten Windows-Decoder nicht lesbare Dateien werden verständlich übersprungen.
- Kein Recording, keine Effekte, keine Bibliotheksverwaltung, keine Cloud, kein Equalizer, keine Playlistspeicherung, kein Auto-Updater und keine Shell-Erweiterungs-DLL in Version 1.
- Keine Datei mit geheimen Schlüsseln oder Zertifikaten im Repository.
- Keine versionierte Quell-, Test-, Skript- oder Dokumentdatei über 500 physische Zeilen. Ab 400 Zeilen frühzeitig aufteilen. Generierte Build-Ausgaben werden nicht versioniert; JSON-Artefakte wie SBOMs werden für die Ablage minifiziert.
- Ausschließlich lokale Git-Historie; kein Remote, Push oder Release-Upload ohne einen späteren ausdrücklichen Auftrag.

## 3. Festgelegte Produktsemantik

### 3.1 Dateien und Reihenfolge

- Öffnen über Dateidialog erlaubt Mehrfachauswahl. Diese explizite Auswahl behält ihre Reihenfolge.
- Start über Explorer/File Association mit genau einer Datei erzeugt eine temporäre Liste aus allen unterstützten Dateien desselben Ordners, natürlich nach Dateiname sortiert, und selektiert die angeklickte Datei.
- Kommandozeilenargumente werden als vollständige, normalisierte Pfade behandelt; unbekannte Optionen oder nicht unterstützte Endungen werden angezeigt, nicht stillschweigend interpretiert.
- Links/Zurück wählt den Vorgänger, Rechts/Weiter den Nachfolger. An den Grenzen gibt es keinen Wrap; der jeweilige Befehl ist deaktiviert.
- Jeder erfolgreiche Wechsel per Taste oder Schaltfläche startet die neue Datei bei Position 0 automatisch. Schnelle wiederholte Wechsel dürfen nur die zuletzt gewählte Datei hörbar machen.
- Am natürlichen Dateiende wird die nächste Datei automatisch gestartet; am Listenende stoppt die Wiedergabe.
- Öffnen einer neuen Auswahl startet deren erstes Element automatisch.

### 3.2 Pause, Löschen und Fehler

- Leertaste toggelt ausschließlich `Playing <-> Paused`; aus `Stopped` startet sie die aktuelle Datei von Position 0.
- Fensterweite Tastenbehandlung ignoriert modifizierte Tasten und modale Dialoge. Buttons behalten sichtbaren Fokus und Screenreader-Namen.
- „Löschen“ und optional die Entf-Taste zeigen den vollständigen Dateinamen in einer Bestätigung.
- Gelöscht wird ausschließlich in den Windows-Papierkorb, niemals permanent. Vorher werden Ladevorgang, Wiedergabe und Dateihandles dieser Datei beendet.
- Nach Löschen wird das Element am gleichen Index gewählt, sonst der Vorgänger. Existiert ein Ziel, startet es automatisch; bei leerer Liste wechselt die App in `Empty`.
- Datei verschwunden/gesperrt/defekt: Cacheeintrag verwerfen, kurze nicht-modale Fehlermeldung zeigen und beim automatischen Ablauf zum nächsten gültigen Element gehen. Keine Endlosschleife.

### 3.3 Rudimentäre GUI

- Ein Fenster mit Menü `Datei > Öffnen`, aktuellem Dateinamen, `Zurück`, `Play/Pause`, `Weiter`, `Löschen`, Zeit/Restzeit, einfacher Seek-Leiste und Lautstärkeregler.
- Native WPF-Controls, Systemschrift, Windows-Farben, 100–200-%-DPI, Tastaturfokus und High-Contrast-Unterstützung; keine eigene Designbibliothek.
- Status zeigt klar `Lädt`, `Bereit`, `Wiedergabe`, `Pausiert` oder den konkreten Fehler. Die UI darf während Dekodierung, Löschen oder Gerätewechsel nicht blockieren.

## 4. Architekturentscheidung

### 4.1 Projektstruktur

```text
ClipPlayer.sln
global.json
Directory.Build.props
Directory.Packages.props
NuGet.config
src/
  ClipPlayer.Core/                 # echte Klassenbibliothek; Zustände und Playlist
  ClipPlayer.Audio.Windows/        # echte Klassenbibliothek; Decoder, Cache, WASAPI
  ClipPlayer.App/                  # sehr dünnes WPF-WinExe
tests/
  ClipPlayer.Core.Tests/
  ClipPlayer.Audio.Windows.Tests/
  ClipPlayer.App.Tests/            # ViewModel/Commands ohne GUI-Start
packaging/
  ClipPlayer.Package/              # Windows Application Packaging Project/MSIX
scripts/
  run-tests-sac-safe.ps1
  verify-lines.ps1
  verify-release.ps1
  run-audio-stress.ps1
docs/
  adr/
  licenses/
  SAC.md
  THIRD_PARTY_NOTICES.md
  dependency-provenance.md
```

Abhängigkeiten zeigen nur nach innen: `App -> Core + Audio.Windows`, `Audio.Windows -> Core`. `Core` kennt weder WPF noch NAudio noch Dateisystemdialoge. Die Tests referenzieren primär echte Klassenbibliotheken und laden das GUI-Entry-Assembly nur dort, wo eine signierte/geeignete Umgebung vorhanden ist.

### 4.2 Zustands- und Nebenläufigkeitsmodell

- Ein `PlaybackCoordinator` besitzt die Zustände `Empty`, `Loading`, `Playing`, `Paused`, `Stopped`, `Faulted` und serialisiert alle Befehle über genau eine Command-Queue.
- Jede Auswahländerung erhöht eine monotone `SelectionGeneration`. Ergebnisse älterer Ladeaufträge werden verworfen; so kann ein langsamer Decoder keinen überholten Sound starten.
- Der WASAPI-Player wird einmal aufgebaut und erhält einen stabilen, umschaltbaren PCM-Provider. Ein Trackwechsel tauscht atomar nur Provider und Position; das Audiogerät wird nicht pro Datei neu initialisiert.
- Im Renderpfad gelten harte Regeln: keine Dateizugriffe, keine Decoder, kein Logging, keine UI-Callbacks, keine Sperren mit unbeschränkter Wartezeit und möglichst keine Allokationen.
- UI-Updates werden gedrosselt (zum Beispiel 10 Hz), auf den Dispatcher übertragen und dürfen die Audio-Queue nie blockieren.
- Ein Default-Device-Wechsel stoppt kontrolliert, initialisiert den Ausgabepfad neu, invalidiert formatabhängige PCM-Caches und startet die aktuelle Datei wieder. Fehler enden sichtbar in `Faulted`, nicht in einem Crash.

### 4.3 Audio-Engine und Puffer

- Bevorzugte Bibliothek: die neueste stabile NAudio-3.x-Version aus dem offiziellen NuGet-Feed, exakt zentral gepinnt und per Lockfile fixiert; nur die benötigten Pakete (`NAudio.Wasapi` plus transitive Core-Komponenten), kein `NAudio.SoundFile`/libsndfile.
- Luna prüft vor dem ersten Code-Commit: stabile 3.x-Version vorhanden, MIT-Lizenz im Paket, Repository/Package-Identität, SHA-512 aus dem Lockfile und keine unerwarteten nativen Binärdateien. Ist nur eine Preview verfügbar, wird nicht stillschweigend fortgefahren: ADR anlegen und NAudio 2.3.0 versus exakt gepinnte 3.x-RC in einem eintägigen Spike messen; die Variante mit bestandenem Lasttest und akzeptiertem Release-Risiko wählen.
- NAudio-3-Zielkonfiguration: `WasapiPlayer`, Shared Mode, Event Sync, Stream-Kategorie `Media`, MMCSS-Aufgabe `Pro Audio`, kein Exclusive Mode und zunächst kein erzwungener Low-Latency-Modus.
- Buffer-Spike misst 100, 150 und 200 ms. Gewählt wird der kleinste Wert mit null Aussetzern im definierten 100-%-CPU-Test; erwarteter Startwert ist 150 ms. Keine Prozessklasse `High` oder `Realtime`.
- Dateien werden außerhalb des Renderthreads vollständig dekodiert und einmalig in das Mixformat des Ausgabegeräts resampelt. Der Renderthread kopiert danach nur PCM.
- Cache-Fenster: aktuelle Datei plus bis zu drei Nachfolger. Nach einem Rückwärtssprung darf zusätzlich der direkte Vorgänger verbleiben, wenn das Budget reicht.
- Cachebudget: standardmäßig 256 MiB, LRU außerhalb des geschützten Fensters. Die aktuelle Datei wird nicht während der Wiedergabe verdrängt. Ein einzelner voll dekodierter Clip darf höchstens 128 MiB belegen.
- Größere Dateien nutzen einen 5-Sekunden-Ringpuffer und werden klar als „Streaming“ markiert. Die Kernoptimierung und die Release-SLO gelten für Kurzclips bis 128 MiB dekodierter Größe; Streaming wird separat auf schadensfreies Degradieren geprüft.
- Genau ein Decoder-Worker mit normaler Priorität verhindert zusätzliche CPU-Spitzen. Die aktuell angeforderte Datei hat Vorrang, danach werden `index+1..index+3` geladen. Überholte Aufträge werden kooperativ abgebrochen.
- Decoder schließen die Quelldatei direkt nach vollständigem Caching. Cacheidentität: normalisierter Pfad, Dateilänge, letzter Schreibzeitpunkt und Ziel-Mixformat.

## 5. SAC-/WDAC-Strategie (nicht verhandelbar)

Quelle und lokale Wahrheit: `C:\Projects\SACsolutions.md`, einschließlich Korrektur vom 2026-09-02.

- SAC, Defender, WDAC, AppLocker und Execution Policy auf dem Host werden niemals deaktiviert, abgeschwächt oder per Registry verändert.
- Ein Microsoft-signiertes `dotnet.exe` macht eine frische, nicht signierte GUI-DLL nicht vertrauenswürdig. Wrapper, Umbenennen, Kopieren, Clean/Rebuild oder Selbstsignieren sind keine Lösung.
- `ClipPlayer.Core` und `ClipPlayer.Audio.Windows` sind echte Libraries; `ClipPlayer.App` enthält nur Composition Root, Ressourcen und WPF-View. Dadurch kann der größte Testanteil ohne Laden des GUI-Subsystem-Assemblies laufen.
- Vor jeder Ergebnisinterpretation sucht der Testwrapper im Output nach `0x800711C7` und im CodeIntegrity-Operational-Log seit Testbeginn nach Events 3033/3077, gefiltert auf `ClipPlayer`-Assemblies.
- Wrapper-Ablauf: einmal bauen, 20 Sekunden setzen lassen, einen billigen Canary-Test starten, bei SAC-Block höchstens vier Versuche mit `30 s * Versuch`, danach Exitcode 42. Echte Testfehler bleiben Exitcode 1; „kein Test passte zum Filter“ erhält einen eigenen Exitcode.
- Native Testausgabe nicht durch `Tee-Object` pipen. `Start-Process` nutzt getrennte stdout/stderr-Dateien, cached sofort den Process-Handle, zeigt alle 30 Sekunden Heartbeat und beendet den Prozessbaum nach einem festen Timeout.
- Tagesarbeit: gezielte Gruppen von höchstens ungefähr 30 Tests, `--no-build` nach einmaligem Build. Vollsuite einmal am Gate, Coverage einmal am Ende. Exit 42 bedeutet „Umgebung, kein Testergebnis“ und löst niemals Codeänderung oder Revert aus.
- Wenn der Host frische GUI-Binaries blockiert, erfolgen GUI-Funktionstests auf einer separaten, nicht erzwingenden Entwicklungs-VM/Sandbox; die Host-Sicherheitslage bleibt unverändert. Das beweist Funktion, nicht Distribution Trust.
- Release-Vertrauen wird ausschließlich durch Signierung gelöst: primär Store-signiertes MSIX; alternativ RSA-Code-Signing-Zertifikat einer CA im Microsoft Trusted Root Program/Artifact Signing. Selbstsignierte Zertifikate sind nicht akzeptabel.
- Alle ausgelieferten PE-Dateien, Installer und Pakete werden signiert und zeitgestempelt, soweit der Vertriebsweg dies vorsieht. `signtool verify /pa /all /v` und `Get-AuthenticodeSignature` müssen erfolgreich sein.
- Finales Trust-Gate: Installation und Start des exakt zu veröffentlichenden Artefakts auf sauberem Windows-11-System mit SAC Enforcement; danach CodeIntegrity 3033/3077 prüfen. File Activation, Wiedergabe und Deinstallation gehören zum selben Gate.

## 6. Windows-Integration und Vertrieb

- WPF wird über ein Windows Application Packaging Project als x64-MSIX verpackt; .NET-Runtime wird selbstenthaltend mitgeführt, damit kein Erststart-Download nötig ist.
- Das Manifest registriert `.wav`, `.mp3` und `.flac` über `uap:FileTypeAssociation`, passende neutrale Icons und den normalen Open-Verb.
- Die App setzt sich nie selbst als Standard. Windows zeigt sie in „Öffnen mit“ und „Standard-Apps“; eine einmalige, zurückhaltende UI-Aktion darf `ms-settings:defaultapps` öffnen. Die Nutzerwahl wird respektiert.
- Der normale Open-Verb erfüllt bereits den Kern des Kontextmenüwunsches. Ein eigener Windows-11-Kontextmenübefehl über `windows.fileExplorerContextMenus`/`IExplorerCommand` wird wegen zusätzlicher COM-/Signier-/Explorer-Risiken auf Version 2 verschoben und nur bei belegtem Mehrwert umgesetzt.
- Primärkanal: Microsoft Store MSIX, weil Microsoft Hosting, Updates und Signierung übernimmt. Direkter MSIX-Download benötigt zusätzlich CA-vertrauenswürdige Signierung und einen separat geplanten Updatekanal.
- Releaseartefakte enthalten Version, SHA-256-Prüfsumme, SPDX-SBOM, Third-Party Notices und reproduzierbare Buildmetadaten; keine Debugsymbole oder Testdateien im Kundenpaket.

## 7. Lizenz- und Code-Reuse-Regeln

- Zulässig geplant: .NET/WPF (MIT), NAudio (MIT) und Microsoft `sbom-tool` (MIT). Windows Media Foundation/WASAPI werden als Betriebssystemkomponenten genutzt; es werden keine fremden Codec-Binaries weiterverteilt.
- NAudio-Dokumentation, `WasapiPlayer`-Muster und passende offizielle Demo-Patterns dürfen adaptiert werden. Jede tatsächlich kopierte oder substanziell abgeleitete Passage erhält im Dateikopf/Provenienzregister Repository-URL, Commit/Tag, Ursprungspfad, SPDX-ID und Änderungsvermerk.
- GitHub ist keine Lizenz. Code ohne klare, kompatible Lizenz wird nicht kopiert. Keine Snippets aus Blogs/Stack Overflow, kein GPL-/AGPL-Code, kein LGPL-natives Codec-Bundle und keine Audio-Testdatei unklarer Herkunft.
- Abhängigkeiten werden sparsam gehalten, zentral exakt gepinnt, mit `packages.lock.json` und `dotnet restore --locked-mode` reproduzierbar gemacht. `NuGet.config` erlaubt nur den offiziellen Feed und Package Source Mapping.
- `docs/dependency-provenance.md`, `docs/THIRD_PARTY_NOTICES.md` und `docs/licenses/` werden mit jedem Dependency-Commit aktualisiert. Der Release-Build erzeugt und validiert eine SPDX-SBOM mit einer exakt gepinnten Version von `microsoft/sbom-tool`.
- Vor Release: transitive Abhängigkeiten, Paketinhalt, Lizenztexte, bekannte Schwachstellen und native Dateien erneut prüfen. Diese Prüfung unterstützt, ersetzt aber keine Rechtsberatung für Codec-/Markenfragen.

## 8. Ausführungsphasen für Luna

### Phase 0 – Bootstrap und belegte Entscheidungen

1. `main` prüfen; `.gitignore`, `global.json`, zentrale Buildregeln, EditorConfig und Solution anlegen.
2. `docs/SAC.md` als projektspezifische Kurzfassung der lokalen Field-Guide-Regeln schreiben; Quelle und Datum vermerken.
3. ADRs für WPF/.NET 10, NAudio-Version, Cachegrenzen, Formate und Store-MSIX anlegen.
4. NAudio-Paketgate und eintägigen 100/150/200-ms-Spike durchführen; Ergebnis und Rohmesswerte committen.
5. Zeilenlimit-Prüfung und SAC-sicheren Testwrapper zuerst bauen, damit spätere Ergebnisse korrekt klassifiziert werden.

Abnahme: reproduzierbarer Restore; Build mit Warnungen als Fehler; Paket-/Lizenzentscheidung dokumentiert; Canary unterscheidet Pass, echten Fail, kein Match, Timeout und SAC-Exit 42.

### Phase 1 – Testbarer Core

1. Immutable `Track`-Daten, Pfadnormalisierung, Formatfilter und natürliche Sortierung implementieren.
2. Playlistoperationen, Grenzverhalten, End-of-track, Lösch-Folgewahl und Zustandsautomat implementieren.
3. `SelectionGeneration`, Command-Queue und Ports für Decoder, Cache, Output, Papierkorb, Uhr und UI-Dispatcher definieren.
4. Unit-Tests für leere/Ein-Datei-/Mehr-Datei-Listen, schnelles Links/Rechts, Pause/Resume, stale load completion und Fehlerketten schreiben.

Abnahme: Core hat keine WPF-/NAudio-Referenz; deterministische Tests; keine Race-bedingte Wiedergabe eines überholten Tracks.

### Phase 2 – Audioadapter und Cache

1. WAV- und Media-Foundation-Decoderadapter mit Formatvalidierung und Cancellation implementieren.
2. PCM-Cache mit 256-MiB-LRU, 128-MiB-Einzelgrenze, Invalidation und Preload-Prioritäten implementieren.
3. Stabilen Switchable Provider und WASAPI-Outputadapter bauen; Dispose/Device-loss/Default-device-change sauber behandeln.
4. Streaming-Fallback mit begrenztem 5-Sekunden-Ringpuffer ergänzen.
5. Aus eigenen, zur Testzeit erzeugten Sinus-/Impulsdaten Formatfixtures erstellen; keine fremden Audiodateien einchecken.

Abnahme: aktueller + drei nächste kleine Clips im Cache; keine offenen Quelldateihandles nach Preload; schneller Wechsel liest nicht von Disk und dekodiert nicht; Cache bleibt im Budget.

### Phase 3 – WPF-Oberfläche und Dateiverhalten

1. Dünnes ViewModel/Commands und die definierte Ein-Fenster-GUI implementieren.
2. Fensterweite Shortcuts, Buttonzustände, Fokus, High Contrast, DPI und Fehlerstatus umsetzen.
3. Multi-Open, Explorer-Aktivierung und Ordnerscan mit korrekter Ausgangsauswahl umsetzen.
4. Papierkorb-Löschen mit Bestätigung und konfliktfestem Handle-Lifecycle integrieren.

Abnahme: Links/Rechts autoplayt, Space toggelt ohne Positionsverlust, Löschen ist wiederherstellbar, 50 schnelle Richtungswechsel enden reproduzierbar beim letzten Ziel, UI bleibt responsiv.

### Phase 4 – Belastungs-, Qualitäts- und Fehlergates

1. Cache-/Coordinator-Tests mit kontrollierten Fake-Decodern und zufälligen Befehlsfolgen ausbauen.
2. Integrationstests für unterstützte WAV-Ausprägungen, MP3, FLAC, beschädigte Datei, gesperrte Datei, Unicode-/lange Pfade und Geräteverlust schreiben.
3. Lasttool erzeugt kontrollierte konkurrierende CPU-Last und zeichnet WASAPI-Loopback/ETW-Indikatoren auf; Testdauer 15 Minuten je gewählter Buffergröße.
4. Memory, Handles, GC, Wechselzeit und Audioaussetzer protokollieren; Lauf mit 1.000 Wechseln und begrenztem Cache durchführen.
5. Statische Verifikation bleibt auch bei Exit 42 aktiv: Build mit `-warnaserror`, Struktur-, Manifest-, Signatur- und Zeilenchecks.

Abnahme-SLOs für kleine, bereits gepufferte Clips:

- Warmwechsel Befehl bis Provider-Swap: p95 <= 50 ms, p99 <= 100 ms.
- UI-Reaktion auf Tasten: p95 <= 100 ms unter definierter CPU-Last.
- 15 Minuten Wiedergabe unter 100 % synthetischer Konkurrenzlast: 0 gemessene Aussetzer/Discontinuities.
- 1.000 Wechsel: kein Deadlock/Crash, kein falscher Track, Working-Set nach Beruhigung im dokumentierten Budget plus Runtime-Overhead, keine wachsenden Datei-/COM-Handles.

Wenn ein SLO scheitert: keine Beschönigung. Profil aufnehmen, Ursache klassifizieren und höchstens eine Variable pro erneutem Spike ändern (Buffer, Cacheformat, Decoderpriorität oder NAudio-Version).

### Phase 5 – MSIX, Integration und Trust

1. Packaging-Projekt, Assets und drei File-Type Associations erstellen; x64/Release/self-contained konfigurieren.
2. Installieren, `Öffnen mit`, Standard-App-Auswahl, direkte Aktivierung mit Leerzeichen/Unicode und saubere Deinstallation testen.
3. SPDX-SBOM, Notices und Prüfsummen erzeugen; Paketinhalt auf unerwartete native/unsignierte Dateien prüfen.
4. Store-Testsubmission erstellen; alternativ alle PE-Dateien plus MSIX per CA/Artifact Signing RSA-signieren und timestampen.
5. Exaktes Candidate-Artefakt auf SAC-Enforcement-Rechner installieren und vollständiges Trust-Gate ausführen.

Abnahme: kein CodeIntegrity-Block, keine SmartScreen/SAC-Umgehung, Dateitypen auswählbar, Offline-Erststart, Wiedergabe-SLOs auf Releaseartefakt, Rollback durch normale Deinstallation.

## 9. Testmatrix

| Bereich | Pflichtfälle |
|---|---|
| Playlist | leer, 1/2/n Dateien, Grenzen, natürliche Sortierung, verschwundene Dateien |
| Steuerung | Links, Rechts, Space, Button, Key Repeat, 50 schnelle Wechsel, Trackende |
| Pause | Position bleibt erhalten, Resume genau einmal, Wechsel aus Pause autoplayt |
| Löschen | Abbruch, Papierkorb, aktuelle/erste/letzte/einzige Datei, gesperrte Datei |
| Formate | WAV PCM 8/16/24/32, WAV Float32, MP3, FLAC, falsche Endung, korrupt |
| Pfade | Leerzeichen, Umlaute, Emoji, langer Pfad, UNC nur als dokumentierter Best-Effort-Fall |
| Audio | 44,1/48/96 kHz, Mono/Stereo, Gerätewechsel, kein Gerät, Cachehit/-miss, Streaming |
| Ressourcen | 256-MiB-Grenze, Eviction, Cancellation, 1.000 Wechsel, Dispose/COM-Handles |
| Windows | File Association, Open With, Default Apps, Install/Upgrade/Uninstall |
| Trust | Signaturkette, Timestamp, Hash, SAC Enforcement, Events 3033/3077 |

## 10. Lokale Commitstrategie

- Trunk-basiert auf `main`; kurze Branches nur für riskante Spikes (`spike/audio-buffer`, `spike/msix`). Kein Mergecommit für Ein-Personen-Arbeit nötig.
- Conventional Commits, Imperativ, eine fachliche Änderung je Commit. Jeder Nicht-Spike-Commit muss bauen und seine betroffenen gezielten Tests bestehen oder im Committext ehrlich `SAC environment block (exit 42)` nennen.
- Abhängigkeit plus Lizenz-/Lockfile-Änderung gehören in denselben Commit. Generierte `bin/`, `obj/`, Testresultate, Logs, Zertifikate und ungepackte Store-Secrets werden nie committed.
- Empfohlene Folge:
  1. `docs: record architecture, SAC and dependency decisions`
  2. `chore: scaffold solution and deterministic build`
  3. `test: add SAC-safe runner and repository gates`
  4. `feat(core): add playlist and playback state machine`
  5. `feat(audio): add audited decoders and bounded PCM cache`
  6. `feat(audio): add switchable WASAPI playback`
  7. `feat(ui): add accessible transport window and shortcuts`
  8. `feat(files): add activation and recycle-bin deletion`
  9. `test(perf): add CPU-load and rapid-switch gates`
  10. `build(msix): add file associations and packaging`
  11. `docs: add licenses SBOM and release runbook`
  12. `release: verify signed SAC-compatible candidate`
- Vor jedem Commit: `git diff --check`, Zeilenlimit, Formatierung, Build und kleinste relevante Testgruppe. Vor Tag `v1.0.0`: locked restore, Vollsuite, Lasttest, MSIX-Installtest, Signatur-/SAC-Gate und saubere Arbeitskopie.
- Niemals Änderungen wegen eines SAC-Blocks zurückrollen. Reverts nur für nachgewiesene Produktregressionen und als eigener `revert:`-Commit.

## 11. Definition of Done für Version 1

- [ ] Alle in Abschnitt 3 beschriebenen Bedien- und Fehlerfälle sind umgesetzt.
- [ ] `.wav`, `.mp3`, `.flac` bestehen die Testmatrix; andere Formate werden sicher abgelehnt.
- [ ] Aktueller und bis zu drei nächste Kurzclips werden innerhalb des Budgets vorbereitet.
- [ ] Warmwechsel, UI-Latenz, 15-Minuten-Lastlauf und Ressourcenlauf bestehen die SLOs.
- [ ] Kein Dateizugriff, Decoder, blockierendes Lock oder Logging im Audiopfad.
- [ ] Alle Tests sind grün oder ein Lauf ist explizit als SAC-Exit 42/Nicht-Ergebnis dokumentiert; niemals vermischt.
- [ ] Alle versionierten Dateien erfüllen das 500-Zeilen-Limit.
- [ ] Abhängigkeiten sind minimal, stabil, exakt gepinnt, gelockt, MIT-kompatibel dokumentiert und in der SPDX-SBOM enthalten.
- [ ] MSIX installiert/deinstalliert sauber und registriert die drei Formate, ohne die Nutzerwahl zu überschreiben.
- [ ] Exaktes signiertes Releaseartefakt startet auf SAC Enforcement ohne 3033/3077-Block und spielt per File Activation ab.
- [ ] Keine Sicherheitsrichtlinie wurde für Entwicklung, Test oder Release auf dem Host verändert.
- [ ] Lokale Historie besteht aus kleinen, nachvollziehbaren, einzeln prüfbaren Commits; Working Tree ist beim Tag sauber.

## 12. Hauptrisiken und Gegenmaßnahmen

| Risiko | Wkt. | Wirkung | Gegenmaßnahme/Stopregel |
|---|---:|---:|---|
| Frisches GUI-Assembly durch SAC blockiert | hoch | hoch | Core-Libraries, Exit 42, getrennte Dev-VM, signiertes Endgate; nie als Testfehler werten |
| NAudio 3 nur als Preview verfügbar | mittel | hoch | Paketgate + eintägiger Vergleich; keine unbemerkte Preview-Abhängigkeit |
| 100-%-CPU verursacht Dropouts | hoch | hoch | Predecode, PCM-Cache, Event WASAPI, MMCSS, Buffer-Spike; Release bei einem Dropout stoppen |
| Große Clips sprengen RAM | mittel | hoch | 256-MiB-LRU, 128-MiB-Einzelgrenze, begrenztes Streaming |
| Schnelles Wechseln startet falschen Clip | mittel | hoch | Generation Token + serialisierte Commands + Stresstest |
| Codec verhält sich je Windows-Edition anders | mittel | mittel | Windows-11-Matrix, Decoder-Featurecheck, verständlicher Fehler, keine mitgelieferten Codecs |
| Löschen verliert Daten | niedrig | hoch | Bestätigung, Papierkorb, Handlefreigabe, Tests; nie Permanent Delete |
| File Association wird aggressiv gesetzt | niedrig | hoch | Nur Manifestregistrierung; Windows-Nutzerwahl bleibt allein maßgeblich |
| Lizenz/Transitivabhängigkeit unklar | niedrig | hoch | Minimalpakete, Locked Restore, Provenienz, Notices, SBOM, Releaseaudit |
| Eigene Explorer-COM-Erweiterung destabilisiert Shell | mittel | hoch | Nicht in V1; normaler Open-Verb genügt |

## 13. Primärquellen für Luna

- Lokaler SAC-Field-Guide: `C:\Projects\SACsolutions.md`
- Smart App Control: https://learn.microsoft.com/windows/apps/develop/smart-app-control/overview
- SAC-Signaturtest: https://learn.microsoft.com/windows/apps/develop/smart-app-control/test-your-app-with-smart-app-control
- SmartScreen/Signierung: https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation
- Windows-Vertriebswege: https://learn.microsoft.com/windows/apps/package-and-deploy/choose-distribution-path
- WPF als MSIX: https://learn.microsoft.com/windows/apps/desktop/modernize/dotnet/package-app
- File Activation: https://learn.microsoft.com/windows/apps/develop/launch/handle-file-activation
- Default-App-Regeln: https://learn.microsoft.com/windows/apps/develop/windows-integration/default-apps-platform
- Explorer-Kontextmenüs (erst V2): https://learn.microsoft.com/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer
- MMCSS: https://learn.microsoft.com/windows/win32/procthread/multimedia-class-scheduler-service
- .NET-Support: https://dotnet.microsoft.com/platform/support/policy
- NAudio und MIT-Lizenz: https://github.com/naudio/NAudio
- NAudio `WasapiPlayer`: https://github.com/naudio/NAudio/blob/main/Docs/WasapiPlayer.md
- WPF und MIT-Lizenz: https://github.com/dotnet/wpf
- Microsoft SBOM Tool und MIT-Lizenz: https://github.com/microsoft/sbom-tool

## 14. Erste Anweisung an Luna

Zuerst Abschnitt 5 und `C:\Projects\SACsolutions.md` vollständig lesen. Danach ausschließlich Phase 0 ausführen und committen. Keine GUI starten, bevor der SAC-Canary-Wrapper existiert; keine Preview-Abhängigkeit, Signierausgabe oder Sicherheitsänderung improvisieren. Nach dem Audio-Buffer-Spike die Messwerte gegen die SLOs prüfen und erst dann mit Phase 1 fortfahren.
