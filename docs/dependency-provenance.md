# Dependency Provenance

Stand: 2026-09-04. Im Produkt-Core gibt es derzeit keine NuGet-Abhängigkeit. Die Testprojekte verwenden ausschließlich zentral gepinnte Pakete aus dem offiziellen `nuget.org`-Feed; `packages.lock.json` wird durch locked restore erzeugt.

| Paket | Version | Zweck | Lizenz/Quelle |
|---|---:|---|---|
| NAudio.Core | 2.2.1 | Wave-/PCM-Basis des Windows-Audioadapters | MIT, nuget.org |
| NAudio.Wasapi | 2.2.1 | WASAPI-Ausgabe und Media Foundation Reader | MIT, nuget.org |
| Microsoft.NET.Test.Sdk | 17.13.0 | Testhost | MIT, nuget.org |
| xunit | 2.9.3 | Unit-Testframework | Apache-2.0, nuget.org |
| xunit.runner.visualstudio | 3.1.4 | Adapter | Apache-2.0, nuget.org |
| coverlet.collector | 6.0.4 | optionale Coverage | MIT, nuget.org |

NAudio.Core und NAudio.Wasapi 2.2.1 sind die aktuell implementierten stabilen MIT-Abhängigkeiten des Windows-Audioadapters; das Meta-Paket `NAudio` wird vermieden und es wird kein Codec-Bundle mitgeliefert. Ein späterer 3.x-Vergleich bleibt vor dem Release-Audit zu dokumentieren. Keine fremden Quelltextpassagen wurden kopiert; das SBOM-Tool wird erst nach seinem Dependency-Gate ergänzt.
