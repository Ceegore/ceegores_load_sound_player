# ADR 0001: Runtime und Projektgrenzen

Status: angenommen, 2026-09-04

ClipPlayer zielt auf .NET 10 (`global.json`, SDK 10.0.301) und Windows 11 x64. `ClipPlayer.Core` ist eine echte Klassenbibliothek und enthält Zustands-, Auswahl- und Portverträge ohne WPF, NAudio oder GUI-Subsystem. Audio und WPF hängen nur nach innen vom Core ab. So bleiben deterministische Kern-Tests klein und ein SAC-Block des GUI-Assemblies wird nicht als Core-Regression fehlinterpretiert.
