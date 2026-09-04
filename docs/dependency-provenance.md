# Dependency Provenance

Stand: 2026-09-04. Im Produkt-Core gibt es derzeit keine NuGet-Abhängigkeit. Die Testprojekte verwenden ausschließlich zentral gepinnte Pakete aus dem offiziellen `nuget.org`-Feed; `packages.lock.json` wird durch locked restore erzeugt.

| Paket | Version | Zweck | Lizenz/Quelle |
|---|---:|---|---|
| NAudio | 2.2.1 | Windows-Audioadapter | MIT, nuget.org |
| Microsoft.NET.Test.Sdk | 17.13.0 | Testhost | MIT, nuget.org |
| xunit | 2.9.3 | Unit-Testframework | Apache-2.0, nuget.org |
| xunit.runner.visualstudio | 3.1.4 | Adapter | Apache-2.0, nuget.org |
| coverlet.collector | 6.0.4 | optionale Coverage | MIT, nuget.org |

NAudio 2.2.1 ist die aktuell implementierte stabile MIT-Abhängigkeit des Windows-Audioadapters; sie enthält kein mitgeliefertes natives Codec-Bundle. Ein späterer 3.x-Vergleich bleibt vor dem Release-Audit zu dokumentieren. Keine fremden Quelltextpassagen wurden kopiert; das SBOM-Tool wird erst nach seinem Dependency-Gate ergänzt.
