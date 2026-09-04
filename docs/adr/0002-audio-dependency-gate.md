# ADR 0002: Audio-Abhängigkeit bleibt ein Gate

Status: NAudio 2.2.1 für die aktuelle Audio-Implementierung angenommen; Release-Audit offen, 2026-09-04

Core verwendet keine Audioabhängigkeit. Der Windows-Adapter nutzt aktuell die stabile NAudio-2.2.1-Version aus nuget.org (MIT); Paketidentität, Lockfile und Paketinhalt sind zu prüfen. Vor dem Release ist eine stabile NAudio-3.x-Variante erneut zu bewerten. Gibt es nur eine Preview, wird sie nicht stillschweigend eingesetzt; ein dokumentierter Vergleich entscheidet nach dem Buffer-Spike.
