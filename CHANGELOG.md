# Changelog

Released versions of skein-1color (skein-mandala until 0.9.2). Versions
before 0.10.0 are in the git history (each release commit names what
changed).

## 0.10.0 (2026-10-21)

The 1Color rename (David Case, 2026-10-15, shruggr/skein#120; BRC-162
retitled 1Color, bsv-blockchain/BRCs#317), and the engine on
skein-overlay 0.14.0. No aliases: the old names stop working everywhere.

**BRC-207's wire names** (`wallet/0207.md` "Overlay spendability contract",
"Deployment discovery"):

| until 0.9.2 | 0.10.0 |
|---|---|
| `tm_mandala` | `tm_color` |
| `tm_mandala_<assetId>` | `tm_color_<assetId>` |
| `ls_mandala_<assetId>` | `ls_color_<assetId>` |
| `mandala-spendability`, `mandala-admission` | `color-spendability`, `color-admission` |

**Our own names:**

| until 0.9.2 | 0.10.0 |
|---|---|
| repo `shruggr/skein-mandala` | `shruggr/skein-1color` |
| Zig package `skein_mandala`, module `mandala` | `skein_1color`, module `1color` (`const color = @import("1color")`) |
| programs `mandala-topic`, `mandala-lookup` (`bin/*.wasm`, `src/mandala_*.zig`) | `color-topic`, `color-lookup` (`src/color_*.zig`) |
| lookups `ls_mandala`, `ls_mandala_deploys` | `ls_color`, `ls_color_deploys` |
| the manifest's `name` `mandala` | `1color`; every head and record path follows (`<app>/ls_color`, the default app `1color`) |
| read `/mandala/tokens`, pages `/<app>/mandala/` | `/color/tokens`, `/<app>/color/` |
| docs/MANDALA.md | docs/1COLOR.md |

The lookup's two BRC-207 answers were checked against BRC-207 on BRCs
master: the query keys, the dot-form outpoints, the `<txid>_<vout>` asset
ids (`_0` included), exactly the queried outputs (each once, in the query's
order), admission including spent outputs, and the discovery topic's
admission (every valid BRC-161/162 deploy, no one-satoshi filter, legacy
non-zero-index deploys) already matched; only the names changed.

**The engine**: skein-overlay v0.12.1 → v0.14.0 (`build.zig.zon` by tag URL
and hash; `bin/overlay.wasm` its build, byte-identical to the tag's
committed engine). 0.13.0 adds optional ancillary txids to a topic's
verdict (`color-topic` names none); 0.14.0 adds anchors (the topic beat
carries `tipHeight`, `tipAnchor`, `tailDigest`) and the reads `/anchors`
and `/admitted`. The topic and lookup programs compiled against 0.14.0's
contracts unchanged.

The pages' title is 1Color; the SDK's own names (`deployMandala`, the
basket and label `mandala`, the protocol `[2, "mandala deploy"]`) are
unchanged until `@1sat/actions` moves to 1Color.
