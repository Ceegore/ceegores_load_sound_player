# ADR 0004: Distribution und Vertrauen

Status: angenommen, 2026-09-04

Solange keine Store- oder CA-vertrauenswürdige Signatur verfügbar ist, ist der
primäre GitHub-Releaseweg das reine PowerShell-/XAML-Quellpaket aus ADR-0005. Es
enthält keine eigene PE-Datei. Ein binärer Download wird erst als unterstützt
veröffentlicht, wenn ein Store-signiertes x64-MSIX oder eine CA-vertrauenswürdige
Signatur mit Zeitstempel vorliegt. Die App setzt sich niemals selbst als Standard.
