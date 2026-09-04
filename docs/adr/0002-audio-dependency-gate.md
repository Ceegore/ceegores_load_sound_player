# ADR 0002: Audio-Abhängigkeit bleibt ein Gate

Status: NAudio 2.2.1 für die aktuelle Audio-Implementierung angenommen; Release-Audit offen, 2026-09-04

Core verwendet keine Audioabhängigkeit. Der Windows-Adapter nutzt ausschließlich `NAudio.Core` und `NAudio.Wasapi`, jeweils stabil 2.2.1 aus nuget.org (MIT); beide sind im Audio-Projekt-Unterbaum und in `packages.lock.json` exakt gepinnt. Das Meta-Paket `NAudio` wird nicht verwendet. Vor dem Release ist eine stabile NAudio-3.x-Variante erneut zu bewerten. Gibt es nur eine Preview, wird sie nicht stillschweigend eingesetzt; ein dokumentierter Vergleich entscheidet nach dem Buffer-Spike.

Die V1 dekodiert und cached Clips bis 128 MiB PCM vollständig. Größere Dateien werden mit einer verständlichen Fehlermeldung abgelehnt; der vorhandene 5-Sekunden-Ringpuffer bleibt für die nachfolgende Streaming-Integration reserviert und wird nicht fälschlich als Streaming-Versprechen ausgeliefert.
