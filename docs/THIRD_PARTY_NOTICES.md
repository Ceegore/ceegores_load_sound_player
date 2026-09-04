# Third-party notices

ClipPlayer.Core enthält keine Drittanbieter-Laufzeitbibliothek. Der Windows-Audioadapter verwendet NAudio; die übrigen zentral fixierten Pakete werden nur für lokale/CI-Tests verwendet und sind nicht Bestandteil eines Kundenpakets:

- NAudio.Core 2.2.1 — MIT — https://github.com/naudio/NAudio (Wave-/PCM-Basis)
- NAudio.Wasapi 2.2.1 — MIT — https://github.com/naudio/NAudio (WASAPI/Media Foundation)

- Microsoft.NET.Test.Sdk 17.13.0 — MIT — https://github.com/microsoft/vstest
- xunit 2.9.3 — Apache-2.0 — https://github.com/xunit/xunit
- xunit.runner.visualstudio 3.1.4 — Apache-2.0 — https://github.com/xunit/visualstudio.xunit
- coverlet.collector 6.0.4 — MIT — https://github.com/coverlet-coverage/coverlet

Die Lizenztexte werden vor einem Release aus den exakt verwendeten Paketmetadaten geprüft. Es werden keine Codec-Binaries oder unklar lizenzierten Audiodateien ausgeliefert.
