# ADR 0002: Audio-Abhängigkeit bleibt ein Gate

Status: NAudio 2.2.1 für die aktuelle Audio-Implementierung angenommen; Release-Audit offen, 2026-09-04

Core verwendet keine Audioabhängigkeit. Der Windows-Adapter nutzt ausschließlich `NAudio.Core` und `NAudio.Wasapi`, jeweils stabil 2.2.1 aus nuget.org (MIT); beide sind im Audio-Projekt-Unterbaum und in `packages.lock.json` exakt gepinnt. Das Meta-Paket `NAudio` wird nicht verwendet. Vor dem Release ist eine stabile NAudio-3.x-Variante erneut zu bewerten. Gibt es nur eine Preview, wird sie nicht stillschweigend eingesetzt; ein dokumentierter Vergleich entscheidet nach dem Buffer-Spike.

NAudio 2.2.1 bietet für diesen Adapter WASAPI Shared/Event-Sync und COM-Endpoint-
Notification-Callbacks (`IMMNotificationClient`), jedoch keine öffentliche API für
Stream-Kategorie oder MMCSS-Aufgaben. Deshalb registriert ClipPlayer Default-Device-
Callbacks und nutzt einen 150-ms-Shared-Puffer; Prozesspriorität wird nicht auf
High/Realtime gesetzt. Stream-Kategorie `Media` und `Pro Audio`-MMCSS bleiben ein
explizites NAudio-3.x-Release-Audit, nicht eine heimliche P/Invoke-Erweiterung.

Clips bis 128 MiB dekodiert und cached die V1 vollständig. Größere Dateien nutzen den
5-Sekunden-Ringpuffer mit Hintergrunddecoder; Seek ist für diesen Pfad in der UI
deaktiviert und wird als solche Einschränkung angezeigt.
