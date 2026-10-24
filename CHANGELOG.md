# Changelog

Released versions of skein-1color (skein-mandala until 0.9.2). Versions
before 0.10.0 are in the git history (each release commit names what
changed).

## 0.11.3 (2026-10-24)

Engine 0.16.0: validator terms from the record `<app>/terms`, not
`config.overlay.terms` (shruggr/skein-overlay#7). 1Color writes no terms and
never set `config.overlay.terms`, so its beats carry no `terms`, as before.
No other change in behaviour; the programs, the manifest's rows, the pages
and `www/` are unchanged.

- Engine: skein-overlay v0.15.1 → v0.16.0 (tag URL and hash; skein-sdk
  v0.11.1 through it, unchanged). `bin/overlay.wasm` is the tag's committed
  engine (sha256 bb2f16fe…0022, the same bytes as the tag tarball's).
  `bin/color-topic.wasm` and `bin/color-lookup.wasm` rebuilt from this
  tree.
- `etc/app.json`: version 0.11.3; the description names skein-overlay
  0.16.0.

## 0.11.2 (2026-10-23)

Engine 0.15.1: pending-parent pause (shruggr/skein-overlay#6). No other
change in behaviour; the programs, the manifest's rows, the pages and
`www/` are unchanged.

- Engine: skein-overlay v0.15.0 → v0.15.1 (tag URL and hash; skein-sdk
  v0.11.1 through it, unchanged). A submission whose parent is held but
  not yet admitted now pauses and resumes on the parent's admission.
  `bin/overlay.wasm` is the tag's committed engine (sha256 2b11a447…6f02,
  the same bytes as the tag tarball's). `bin/color-topic.wasm` and
  `bin/color-lookup.wasm` rebuilt from this tree: the same bytes.
- `etc/app.json`: version 0.11.2; the description names skein-overlay
  0.15.1.

## 0.11.1 (2026-10-23)

The receive row (shruggr/skein#154). No other change in behaviour; the
programs, the engine, the pages and `www/` are unchanged.

- `etc/app.json`: the engine's receive row `{"transport": "libp2p",
  "address": "/skein/overlay/beef/1.0.0", "filters": ["kernel.beef"],
  "handler": "overlay.submit"}`, as in skein-overlay's own manifest. The
  host hands each Atomic BEEF a catch-up fetches to this row, as from the
  serving peer; without it a puller refused every fetched BEEF ("no route
  for libp2p:/skein/overlay/beef/1.0.0"; found live, a local node catching
  up from the rack's `swap`). The description says so.

## 0.11.0 (2026-10-23)

The sync row (shruggr/skein-overlay#5, shruggr/skein#154; David,
2026-10-23: each app declares the engine's sync filter and the libp2p read
row in its own manifest, no handler). No other change in behaviour; the
pages and `www/` are unchanged.

- `etc/app.json`: `filters.sync = "overlay.sync"` and the route
  `{"transport": "libp2p", "address": "/skein/overlay/sync/1.0.0",
  "filters": ["sync"]}`: a peer's catch-up frames (locator, admitted
  ranges, a transaction's BEEF) are answered by the engine through the
  front door, not by the host. The description says so.
- Engine: skein-overlay v0.14.0 → v0.15.0 (tag URL and hash;
  skein-sdk v0.11.1 through it). `bin/overlay.wasm` is the tag's
  committed engine (sha256 45a2d8f1…dc267, the same bytes as the tag
  tarball's). `bin/color-topic.wasm` and `bin/color-lookup.wasm`
  rebuilt from this tree: the same bytes.
- A host serves the row once it takes shruggr/skein#154 (until then its
  kernel refuses a libp2p row with no handler).

## 0.10.1 (2026-10-21)

The pages only (no program, wasm or manifest change). The deploy goes
through the wallet's BRC-207 `color` module: `@1sat/actions` 0.1.0's
`deploy1Color` replaces `deployMandala`, so the wallet no longer asks for
the basket `mandala <txid> 0` (David, 2026-10-21).

- `web/package.json` (0.6.3): `@1sat/actions`, `@1sat/react`,
  `@1sat/connect`, `@1sat/templates` 0.1.0, published, on `@bsv/sdk` 4;
  `@bsv/sdk` → `npm:@bopen-io/sdk@4.0.1` (with an `overrides` entry, one
  copy in the tree), `@bsv/color-permission-module` →
  `npm:@bopen-io/color-permission-module@0.1.0` (already in the tree under
  `@1sat/actions`; the pages use its `assetBasket`). The packed-tarball
  build of 0.9.1/0.10.0 is gone.
- Deploy page: the module files the deploy in its basket
  `p color <txid>v0` (`p color <txid>v0 authority` for an authority
  deploy; BRC-207's asset tag `<txid>v<vout>`, not `<txid>_<vout>`) and
  submits it to `tm_color` and the token's topic at the wallet's overlay.
  The page still submits it to this overlay's `tm_color` by plain fetch,
  as before. "File it again" (`fileMandalaDeploy`) is gone: the module
  files in the same action. A result with an error is shown as an error,
  never as "Deployed" (0.10.0 showed the Deployed panel when the wallet
  had broadcast but filing was refused).
- Tokens page: the wallet fallback for a deploy the overlay does not hold
  reads `p color <txid>v<vout>`, then `p color <txid>v<vout> authority`
  (was `mandala <txid> <vout>`).

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
