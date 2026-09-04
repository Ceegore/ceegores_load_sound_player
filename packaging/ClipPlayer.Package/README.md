# ClipPlayer MSIX

Das Windows Application Packaging Project baut ausschließlich x64 und führt die
.NET-Runtime selbstenthaltend mit. `AppxPackageSigningEnabled` bleibt im Repository
deaktiviert: Store-Signierung oder ein CA-vertrauenswürdiges RSA-Zertifikat erfolgt
erst in der Release-Pipeline und wird nicht als Geheimnis eingecheckt.

Das Manifest registriert nur `.wav`, `.mp3` und `.flac`. Es setzt keine Standard-App
und enthält keine Explorer-COM-Erweiterung. Die SVG-Assets sind neutrale Platzhalter
für den technischen Paketaufbau; vor einer Store-Einreichung müssen sie entsprechend
der Store-Asset-Vorgaben als validierte PNG-Varianten eingebunden werden.
