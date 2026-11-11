# Changelog

Released versions of skein-1color (skein-mandala until 0.9.2). Versions
before 0.10.0 are in the git history (each release commit names what
changed).

## 0.20.0 (branch `one-step-0.20`, not released)

Re-pin onto skein-overlay 0.28.0 (David 2026-11-11: a submission is admitted in the step that hands it
to the chain app; no thread per transaction — the engine's `chainTx` subscription; skein-sdk 0.22.0,
skein-chain 0.12.0: an instance hears only rejected or mined).

- `build.zig.zon` the overlay's commit URL and hash (fef3dd4, until tagged); `bin/overlay.wasm` its
  committed engine; `bin/color-topic.wasm` and `bin/color-lookup.wasm` rebuilt (unchanged bytes);
  `etc/app.json` 0.20.0; `equiv/color-ledger.ts` the version check. No logic change: the topic and
  lookup contracts are unchanged, and the lookup's hooks run as before (called by the engine in the
  admitting step, now the intake step).
- Release notes: a FRESH HOME is required (skein-overlay 0.28.0's: threads a 0.27.x engine left
  resting on `chain/tx/<txid>` end in error on their next wake).

## 0.19.1 (2026-11-11)

Re-pin: skein-overlay v0.27.0 → v0.27.1 (skein-sdk v0.21.3 through it: a held transaction a BEEF
carries raw is not script-checked again; skein-chain 0.11.1 for `chain/1`).

- `build.zig.zon` the overlay's tag URL and hash; `bin/overlay.wasm` its committed
  engine; `bin/color-lookup.wasm` rebuilt; `etc/app.json` 0.19.1. No logic change.

## 0.19.0 (branch `ledger-0.19`, not released)

The lookup on skein-overlay v0.27.0 (a lookup raises its own events) and skein 0.8.0 (a step reads its
own events). Fixes the one-step parent+child defect reproduced in 0.18.1.

- Re-pin: skein-overlay v0.26.1 → v0.27.0 (skein-sdk v0.21.0 through it); `bin/overlay.wasm` the tag's.
- `color-lookup` raises its facts with `Service.emit` and reads them with `Service.events` /
  `Service.latest` under `Service.app` (the global event reader, the global app name and the local
  `events` import are gone); a read route's service gets the VM's kernel. Nothing is handed back.
- No logic change in the hooks: each reads the facts it needs by name. On skein 0.8.0 the parent's
  `topic/output` fact raised earlier in the step is read, so a parent and child admitted in one step
  debit the parent's output and count a burn. The three 0.18.1 reproductions are real tests now.
- Test harness: a kernel over one log, every fact visible to every later hook at once; an item's
  output facts raised after its hooks (skein-overlay `admitItem`). `begin`/`commit` are gone.
- `equiv/color-ledger.ts`: D, a transfer and a burning transfer, mined together and posted in ONE BEEF,
  admitted in one step on a real kernel → holders, supply, burned right; replay exact.
- `etc/app.json` and `build.zig.zon` 0.19.0; the lookup's metadata version 0.7.0. zig 48.

## 0.18.1 (branch `repin-0.26.1`, not released)

Re-pin: skein-overlay v0.26.0 → v0.26.1 (skein-sdk v0.21.0; skein-chain 0.11.0 for `chain/1`).

- `build.zig.zon` the tag's URL and hash; `bin/overlay.wasm` the tag's committed engine;
  `bin/color-lookup.wasm` rebuilt; `etc/app.json` 0.18.1 (the overlay's manifest rows are unchanged).
  No code change was forced.
- REPRODUCED, NOT FIXED: a parent and child admitted in one overlay step leave the parent's output
  undebited (the child's `spent` hook and burn check read the parent's output fact, not yet visible in
  that step). Three tests named `REPRODUCTION …` skip with the numbers. zig 45 pass, 3 skipped.

## 0.18.0 (2026-11-09)

The color lookup as a recognizer (agent-env plans/research/plan-pass-recognizers-2026-11-09.md, its
skein-1color part). Engine skein-overlay v0.26.0 (skein-sdk v0.19.0, skein-chain v0.10.0).

- Re-pin: skein-overlay v0.23.0 → v0.26.0; `bin/overlay.wasm` the tag's committed engine; `etc/app.json`
  without `lookupVersion`, the `reindex` role and route, and the libp2p receive row
  `/skein/overlay/beef/1.0.0`.
- `color-lookup` keeps no index: the maps `values`, `authorities`, `outputs`, `deploys`, `admitted`,
  `symbols`, `burns` are gone; `balances`, `byBalance`, `holders`, `counters` stay (summaries). It reads
  the overlay's facts `<app>/topic/output/<txid>.<vout>` (the kernel's `events` read) and emits
  `<app>/color/burn/<txid>/<tokenId>` {tokenId, amount, at} (was the bare `burn` event) and
  `<app>/color/symbol/<hex(lower sym)>/<txid>.<vout>` {tokenId}, each `{reverted: true}` from the
  `rejected` hook.
- BRC-207 `color-admission` / `color-spendability` (both forms) keep their query and answer shapes:
  admission = the latest output fact not `reverted` and the asset's output by its stored transaction;
  spendability adds the chain state's `spentBy` (a held spender not rejected, skein-chain 0.10.0).
- A proven B admitted against a held unmined A (overlay 0.26.0: B's hooks before A's `rejected`): the
  coin X is debited once (at A's spend) and never given back by A's rejection. A rejection credits back
  only the inputs in the hook's `givenBack` (overlay 0.26.0), and only while the coin's latest fact
  names that transaction.
- The burn is named per token, `<app>/color/burn/<txid>/<tokenId>`, so one transaction burning two
  tokens on one instance has both.
- `etc/app.json` 0.18.0; the lookup's metadata version 0.6.0. Known limits: README "Known limits
  (0.18.0)". zig 45.
- The queries `{tokenId}`, `{authoritiesTokenId}`, `{txid, outputIndex}` are gone (no consumer).
- `/tokens` (`ids`, `q`, `after`, `limit`, `skip`), `/<token>`, `/icon`, `/deploy`, `/holders`: same
  paths and JSON, read from the facts and the summaries.

## 0.17.2 (2026-11-07)

Reindex (agent-env plans/reindex-2026-11-07.md). Engine skein-overlay v0.23.0.

- Engine: skein-overlay v0.22.0 → v0.23.0 (root's `{fn: "reindex", args: {service}}` in the box
  `<app>/reindex`: a lookup's index derived again from its topics' admitted history in place, one
  transaction per step, the index's head switched in the last); `bin/overlay.wasm` the tag's committed
  engine; `bin/color-lookup.wasm` rebuilt (the lookup contract's fn `reindex` and the hooks' `reindex:
  true`; its hooks write only through their `Service` and read no head, so they re-run into a fresh index
  unchanged); `bin/color-topic.wasm` the same bytes.
- `etc/app.json`: version 0.17.2; `lookupVersion: 1` (the version of `color-lookup`'s record shape, raised
  when a release changes it: a host reindexes on a greater one); the route `{address: "reindex", handler:
  "overlay.reindex"}` and `reindex` under `roles.root`. zig 42.
- Re-running the hooks stamps what they stamp with the step's time (`now`: a burn row's `at`) with the
  reindex's step, not the admission's.

## 0.17.1 (2026-11-07)

Engine 0.22.0: a re-pin only (agent-env plans/data-model-cleanup-2026-11-07.md). The programs' code,
the manifest's rows, the pages and `www/` are unchanged.

- Engine: skein-overlay v0.21.1 → v0.22.0 (anchors kept only at heights with a mined transaction; the
  admittance record without `script` and `satoshis`, which nothing here read); `bin/overlay.wasm` the
  tag's committed engine; `bin/color-lookup.wasm` and `bin/color-topic.wasm` the same bytes.
- `etc/app.json`: version 0.17.1. zig 42.

## 0.17.0 (2026-11-07)

The counters (agent-env plans/read-optimizations-2026-11-07.md D5). Engine skein-overlay v0.21.1.

- `color-lookup`: maps `counters` (`tok → supply ‖ authorities ‖ burned ‖ burns`, 4 × u64 BE) and
  `burns` (`tok ‖ txid → amount ‖ at`), written by the hooks and unwound by a rejection: the
  circulating supply (moved as `values`: value outputs admitted minus value inputs consumed, the deploy
  included), the unspent authority outputs, the total burned and the transactions that burned (inputs
  carrying more of the token than the admitted outputs). A burn emits `{event: "burn", topic:
  "ls_color_<tokenId>", tokenId, row: {kind: "burn", txid, amount, at}}`; its rejection `row: {kind:
  "revert", …}`. The hooks read the step's time (`now`). No backfill.
- `<token>/holders` answers `supply`, `authorities`, `burned`, `burns` beside `count` and `rows`.
  Every other answer unchanged.
- Engine: skein-overlay v0.21.0 → v0.21.1 (skein-sdk 0.15.0 through it); `bin/overlay.wasm` the tag's
  committed engine (the same bytes as 0.21.0's, sha256 4616849f…); `bin/color-lookup.wasm` rebuilt
  (sha256 4f924298…); `bin/color-topic.wasm` the same bytes.
- `etc/app.json`: version 0.17.0. zig 42, web 42.

## 0.16.2 (2026-11-07)

Engine 0.21.0: a re-pin only. The programs' code, the manifest's rows, the pages and `www/` are
unchanged.

- Engine: skein-overlay v0.20.5 → v0.21.0 (tag URL and hash; skein-sdk 0.14.0 through it: a BEEF
  out carries one BUMP per block, selected from the chain's tree nodes in one descent, no
  `MerklePath.combine`). `bin/overlay.wasm` is the tag's committed engine (sha256 4616849f…);
  `bin/color-lookup.wasm` rebuilt on the new SDK (sha256 b2645466…: the BEEF it serves
  comes from the chain state's `beefOf`, the same path); `bin/color-topic.wasm` the same bytes.
- `etc/app.json`: version 0.16.2. zig 41.

## 0.16.1 (2026-11-06)

Engine 0.20.5: a re-pin only. The programs' code, the manifest's rows, the pages and `www/` are
unchanged.

- Engine: skein-overlay v0.20.4 → v0.20.5 (tag URL and hash; one held spender per coin: an unproven
  submission spending an output another held, unrejected transaction spends — held by the chain app
  or in flight in another submission of the engine — is refused at intake `DoubleSpend`; a
  submission whose admission applied nothing is answered `rejected`). `bin/overlay.wasm` is the tag's
  committed engine (sha256 12fe2e86…2d6f); `bin/color-topic.wasm` and `bin/color-lookup.wasm` the
  same bytes.
- `etc/app.json`: version 0.16.1. zig 41, web 42.

## 0.16.0 (2026-11-06)

The token list's search and cursor (shruggr/open-exchange#5; David, 2026-11-06: `q` is starts-with,
indexed; `unlisted` out).

- `GET /<app>/tokens?q=<text>`: the tokens whose `sym` starts with the text, ASCII
  case-insensitively, or whose `tokenId` starts with it (lower-case hex), the same rows in the same
  order as the plain list; `q=` no filter; at most 100 bytes, percent-decoded, `+` a space. Never a
  read of every token: the symbol side reads a new map of the index, `symbols` (lower-cased `sym` ‖
  token key → nothing), written by `admitted` beside `deploys` and removed by `rejected` with it; the
  id side reads `deploys` by the key range of the text's leading hex digits.
- `after=<txid>_<vout>`: the rows strictly after that token in the list's order (newest first by
  the chain), with or without `q`, `limit` as ever; its place read from the chain state by its key.
  An `after` the list does not hold is a 400; `after` beside `skip` a 400; `q` / `after` beside
  `ids` a 400. The answer is the plain array, as before.
- No backfill: a deploy admitted before 0.16.0 has no `symbols` row (found by its id, not its
  symbol); resubmitting its BEEF does not add one (the engine skips the hooks for an applied
  transaction).
- `bin/color-lookup.wasm` rebuilt; `bin/color-topic.wasm` and `bin/overlay.wasm` the same bytes.
  `etc/app.json`: version 0.16.0. zig 41.

## 0.15.3 (2026-11-05)

Engine 0.20.4: a re-pin only. No change in behaviour; the programs' code, the manifest's rows, the
pages and `www/` are unchanged.

- Engine: skein-overlay v0.20.3 → v0.20.4 (tag URL and hash; a lookup hook may hand back `events`
  the engine emits in the same step). `bin/overlay.wasm` is the tag's committed engine (sha256
  f4bd920f…62bf). `bin/color-lookup.wasm` rebuilt from this tree (the lookup contract it links
  answers `events` when a hook sets any; color-lookup sets none); `bin/color-topic.wasm` the same
  bytes.
- `etc/app.json`: version 0.15.3. zig 40.

## 0.15.2 (2026-11-05)

Engine 0.20.3: a re-pin only. No change in behaviour; the programs, the manifest's rows, the
pages and `www/` are unchanged.

- Engine: skein-overlay v0.20.2 → v0.20.3 (tag URL and hash; skein-sdk v0.12.0 → v0.13.0 through
  it: the tree's `floor`, `Map.floor`, `Map.range`). `bin/overlay.wasm` is the tag's committed
  engine (sha256 a21999b2…43b9, the same bytes as 0.20.2's). `bin/color-topic.wasm` and
  `bin/color-lookup.wasm` rebuilt from this tree: the same bytes.
- `etc/app.json`: version 0.15.2. zig 40.

## 0.15.1 (2026-11-05)

A fix (David Case, 2026-11-05). `color-lookup` filed every output the BSV-21 rules mark as a deploy
as an authority, a supply-holding deploy (BRC-162 deploy with an amount, BRC-161 `deploy+mint`)
included: an error. An output is filed by what it holds: a deploy that carries the supply is a
VALUE output (in `values`, answered by `{tokenId}`, moved by its spend and by rejections like any
value output, and so in the balance table with no special case); an authority-only deploy (amount
0, BRC-161 `deploy+auth`) stays an authority (`{authoritiesTokenId}`). The `deploys` registry over
`tm_color`, the `outputs` and `admitted` maps and BRC-207's `color-admission` /
`color-spendability` answers are unchanged. An index built before 0.15.1 keeps its deploys under
`authorities` until rebuilt. `bin/color-lookup.wasm` rebuilt; manifest 0.15.1. zig 40.

## 0.15.0 (2026-11-05)

Holders and the discovery row's supply and height (agent-env plans/history-api-build-2026-11-05.md
§2; decisions D4, D5 in plans/history-api-2026-11-05.md). `color-lookup` only.

- **The balance table** (D4): per token, `balances: tok ‖ pkh → amount`, `byBalance: tok ‖ (2^64 −
  1 − amount) ‖ pkh → null`, `holders: tok → count`, kept at admitted / spent / rejected for the
  unspent value outputs whose lock is P2PKH (pools and other contracts not counted); re-keyed on
  every change, a zero balance leaves both maps. No backfill (rebuild, not code).
- **`/<app>/<token>/holders?limit=&skip=`** on the prefix row (filter `token`): `{count, rows:
  [{address, balance}]}` largest first, `limit` 1 to 100, `max-age=5`; the address on
  `chain/state`'s network. Needs no deploy in the discovery index (a token instance's own topic
  feeds its table).
- **The discovery rows** (`/tokens`, `?ids=`, `/<token>`; D5) gain `amount` (the deploy output's
  supply, 0 for an authority-only deploy) and `height` (the deploy txid's height in the overlay
  state's `placed` under `tm_color`, null while unmined).
- `bin/color-lookup.wasm` rebuilt; manifest version 0.15.0. zig 39.

## 0.14.0 (2026-11-04)

The discovery routes of the Open Exchange public read API (exchange-api
decisions D8, D10, D17, D21; the build brief's P13–P16). `color-lookup`
only; the topic manager and the engine unchanged.

- **`/<app>/color/tokens` → `/<app>/tokens`** (D10: the `color/` segment
  goes; no alias). Paged `?limit=&skip=` as before; new `?ids=a,b` (D17):
  one row per id in the query's order, `{tokenId, listed: false}` for an id
  discovery does not list; an id not exactly `<txid>_<vout>` is a 400.
  `Cache-Control: public, max-age=5`.
- **`iconUrl` replaces the data-URL `icon`** (D8): `<tokenId>/icon`,
  relative to the list, for a 1Color deploy's embedded image (absent when
  its media type is not `type/subtype`); a BRC-161 JSON deploy's icon
  string only when it is an http(s) URL. `dataUrlOf` is gone.
- **A token's reads**: one prefix row `/` (filter `token`,
  `color-lookup.token`): `/<app>/<txid>_<vout>` the detail JSON
  `{tokenId, topic, sym, dec, txid, vout, iconUrl?}` (`max-age=5`),
  `/<app>/<txid>_<vout>/icon` the icon bytes in their media type,
  `/<app>/<txid>_<vout>/deploy` the deploy's Atomic BEEF
  (`application/octet-stream`, `chain/state`'s `beefOf`; D21); the two byte
  reads `public, max-age=31536000, immutable` when the deploy is proven in
  `chain/state`, else `public, max-age=5`. Anything else under the row 404.
  Exact routes match first (the kernel's dispatch), so `/tokens`, the
  engine's listing paths, `/submit` and `/lookup` are untouched.
- Pages: `listTokens` reads `/<app>/tokens` and resolves `iconUrl` against
  the list's URL; the tokens page shows the icon from it. `www/` rebuilt.
  `bin/color-lookup.wasm` rebuilt; manifest version 0.14.0.

## 0.13.4 (2026-11-04)

The pages submit and look up at the host root: `POST <origin>/submit` and
`POST <origin>/lookup`, which the skein host routes by `X-Topics` and by
`service` on any hostname it serves (skein 9e4f219), in place of
`<base>/<app>/submit` and `<base>/<app>/lookup`. On the Open Exchange's swap
site (`/amm/color/…`) the app paths were served by nobody (HTTP 405, the deploy
page's error after the wallet module had already submitted the deploy). The
token list (`<base>/<app>/color/tokens`) is the app's read and stays. `www/`
rebuilt; programs and manifest unchanged but the version, 0.13.4.

## 0.13.3 (2026-11-04)

On skein-overlay 0.20.2: `rebeat` re-declares the liveness of the configured
lookup services too — this manifest's `ls_color` (`config.overlay.lookups`),
which nobody registers. `bin/overlay.wasm` is its engine; the color wasm
files unchanged. Manifest version 0.13.3. Pages unchanged.

## 0.13.2 (2026-11-04)

On skein-overlay 0.20.1: `{fn: "rebeat"}` re-declares every topic's liveness
window (the market's window now) beside its beacon, and each registered
lookup service's liveness; an instance registered before skein-overlay
0.20.0 held a 40 s window under 120 s beats until then.

- skein-overlay v0.20.1 (was v0.20.0): `bin/overlay.wasm` is its engine;
  `bin/color-topic.wasm` and `bin/color-lookup.wasm` rebuilt (byte-identical). Manifest
  version 0.13.2. Pages unchanged.

## 0.13.1 (2026-10-30)

On skein-overlay 0.20.0, the settled overlay sync design (David, 2026-10-30:
"announce, then fetch"; no wants; every proof published; the tail read).

- skein-overlay v0.20.0 (was v0.19.0): `bin/overlay.wasm` is its engine;
  `bin/color-topic.wasm` and `bin/color-lookup.wasm` rebuilt (byte-identical:
  the topic and lookup contracts did not change). The `<topic>`
  mesh carries only the engine's `admit` verdicts (the host fetches the
  BEEF); a paused submission asks nobody (no `want` events).
- The receive row `/skein/overlay/beef/1.0.0` is the host's own entry, not
  served to peers (skein's host never handles it inbound); the manifest
  keeps the row and says so. Manifest version 0.13.1. Pages unchanged.

## 0.13.0 (2026-10-30)

Undecided is not rejected (David, 2026-10-30: "My only real concern is that
we don't mark items which are undecided as invalid, which would be a
persistent state."). On skein-overlay 0.19.0's `MissingParents`.

- `color-topic`: judging a token's topic, a transaction whose judgement does
  not admit every output of the token (a shortfall, a mint or authority
  output with no authority in) while an input's source transaction cannot be
  read (not in the BEEF, not held) fails `MissingParents` naming every source
  it cannot read (`Call.lacking`; it does not classify them). The engine
  pauses the submission, wants them, and judges it again as each arrives;
  nothing is recorded as rejected. A deploy needs no parents; a transaction
  judged completely, or whose sources are all read, is decided as before (a
  transfer spending a readable output that is no coin of the topic is still
  refused). `tm_color` (deploys) is unchanged. `token.complete`.
  color-topic version 0.5.0.
- skein-overlay v0.19.0 (was v0.16.1): `bin/overlay.wasm` is its engine;
  `bin/color-topic.wasm` and `bin/color-lookup.wasm` rebuilt (byte-identical). Manifest
  version 0.13.0. Pages unchanged (`www/` as 0.12.1).

## 0.12.1 (2026-10-29)

The deploy lookup takes BRC-207's query form, not ours (David, 2026-10-29,
correcting 0.12.0): over the discovery topic, `ls_color` answers BRC-207's
query with `topic: "tm_color"`:

```json
{"service": "ls_color", "query": {"type": "color-admission", "version": 1, "assetId": "<txid>_<vout>", "topic": "tm_color", "outpoints": ["<txid>.<vout>"]}}
```

`color-admission`: of the queried outpoints, the asset's deploy if
`tm_color` admitted it, spent or not (a registry); `color-spendability`:
the same while the chain state names no spender. Validated as the per-asset
form (five keys, version 1, `assetId` canonical, outpoints BRC-36 dot form),
the topic exactly `tm_color`.

- 0.12.0's additions are withdrawn: `{txid, outputIndex}` answers unspent
  value or authority outputs only, as until 0.11.x (no deploy registry
  there); `ls_color_<assetId>` takes BRC-207's queries only, as until
  0.11.x. `ls_color_deploys` stays gone.
- Pages: `lookupDeployBeef` asks `ls_color` the `color-admission` query
  above. `www/` rebuilt.
- color-lookup version 0.5.1; `bin/color-lookup.wasm` rebuilt; manifest
  version 0.12.1.

## 0.12.0 (2026-10-29)

One lookup name over the discovery topic (David, 2026-10-29: "There should
be no difference between what these things are looking up. The only
difference is which topic the instance has got access to."). A lookup is
`color-lookup` under a name; the name pairs it with the topic that feeds it;
an output is looked up by outpoint.

- `ls_color_deploys` is GONE, no alias (the name switch in
  `color_lookup.zig` and `name.zig`'s `deploys_service` removed). A deploy
  is looked up under `ls_color` by its outpoint, `{txid, outputIndex}`: the
  token id `<txid>_<vout>` IS that outpoint. On a `tm_color` feed (the map
  `deploys`) it answers the deploy output, spent or not (a registry, as
  `ls_color_deploys {tokenId}` did); a rejected deploy is gone.
  `{tokenId}` / `{authoritiesTokenId}` read the token topics' maps, as
  before (a `tm_color` feed puts nothing there).
- `ls_color_<assetId>` answers `ls_color`'s three queries too (a query
  carrying `type` is BRC-207's, validated strictly as before; any other is
  one of the three). Until 0.11.x it refused them. color-lookup version
  0.5.0.
- `etc/app.json`: `config.overlay.lookups` is `ls_color` alone; version
  0.12.0; description.
- Pages: `DEPLOYS_LOOKUP` is `ls_color`, asked `{txid, outputIndex}`; the
  deploy page still submits to `tm_color` at the pages' origin; the tokens
  page's text. `www/` rebuilt.
- `bin/color-lookup.wasm` rebuilt from this tree; `bin/overlay.wasm` and
  `bin/color-topic.wasm` unchanged (engine skein-overlay v0.16.1).

## 0.11.4 (2026-10-27)

The chain app's state read through the SDK's one opener (shruggr/skein-sdk#1):
the token list (`color_lookup.zig` `tokens`) calls skein-sdk v0.12.0
`chain.open` (the record's network, else main) instead of opening the state
itself. No change in behaviour; the manifest's rows, the pages and `www/`
are unchanged. (shruggr/skein#156: skein-chain 0.7.0's chain state names
the host chain's `headers` and `heights` roots; the layout readers see is
the same.)

- Engine: skein-overlay v0.16.0 → v0.16.1 (tag URL and hash; skein-sdk
  v0.11.1 → v0.12.0 through it). `bin/overlay.wasm` is the tag's committed
  engine. `bin/color-topic.wasm` and `bin/color-lookup.wasm` rebuilt from
  this tree.
- `etc/app.json`: version 0.11.4; the description names skein-overlay
  0.16.1.

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
