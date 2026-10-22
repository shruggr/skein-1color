# skein-1color

The 1Color token (BRC-162; BRC-207) overlay components for a
[skein](https://github.com/shruggr/skein): a topic manager and a lookup
service, as programs an overlay app carries in its tree, and the token
library they are built on, as a Zig package, and two pages an app that
carries the components serves. Version **0.10.0**.

0.10.0 is the 1Color rename, on BRC-207's wire names
(David Case, 2026-10-15, shruggr/skein#120): the repo `skein-1color`, the
app `1color`, the Zig module `1color`, the programs `color-topic` and
`color-lookup`, the topics `tm_color` and `tm_color_<assetId>`, the lookups
`ls_color`, `ls_color_deploys` and `ls_color_<assetId>`, the queries
`color-spendability` and `color-admission`, the read `/color/tokens` and
the pages under `/<app>/color/`. No aliases: the old names stop working
everywhere (CHANGELOG.md).

## What it is

- **The topic manager** (`bin/color-topic.wasm`): one topic per token,
  `tm_color_<assetId>` (BRC-207): `tm_color_<txid>_0` (a token deployed
  at output 0, under BRC-162 or BRC-161, id `<txid>_0`) or
  `tm_color_<txid>_<vout>` (a BRC-161 token deployed at a non-zero output). It admits every output of
  the token that the BSV-21 rules allow and retains the token coins a
  transaction spends: the protocol only, no governance.
- **The lookup service** (`bin/color-lookup.wasm`, `ls_color`): a
  token's unspent value outputs, its unspent authority outputs, one output
  by outpoint. One index for every name it serves, the head
  `<app>/ls_color` (skein-overlay 0.11.0: the hooks reach the program
  once, whatever its names).
- **A token's lookup** `ls_color_<assetId>` (0.9.0, BRC-207; David Case,
  2026-10-08): the same program, registered beside the token's topic,
  answering BRC-207's `color-spendability` and `color-admission`
  (docs/1COLOR.md "BRC-207").
- **The discovery topic** `tm_color` (BRC-207 "Deployment discovery"; a
  mode of `color-topic`): every token's deploy output, every valid BRC-161
  or BRC-162 deploy whatever its carrier's satoshis, legacy BRC-161 deploys
  at a non-zero output included, so the metadata each token
  was deployed with can be found. Its lookup `ls_color_deploys` (a mode of
  `color-lookup`) answers `{tokenId}` with the deploy output.
- **The token list** (0.7.0; a read, not a BRC-24 query): `color-lookup`'s
  fn `tokens` at `/<app>/color/tokens`, `{limit?, skip?}` →
  `[{tokenId, topic, sym, dec, icon?, txid, vout}]`, every deploy
  `tm_color` admitted, newest first (docs/1COLOR.md "The token list");
  `icon` a 1Color deploy's embedded image as a data URL (0.9.0), a BRC-161
  JSON deploy's icon string as written.
- **The embedded icon** (0.9.0; BRC-162 draft bsv-blockchain/BRCs#308): a
  deploy's `icon` is the DAG-CBOR array `[mediaType, bytes]`; the pointer
  forms (an outpoint, an output index) are gone, and any other shape is
  absent.
- **Token ids** (0.8.1; David, 2026-10-07, shruggr/skein#120). A token id
  is written `<txid>_<vout>` for every token, 1Color and legacy BSV-21
  alike, `_0` included; the bare 32-byte txid is the wire form only (BRC-162
  "Token identification": "For display and APIs, the string form is
  `<txid>_<vout>`"). 0.3.1 to 0.8.0 wrote a 1Color token as the bare
  `<txid>`. The lookups take any of `<txid>`, `<txid>_<vout>` and
  `<txid>.<vout>`.
- **Topic and lookup names** (0.9.0, BRC-207; David Case, 2026-10-08). A
  token's topic is `tm_color_<assetId>` and its lookup
  `ls_color_<assetId>`, the asset id its token id `<txid>_<vout>`, `_0`
  included. They replace 0.8.2's `tm_<txid>_<vout>` with no alias. 0.10.0
  moved every name to BRC-207's `color` (above), the discovery topic
  `tm_color` and lookup `ls_color_deploys` too. Names derived from a topic
  follow it (`tm_color_<txid>_0-live`).
- **Tokens registered live.** The manifest declares no topics. A token is
  served once root registers it with the overlay engine, two calls: its
  topic, `register {topic, program: "color-topic"}` (skein-overlay 0.6.0),
  then its lookup, `registerLookup {service, program: "color-lookup",
  topics}` (skein-overlay 0.11.0); deregistering reverses both. The overlay
  tracks registered tokens only.
- **The library** (Zig module `1color`): the BRC-162 and BRC-161 output
  parsers and the BSV-21 rules, which the topic manager, the lookup service
  and an application's own programs share.
- **The pages** (`www/`, built from `web/`): deploy a token; root's
  registered token topics. Below, "Pages".

docs/1COLOR.md has each in full and what is not built.

Exported Zig modules:

| module | file | what |
|---|---|---|
| `1color` | `src/lib.zig` | `brc162` (the binary output parser), `brc161` (the JSON inscription parser), `bsv21` (the rules for one token over a parsed transaction, both forms), `name` (topic names and token id strings), `token` (the topic's verdict). `std` only |

## Use it

**The engine.** The components need skein-overlay 0.7.2 or later, whose
`register` / `deregister` serve topics registered at runtime (and 0.11.0,
whose `registerLookup` / `deregisterLookup` serve lookups registered at
runtime, the hooks reaching a lookup program once)
(docs/1COLOR.md "Registering a topic"), taken in root's box
`<app>/register` (0.7.7; `<app>/overlay` from 0.6.2), and whose submissions are messages into the
submission box `<app>/submit`, by message and from `POST /submit` (0.7.6;
before, the app's own box `<app>`). `bin/overlay.wasm` here is the v0.14.0
build (0.14.0: anchors, the topic's beat carries `tipHeight`, `tipAnchor`
and `tailDigest`, and the reads `/anchors` and `/admitted`; 0.13.0:
ancillary txids on a topic's verdict, optional, which `color-topic` names
none of, and the read `/holds`), and before it the v0.12.1
build (0.12.1: liveness on a registered lookup's `<service>-live` too, and
`config.overlay.terms` copied into the topic beat body), and before it the v0.12.0
build (on skein-sdk v0.11.0, skein log format 10: the BEEF envelope beside
the pointer record, shruggr/skein#146; `<topic>` one mesh for submit and
admit messages, `<topic>-proof` and `<topic>-live` separate; a skein is
always a market and a validator; beats with the topic's view digest), and before it the v0.11.0
build (skein's routes, filters and roles, shruggr/skein#143: its reads are read
routes whose filters answer, its `register` box root's), whose `POST /submit` is BRC-22 and synchronous again (it answers the
STEAK; 0.9.1, shruggr/skein#112), whose `register` takes `seed` (the tokens page's register seeds a
token's topic with its deploy, 0.7.8), whose listings and documentation
are reads (0.8.0, shruggr/skein#135), and whose `config.overlay.market` /
`config.overlay.validator` give the market's window and the validator's
beat (0.9.0, shruggr/skein#120; since 0.12.0 always on, the owner's switch
of 0.9.2 gone).

**On its own** (`etc/app.json`, the reference manifest; the chain app first,
which the overlay requires):

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-1color --instance <handle>
```

**Register a token**: root's messages in the app's box (skein
docs/APPS.md §4), `skein plan` / `skein send` or any BRC-100 wallet, to the
overlay engine (skein-overlay docs/OVERLAY.md "Register a topic",
"Register a lookup service"), its topic then its lookup:

```
box:  register   (installed: <app>/register)
body: {"fn": "register", "args": {"topic": "tm_color_<assetId>", "program": "color-topic"}}
body: {"fn": "registerLookup", "args": {"service": "ls_color_<assetId>", "program": "color-lookup", "topics": ["tm_color_<assetId>"]}}
body: {"fn": "deregisterLookup", "args": {"service": "ls_color_<assetId>"}}
body: {"fn": "deregister", "args": {"topic": "tm_color_<assetId>"}}
```

The asset id is the token id `<txid>_<vout>` (`<txid>_0` at output 0); the
discovery topic `tm_color` is registered by `register` alone. The names
follow from how the token was deployed, and the deploy page shows them.
`registerLookup` answers `{service, active}`; the registered lookups are the
engine's head `<app>/lookups`. `program` is always
`color-topic`. Both calls are idempotent; the step's result record is
`{kind: "overlay-result", op, topic, active, changed}`, and the engine
answers `{fn, request, replyTo, result: {topic, active}}` to a sender a
message can reach. The registered set is the engine's head `<app>/topics`
(`{kind: "overlay-topics", topics: [{topic, program}]}`). A registered topic
is served from the next step, and the host subscribes `tm_color_<assetId>`
(submit and admit messages, one mesh) and `tm_color_<assetId>-proof` from the engine's `subscribe`
events (skein-overlay 0.12.0; `-admit` before), and keeps liveness and a
beacon on `tm_color_<assetId>-live`; a registered lookup
`ls_color_<assetId>` beats on `ls_color_<assetId>-live` (an empty body:
color-lookup gives none) and keeps liveness there (skein-overlay 0.12.1).

**Submit** to the app's base URL (`https://<handle>.<host>/1color`; local:
`http://127.0.0.1:8100/@<handle>/1color`):

```
POST <base>/submit
X-Topics: ["tm_color_<txid>_0"]
Content-Type: application/octet-stream
<BEEF>
```

**Look up**:

```
POST <base>/lookup
{"service": "ls_color", "query": {"tokenId": "<txid>_0", "limit": 10}}
{"service": "ls_color", "query": {"authoritiesTokenId": "<txid>"}}
{"service": "ls_color", "query": {"txid": "<txid>", "outputIndex": 1}}
{"service": "ls_color_deploys", "query": {"tokenId": "<txid>_0"}}
{"service": "ls_color_<txid>_0", "query": {"type": "color-spendability", "version": 1, "assetId": "<txid>_0", "topic": "tm_color_<txid>_0", "outpoints": ["<txid>.1"]}}
{"service": "ls_color_<txid>_0", "query": {"type": "color-admission", "version": 1, "assetId": "<txid>_0", "topic": "tm_color_<txid>_0", "outpoints": ["<txid>.1"]}}
```

At the skein's origin (the @bsv/sdk clients' form, `<origin>/submit` and
`<origin>/lookup`), once root adds the two root routes (skein-overlay
README "Root routes"; an app installed as `1color`):

```
skein routes add --transport http --filters kernel.beef --fn submit /submit 1color.overlay <origin>
skein routes add --transport http --filters 1color.lookup /lookup <origin>
```

**List the tokens** (a read: any method, signed or not):

```
GET <base>/color/tokens?limit=20&skip=0
→ [{"tokenId": "<txid>_0", "topic": "tm_color_<txid>_0", "sym": "GOLD", "dec": 8, "icon": "data:image/png;base64,…", "txid": "<txid>", "vout": 0}, …]
```

Each answer is an output-list: `{type: "output-list", outputs: [{beef,
outputIndex}]}`, each output with its transaction's BEEF.

### Carry the components in another app

An app that serves 1Color tokens with its own programs beside them (an
AMM) carries these in its tree and manifest:

1. **The programs.** `bin/overlay.wasm` (the engine, skein-overlay
   0.14.0), `bin/color-topic.wasm`, `bin/color-lookup.wasm`, copied from
   this repo, under the roles `overlay`, `color-topic`, `color-lookup`.
2. **`config.overlay`**, with no topics:

   ```json
   "overlay": {
     "lookups": {
       "ls_color": {"program": "color-lookup"},
       "ls_color_deploys": {"program": "color-lookup"},
       "ls_<yours>": {"program": "<your lookup>"}
     }
   }
   ```

   The 1Color topics are registered at runtime (item 4), so none is
   declared. A lookup with no `topics` list listens to every topic the
   overlay serves, registered or declared. A manifest MAY pre-declare
   topics in `config.overlay.topics` (an overlay with fixed topics, e.g.
   OpNS's one global topic); 1Color's are dynamic, so it declares none.
   Gossip is on for every topic unless `gossip` turns one off.

   Every skein is a market and a validator, always (skein-overlay 0.12.0;
   David, 2026-10-09: "every skein is marketplace AND validator from
   install, always"): registering a token's topic starts both for it,
   deregistering stops them; there is no switch (0.9.2's `{fn: "market" |
   "validator"}` is gone).

   - **Market**: each registered topic has liveness on `<topic>-live` with
     a window — the runtime keeps the beats newer than it, served at `GET
     /<app>/.live/<topic>-live`.
   - **Validator**: each registered topic has a beacon on `<topic>-live`,
     a signed beat every `every` ms, its body the topic's beat `{view:
     {count, digest}, tipHeight?, tipAnchor?, tailDigest}` (the last three
     skein-overlay 0.14.0's anchors; re-declared when it changes); a validator
     program the app carries signs for any registered topic.

   The ms are `config.overlay.market: {window}` and
   `config.overlay.validator: {every}` (e.g. `skein-host install …
   --config` with `{"overlay": {"market": {"window": 40000}, "validator":
   {"every": 30000}}}`), else 40 000 and 30 000; each an integer from
   1 000 ms to a day.
3. **The routes, filters and roles** (shruggr/skein#143, skein docs/APPS.md
   §2: a route names its transport, address, filters and handler, no
   sender; who may run a function is `roles`), as in `etc/app.json`:
   - `{"address": "register", "handler": "overlay.register"}` with `roles:
     {"root": ["register", "registerLookup", "deregisterLookup"]}`: root's
     message reaches the engine's `register` / `deregister` and
     `registerLookup` / `deregisterLookup` (the function
     the engine runs is the body's `fn`); a message from any other key is
     recorded and runs nothing. The address is relative: the install
     resolves it to `<app>/register` (skein#128).
   - `{"address": "submit", "filters": ["kernel.beef"], "handler":
     "overlay.submit"}`: the submission box `<app>/submit`, anyone whose
     BEEF validates, where a submission is a message `{fn: "submit", args:
     {beef, topics}}` (skein-overlay 0.7.6). No route of the app's own on
     `<app>`: that box is the engine's, derived by the install.
   - **The read routes** (an http route with no handler: its filters
     answer, anyone, signed or not, nothing logged): the four listing and
     documentation paths of the engine (`{"transport": "http", "address":
     "/listTopicManagers", "filters": ["listTopicManagers"]}`, … with
     `filters: {"listTopicManagers": "overlay.listTopicManagers",
     "listLookupServiceProviders": …, "topicDocumentation": …,
     "lookupDocumentation": …}`) and the token list `{"transport": "http",
     "address": "/color/tokens", "filters": ["tokens"]}` with `filters.tokens
     = "color-lookup.tokens"`. Called as a filter, `color-lookup`'s
     `tokens` answers `{answer: <the http answer>}` (0.8.0).
4. **The register calls**, made by root once the app is installed, two
   per token it runs: `{"fn": "register", "args": {"topic":
   "tm_color_<assetId>", "program": "color-topic"}}`, then `{"fn":
   "registerLookup", "args": {"service": "ls_color_<assetId>", "program":
   "color-lookup", "topics": ["tm_color_<assetId>"]}}` (`tm_color` by
   `register` alone); `deregisterLookup {service}` then `deregister
   {topic}` drop one.
5. **`requires: ["chain/1"]`.**

The rest (the http route `/submit`, the read route `/lookup` and its filter
`lookup`, the box `<app>` as an event route and a mailbox route) is derived
from `config.overlay` by the install; a registered topic's gossip is routed
by the engine's `subscribe` events (skein #119), not by routes. Keep the box
`<app>` the engine's: a route of your own there overrides the derived
mailbox route, and the engine's own watch, resume and wait would go to it.

A program of the app's own that reads token outputs depends on the
`1color` module (below) for the parsers and the rules.

## Depend on the library

`build.zig.zon`:

```zig
.dependencies = .{
    .skein_1color = .{
        .url = "https://github.com/shruggr/skein-1color/archive/refs/tags/v0.10.0.tar.gz",
        .hash = "<zig fetch --save prints it>",
    },
},
```

`build.zig`:

```zig
const m = b.dependency("skein_1color", .{ .target = wasi, .optimize = .ReleaseSafe });
// … .imports = &.{.{ .name = "1color", .module = m.module("1color") }}
```

```zig
const color = @import("1color");
const tok = color.brc162.decode(script) orelse return; // {id, amount, role, payload, lock}
const id = color.token.tokenIdOfString("<txid>").?; // or "<txid>_<vout>", "<txid>.<vout>"
var buf: [color.name.max_suffix_len]u8 = undefined;
const text = color.name.tokenIdText(&buf, color.name.tokenIdOfString("<txid>").?); // "<txid>_0"
const j = try color.bsv21.judge(a, id, tx, previous_coins); // the rules over a bsv21.Tx
```

## Pages

Two static pages, for an app that carries the components (README "Carry
the components in another app") to serve. The 1Color app is not installed
by itself, so the pages are not served from this repo's manifest.

Every txid, token id, outpoint and topic the pages show is shortened, shown
whole on a click, and has a copy button; an outpoint is shown `<txid>.<vout>`,
and the underscore appears only in a token id, `<txid>_<vout>` for every
token (`<txid>_0` included; 0.8.1), and a token's topic and lookup, `tm_color_<assetId>` and
`ls_color_<assetId>` (0.9.0, BRC-207) (0.7.4; David, 2026-10-08).

| page | served at | what |
|---|---|---|
| deploy | `/<app>/color/deploy/` | **Deploy a token.** Open to anyone: a helper over the user's own wallet. Fields: symbol, decimals (0 to 18), fixed supply (an amount in whole tokens) or authority (amount 0, the deploy output mints), an optional icon: an image file, embedded in the deploy (0.9.0; BRC-162 draft BRCs#308: the action takes `{mediaType, bytes}`), previewed, its media type `image/…`. `@1sat/actions`' `deploy1Color` (0.10.1; `deployMandala` before) builds the BRC-162 deploy at output 0 and hands it to the wallet's BRC-207 `color` module (the wallet connected through `@1sat/connect`), which signs and broadcasts it, files it in its own basket (`p color <txid>v0`, or `p color <txid>v0 authority` for an authority deploy: BRC-207's asset tag, `assetBasket` of `@bsv/color-permission-module`) and submits it to `tm_color` and the token's topic at the wallet's configured overlay. A result with an error (a refused permission, say) shows as an error; nothing is shown as deployed. Then the page submits the deploy (the AtomicBEEF the action returns) to the overlay it is served from: `POST <base>/<app>/submit`, the BEEF as the body, `X-Topics: tm_color` only (the token's own topic `tm_color_<txid>_0` did not exist here before this transaction, so nobody serves it yet; a repeat of the wallet's own submit is harmless). The page POSTs itself, unsigned, by plain `fetch` (0.7.5; David, 2026-10-08: "We shouldn't be using authfetch for the submit http method"): the skein admits an unsigned POST at a route whose filter validates the payload (shruggr/skein#135, #143), and the `/submit` route's filter is `kernel.beef`. (0.6.1 to 0.7.4 signed it through the wallet's AuthFetch, which refuses the `X-Topics` header.) The answer is BRC-22's STEAK (skein-overlay 0.9.1; 0.7.2 here): the page shows the topics that admitted outputs, or "taken by no topic", or, on a 503 + `Retry-After`, "not decided yet" (the submission stands; Submit again polls it); the discovery topic has the deploy once admitted (lookup `ls_color_deploys`). An overlay that does not serve `tm_color` takes the submit and admits nothing. The page shows the token id, `<txid>_0` (0.8.1; every token is `<txid>_<vout>`), and the topic and lookup to register, `tm_color_<txid>_0` and `ls_color_<txid>_0`; root copies the topic to the tokens page to register both. If the submit fails, "Submit again". (Until 0.10.0 the SDK filed the deploy in a second step, and "File it again" reran it; the module files it in the same `createAction`.) |
| tokens | `/<app>/color/tokens/` | **Tokens on this overlay.** Root's page (the key that claimed the instance, or one root granted; shruggr/skein#143). Lists the registered topics judged by `color-topic` (the overlay engine's head `<app>/topics`, `{kind: "overlay-topics", topics: [{topic, program}]}`, read through the instance's explorer, `/explore/head/<app>/topics`, which is root's read), each with its icon and symbol from its deploy (0.9.0: the read `/<app>/color/tokens`, a 1Color deploy's embedded image as a data URL) and whether its lookup `ls_color_<assetId>` is registered (the head `<app>/lookups`). Register a token by its topic name (`tm_color_<txid>_<vout>`, `tm_color_<txid>_0` at output 0): two messages, its topic then its lookup (0.9.0, BRC-207); deregister a listed token (its lookup, then its topic); and a switch that registers or deregisters the discovery topic `tm_color`. Each change is root's message to the app's box `<app>/register`, the engine's `{fn: "register", args: {topic, program: "color-topic", seed?}}`, `{fn: "registerLookup", args: {service, program: "color-lookup", topics}}`, `{fn: "deregisterLookup", args: {service}}` or `{fn: "deregister", args: {topic}}` (each answered before the next; a refusal stops the rest), sent the way skein-site sends root's messages (skein's `RawBox.send`: a BRC-104-signed `POST <base>/sendMessage`, BRC-231 CBOR, recipient the instance's identity from its signed answers). The outcome is the step's result record (`{kind: "overlay-result", op, topic, active, changed}` or `{op, error}`), whose CID the step prints on stdout, read from the thread the message launched; then the set is read again. A wallet that does not hold root gets the explorer's 403, and its messages run nothing (the route `register` is gated by root: recorded, no step). **The token's own deploy** (0.6.2, skein-overlay 0.7.8): a register of `tm_color_<txid>_<vout>` carries `seed: [<txid>]`, the deploy; the engine judges the deploy under the new topic from what the instance's chain state already holds, and the answer says `seeded` or `missing` (`untaken`: held, but the topic took nothing of it). The page shows which. Seeded, nothing more is sent. Missing (the overlay never held the deploy: a token deployed elsewhere, or before discovery), the connected wallet's copy: `listOutputs` on the token's basket as the wallet's `color` module files it, `p color <txid>v<vout>`, then `p color <txid>v<vout> authority` (0.10.1; `mandala <txid> <vout>` before), with `include: "entire transactions"` (the wallet that deployed it holds it there until the deploy output is spent), submitted under both `tm_color` and `tm_color_<txid>_<vout>`. Before 0.6.2 the page looked the deploy up (`ls_color_deploys`) and resubmitted it after the register; the seed replaces that. Each registered token has "Submit deploy to this overlay", on demand: the deploy's BEEF from the discovery lookup (`POST <base>/<app>/lookup {service: "ls_color_deploys", query: {tokenId}}`, the token id `<txid>_0` or `<txid>_<vout>` from the topic), submitted with `X-Topics: tm_color_<txid>_<vout>`, else the wallet's copy as above. The lookup is a POST through the instance's BRC-104 client, as the reads do (0.6.1); the submit is a plain `fetch`, unsigned, as on the deploy page (0.7.5). The page shows the answer (the STEAK in words, or not decided yet; 0.7.2) and where the BEEF came from. **Market and validator** (0.9.1, skein-overlay 0.12.0; David 2026-10-09: every skein is a market and a validator from install, always): no switch; the page says that registering a token starts both for it and deregistering stops them (0.7.3 to 0.9.0 had the two switches, `{fn: "market" | "validator", …}`). |

The page takes the app's name and the instance from its own URL:
`<base>/<app>/color/<page>/`, where `<base>` is the instance's origin or a
host's `/@<handle>` dev form. So the same files work under any app name.

**Embedding.** The app's build copies `www/*` into its own `www/color/`
(`www/color/deploy/index.html`, `www/color/tokens/index.html`,
`www/color/assets/…`), and its static rows serve that directory under
`/<app>/` (skein-static's README has the rows). Asset paths are relative, so
`/<app>/color/deploy` (redirected to `…/deploy/`) loads them from
`/<app>/color/assets/`. Nothing is built on the skein: `www/` is committed
as built. The token list read is `/<app>/color/tokens` without the slash
(0.7.0): an exact read takes that path, so the tokens page is reached at
`/<app>/color/tokens/` only (the slash-less path answers the JSON list,
not the redirect to the page).

**The wallet's grouped request.** A wallet reads `manifest.json` at the
origin's root, so these pages ship none. The deploy goes through the
wallet's BRC-207 `color` module (0.10.1): the key under
`[2, "p color issue <prefix> <suffix>"]`, keyID `color`, counterparty self,
the plan in the action's labels, and the basket `p color <txid>v0` (or
`… authority`), all `@1sat/actions`' `deploy1Color` and the module's names,
not this repo's; the module asks the user for its own consent. The
tokens page uses a BRC-104 session (`[2, "auth message signature"]`,
`[2, "server hmac"]`). Without them in the embedding app's manifest, the
wallet asks for each when it is first used.

**Build and test** (Node 22 or later, npm):

```
cd web
npm ci
SKEIN_DIR=../../skein npm run build    # typecheck, then ../www; SKEIN_DIR: a skein checkout at web/lib/SKEIN_REV
npm test                               # vitest: the page's place from its URL, the deploy input and the SDK's deploy from it, root's calls, the registered set and the answers, the sendMessage request, the deploy's submit, the register → lookup → submit chain and the wallet fallback
npm run typecheck
```

The stack is the AMM pages' (amm-poc `web/ui`): Vite, React, `@1sat/react`
and `@1sat/connect` for the wallet, `@1sat/actions` for the deploy. Root's
messages and the explorer reads are skein's own client
(`src/client/raw.ts`), bundled from the skein checkout as skein-site bundles
it. `deploy1Color` is imported from the package's `dist/1color/deploy.js`,
not its entry, which re-exports every action. The bundle is about 2 MB
(480 KB gzipped). Most of it is `@1sat/connect`, which ships as one
prebuilt 2 MB file. No analytics.

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/{color-topic,color-lookup}.wasm
zig build bin      # the same, into bin/ (committed)
zig build test     # the parsers, the rules, the topic, the lookup, natively
```

`bin/overlay.wasm` is copied from skein-overlay v0.14.0's build (`zig build
bin` there; the same bytes as its committed `bin/overlay.wasm`), not built
here. With a local skein-overlay
checkout: `zig build --fork=../skein-overlay`.

## Docs

| what | where |
|---|---|
| the components, the topic rule, the lookup, registering topics, what is not built | [docs/1COLOR.md](docs/1COLOR.md) |
| the engine, its contracts and gossip | shruggr/skein-overlay `docs/OVERLAY.md` |
| registering a topic; apps and manifests | shruggr/skein-overlay `docs/OVERLAY.md` "Register a topic"; skein `docs/APPS.md` §4, §6 |
| the protocol | BRC-162 (1Color), BRC-161 (BSV-21 JSON), BRC-207 (the wallet's 1Color module: the topic and lookup names, the two lookup queries, deployment discovery) |

## Versions

| | |
|---|---|
| this app, its programs and package | 0.10.1 (tag `v0.10.1`) |
| the pages | `@1sat/actions`, `@1sat/react`, `@1sat/connect`, `@1sat/templates` 0.1.0 (published; on `@bsv/sdk` 4), `@bsv/sdk` aliased to `npm:@bopen-io/sdk@4.0.1` and `@bsv/color-permission-module` to `npm:@bopen-io/color-permission-module@0.1.0` (the interim @bopen-io repack of ts-stack #1243 until upstream publishes; an npm `overrides` entry keeps one copy of `@bsv/sdk`), `web/package.json`, exact; skein's client at `web/lib/SKEIN_REV` (the build also needs the package `buffer` to resolve from that checkout, for its `web/shims/buffer.ts`: a `node_modules` there, or a link to `web/node_modules`). The committed `www/` is the 0.10.1 build. |
| skein-overlay | v0.14.0 by tag URL and hash in `build.zig.zon` (modules `topic`, `lookup`, `sk`); the engine in `bin/` is its build |
| skein-sdk | v0.11.0, through skein-overlay (modules `chain`, `sk`, `cbor`) |
| requires | `chain/1` (shruggr/skein-chain 0.3.0) |
| skein | log format 10, the BEEF envelope beside the pointer record (shruggr/skein#146); the routes / filters / roles manifest (shruggr/skein#143; 0.8.0: `dispatch` and `reads` became `routes`, the `register` box root's, the reads read routes whose filters answer) |

The token library and its tests moved here from amm-poc
`programs/amm-topic` (shruggr/skein#120); its fixtures
(`src/fixtures/vectors.zig`) are generated there by `gen/main.go` from the
AMM's Pool contract.

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31), this repo's issue is
[#120](https://github.com/shruggr/skein/issues/120). MIT, as skein.
