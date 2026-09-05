# SAC-/WDAC-Testregeln für ClipPlayer

Quelle: `C:\Projects\SACsolutions.md`, zuletzt gegengeprueft am 05.09.2026. Diese Kurzfassung ersetzt die Quelle nicht.

- Hostseitiges SAC, Defender, WDAC, AppLocker und Execution Policy werden niemals geändert.
- Ein unsigniertes GUI-Assembly kann trotz Microsoft-signiertem `dotnet.exe` blockiert werden. Kopieren, Umbenennen, Clean/Rebuild und Selbstsignieren sind keine Lösung.
- Core- und Audio-Projekte bleiben echte Klassenbibliotheken; GUI-Starttests gehören in eine geeignete Entwicklungsumgebung oder in das signierte Release-Gate.
- `scripts/run-tests-sac-safe.ps1` baut einmal, wartet standardmäßig 20 Sekunden, startet einen Canary und prüft sowohl `0x800711C7` als auch CodeIntegrity-Events 3033/3077 mit ClipPlayer-Bezug.
- Exit 0 bedeutet bestanden, Exit 1 echter Testfehler, Exit 3 kein passender Filter, Exit 124 Timeout und Exit 42 SAC-Umgebungsblock. Exit 42 ist kein Testergebnis und darf keine Codeänderung auslösen.
- Testausgabe wird über getrennte Dateien gelesen, nicht durch `Tee-Object` gepiped; der Prozess-Handle wird sofort gecached und der Prozessbaum hat ein hartes Timeout.

Der Wrapper verändert keine Sicherheitsrichtlinie. Bei einem Block sind statische Build-, Struktur- und Zeilenprüfungen weiterhin zulässig; die Blockmeldung wird wahrheitsgemäß dokumentiert.

## GitHub-Release und Mark-of-the-Web

Das unterstützte GitHub-Artefakt ist source-only und enthält absichtlich keine
EXE, DLL, MSI oder MSIX. Der gemessene SAC-Start gilt für lokal erzeugte Skriptdateien
unter `RemoteSigned`. Browser-Downloads können Mark-of-the-Web tragen; deren
Ablehnung ist eine Execution-Policy-/Herkunftsentscheidung und kein SAC-Fehler.

Nach erfolgreicher SHA-256-Prüfung des offiziellen Release-ZIP ist
`Get-ChildItem -LiteralPath $release -Recurse -File |
Unblock-File` ein begrenzter, gemessener Workaround für genau diese
Internet-Markierung. Der Befehl darf nie auf einem breiten Ordner ausgeführt
werden und ändert weder Execution Policy noch SAC/Defender. Er löst keine echte
WDAC-/AppLocker-Skriptregel. `ExecutionPolicy Bypass`, Selbstsignieren und das
Abschalten von Schutzfunktionen bleiben ausgeschlossen. Für eine solche
Richtliniensperre wird ein organisatorisch signierter bzw. freigegebener
Verteilweg benötigt.

## Gemessener lokaler Skriptmodus

Am 04.09.2026 startete der source-only WPF-Player erfolgreich im gültig
Microsoft-signierten Windows-PowerShell-5.1-Host. Dabei wurden keine eigenen PE-Dateien
geladen, keine Richtlinie verändert und keine Code-Integrity-Ereignisse 3033/3077
erzeugt. Dieser Pfad ist die lokale Primärarchitektur, solange keine Store-/CA-Signatur
für den Binärrelease verfügbar ist.

Dauerprüfungen laufen ausschließlich mit `-BackgroundTest`: minimiert,
`ShowActivated=false`, ohne Taskleisteneintrag und über einen temporären Befehlskanal.
Auf gemeinsam genutzten Rechnern sind wiederholtes `AppActivate`, `SendKeys`,
`SetFocus` und UI-Automation-Klickschleifen untersagt.

Ein am 04.09.2026 zunächst erfolgreicher Lauf der unsignierten `ClipPlayer.App.dll`
wurde nach einem späteren sauberen Build vollständig mit `0x800711C7` blockiert.
Ein einzelner früher DLL-Pass ist daher kein stabiler Vertrauensnachweis; nach einer
Settle-Phase erneut prüfen und spätere Blocks als Umgebungs-Nicht-Ergebnis behandeln.
