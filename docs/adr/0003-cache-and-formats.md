# ADR 0003: Formate und Cachegrenzen

Status: angenommen, 2026-09-04

Version 1 unterstützt `.wav` (PCM/IEEE Float), `.mp3` und `.flac`. Der Core filtert nur diese Endungen; Dekodierung bleibt ein Plattformport. Die spätere Audio-Schicht reserviert 256 MiB Cache, höchstens 128 MiB pro Kurzclip und schützt die aktuelle Datei sowie bis zu drei Nachfolger. Auswahlgenerationen verwerfen verspätete Decodergebnisse.
