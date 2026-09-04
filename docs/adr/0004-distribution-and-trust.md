# ADR 0004: Distribution und Vertrauen

Status: angenommen, 2026-09-04

Der primäre Releaseweg ist ein Microsoft-Store-signiertes x64-MSIX. Ein direkter Download ist nur mit CA-vertrauenswürdiger Signatur und Zeitstempel zulässig. Die App registriert Dateitypen über das Manifest, setzt sich aber niemals selbst als Standard. Ein eigener Explorer-COM-Kontextmenüeintrag bleibt wegen zusätzlicher Shell- und Signierrisiken außerhalb von V1.
