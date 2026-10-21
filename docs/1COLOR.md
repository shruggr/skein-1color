# 1Color on a skein

1Color tokens (BRC-162; BRC-207) served by a skein overlay: one topic per token, a
lookup service over the topics, and the topics root registers live.
Decided in shruggr/skein#120 (walkthrough 2026-10-05): components, not one
app; one topic per token; the protocol first; governance later, per token.
0.10.0 is the 1Color rename (David Case, 2026-10-15): every name is
BRC-207's `color` or this repo's `1color`, with no alias (CHANGELOG.md).

## The components

| component | file | role | what |
|---|---|---|---|
| topic manager | `bin/color-topic.wasm`, `src/color_topic.zig` | `color-topic` | judges `tm_color_<assetId>` by the token rules |
| lookup service | `bin/color-lookup.wasm`, `src/color_lookup.zig` | `color-lookup` | `ls_color`: three queries over its index; `ls_color_deploys`: a token's deploy output; `ls_color_<assetId>`: BRC-207's two queries (0.9.0); fn `tokens`: the token list, a read (0.7.0); one index, `<app>/ls_color`, for every name |
| discovery topic | the same program as the topic manager | `color-topic` | `tm_color`: every token's deploy output |
| the library | `src/lib.zig` (module `1color`) | | the parsers, the rules, topic names, the verdict |
| the engine | `bin/overlay.wasm` | `overlay` | shruggr/skein-overlay 0.14.0: serves the topics and lookups, keeps the registered sets (`register` / `deregister`, `registerLookup` / `deregisterLookup`) |

The topic manager and the lookup service are programs on skein-overlay's
contracts (`topic`, `lookup`). An app carries them in its tree with the
engine and names them in `config.overlay` (README "Carry the components in
another app"). This repo's `etc/app.json` is a manifest of the three alone.

## The topic

**Names** (`src/name.zig`; BRC-207 "Overlay spendability contract", David
Case, 2026-10-08). A token's topic is `tm_color_<assetId>` and its lookup
`ls_color_<assetId>`, the asset id its token id `<txid>_<vout>`, `_0`
included. `<txid>` is the deploy txid, 64 lowercase hex characters in
display order; `<vout>` decimal without leading zeros.

- `tm_color_<txid>_0`: a token deployed at output 0. Its genesis is a
  binary deploy (id `OP_0`) or a BRC-161 `deploy+mint` / `deploy+auth`
  inscription there; on the wire its id is the 32-byte txid.
  BRC-162 "Token identification": a BRC-161 token deployed at output 0 is
  the same token in both forms.
- `tm_color_<txid>_<vout>`: a token deployed under BRC-161 at a non-zero
  output. Its binary outputs carry the 36-byte id, the only tokens that
  have one.
- `tm_color` is the discovery topic and `ls_color_deploys` its lookup
  (below): neither carries an asset id, so neither is a token's (a token's
  name is the prefix `tm_color_` / `ls_color_` followed by one).
- 0.8.2's `tm_<txid>_<vout>` and the bare `tm_<txid>` (until 0.8.1) are not
  topic names, neither produced nor taken: no alias. Names derived from a
  topic follow it: `tm_color_<txid>_0-live`.

**Token ids** (`src/name.zig` `tokenIdOfString`, `tokenIdText`). A token id
is the deploy outpoint, written `<txid>_<vout>` for every token, 1Color and
legacy BSV-21 alike, `_0` included; the bare 32-byte txid is the wire form
only (David, 2026-10-07, shruggr/skein#120; BRC-162 "Token identification":
"For display and APIs, the string form is `<txid>_<vout>` … for a 32-byte
id, appends `_0`"). 0.3.1 to 0.8.0 wrote a 1Color token as the bare
`<txid>`. Topic names are unchanged.

Input takes any form: `<txid>`, `<txid>_<vout>` or the BRC-36
`<txid>.<vout>`. `<txid>`, `<txid>_0` and `<txid>.0` all name the
token at output 0, whatever the form of its deploy.

**The rule** (`src/bsv21.zig`, `src/token.zig`): BRC-162 and BRC-161
"Validation rules" for the topic's token, over the transaction and the
outputs its inputs spend.

- An output is binary when it carries a valid BRC-162 prefix, else JSON
  when it carries a valid BSV-21 inscription, else not a token output.
- The deploy is admitted at the token's deploy outpoint only.
- An authority output (amount 0, JSON `auth`) and a mint (a binary value
  output, a JSON `mint`) are admitted only when the transaction spends an
  authority of the token.
- Every other value output, and every JSON `burn`, is balance-checked
  against the token's inputs, all together: admitted when the inputs cover
  them, none of them when they do not. An excess is an implicit burn.
- Once a transaction spends a binary output of the token, its JSON outputs
  of that token are not admitted (one-way migration) and count for nothing.
- A transaction whose balance-checked outputs fail and which has nothing
  else of the token admits and retains nothing. Otherwise its admitted
  outputs stand and the token coins it spends are retained.

Only inputs that are previous coins (outputs of the token the topic holds)
count. The topic knows no application: a contract's output is admitted
exactly when the rules admit it. There is no ownership, authority-chain or
control check.

**Metadata and documentation** (skein-overlay#2): the topic's name, a
one-line description naming the token by its id `<txid>_<vout>`
(`<txid>_0` at output 0), version 0.4.0; the documentation is
the rule above in markdown.

## The lookup

One program, `color-lookup`, serves three kinds of name and keeps one
index for all of them, the head `<app>/ls_color` (its `spec.index`;
skein-overlay 0.11.0: the engine's hooks reach the program once per
admitted transaction and topic, whatever its names, and every name reads
the one index). The hooks go by the topic, never by the name.

`ls_color`, the query shapes of the ts-stack BRC-162 lookup (Deggen's,
`packages/overlays/topics`, its lookup docs). The first
key present, in this order, answers:

| query | answer |
|---|---|
| `{authoritiesTokenId, limit?, skip?}` | the token's unspent authority outputs, its deploy among them, in outpoint order |
| `{tokenId, limit?, skip?}` | the token's unspent value outputs, in outpoint order |
| `{txid, outputIndex}` | the value or authority output at that outpoint, if unspent |

- A token id is taken as `<txid>`, `<txid>_<vout>` or `<txid>.<vout>`
  ("Token ids" above). Lowercase hex in display order; the vout decimal
  without leading zeros.
- `limit` 1 to 100 (default 100), `skip` 0 to 100000 (default 0). Any other
  key, or a value out of shape, is refused.
- Outpoint order is the txid in display order, then the output index (the
  ts-stack sort).
- The answer is an output-list of outpoints, with no token id strings. The
  engine builds each output's BEEF from the chain state, and the service never
  handles one. A client writes the token's id `<txid>_<vout>` (`<txid>_0`
  at output 0) whatever the form of its deploy.

**The index** is five maps under the head `<app>/ls_color`, kept by the
lookup hooks the engine calls in the step that admits or rejects:

| map | key | value |
|---|---|---|
| `values` | token ‖ outpoint | — |
| `authorities` | token ‖ outpoint | — |
| `outputs` | outpoint | kind ‖ token, then the spender's txid once spent |
| `admitted` | token ‖ outpoint | — (every output the token's topic validly admitted, a JSON `burn` too; kept once spent, dropped on rejection: BRC-207) |
| `deploys` | token | — (the discovery topic's, below) |

(token: its deploy txid in display order ‖ vout, 4 bytes big-endian; an
outpoint the same.) `admitted` classifies each admitted output by the rules
for the topic's token: a deploy or an authority into `authorities`, a value
(a transfer or a mint) into `values`, a JSON `burn` into neither. `spent`
takes the output out of its index and records the spender. `rejected`
removes the transaction's outputs and returns the outputs it had spent. A
hook for a topic that is not a token's does nothing.

## BRC-207: a token's lookup

`ls_color_<assetId>` (0.9.0; David Case, 2026-10-08), registered beside
the token's topic (below, "Registering a token"), answers BRC-207's two
queries (bsv-blockchain/BRCs master, `wallet/0207.md` "Overlay
spendability contract"; the wire names `color`, 0.10.0):

```json
{"service": "ls_color_<assetId>",
 "query": {"type": "color-spendability", "version": 1, "assetId": "<assetId>",
           "topic": "tm_color_<assetId>", "outpoints": ["<txid>.<vout>", …]}}
```

- `color-spendability`: an output-list of exactly the queried outpoints
  currently admitted to the topic and unspent, each `{beef, outputIndex}`.
  Admitted: in `admitted` for the asset. Unspent: the chain state names no
  spender for it (`chain/state`'s `spent`, the same reading the engine's own
  `inTopic` uses).
- `color-admission`: the same shape and rules, the outpoints ever validly
  admitted, spent ones included (a rejected transaction's outputs never
  were).
- Exactly the queried outpoints: each once (a repeated one is answered
  once), in the query's order, nothing unrelated. An empty list is a valid
  "no".
- Validated strictly: exactly the keys `type`, `version`, `assetId`,
  `topic`, `outpoints`; `version` the integer 1; `assetId` and `topic`
  this service's own, written exactly (`<txid>_<vout>`,
  `tm_color_<txid>_<vout>`); each outpoint canonical BRC-36 dot form, 64
  lowercase hex, `.`, the index without leading zeros, at most 2^32 - 1.
  Anything else is refused (the engine answers 400). The per-asset service
  takes no other query, and `ls_color` takes no BRC-207 query.
- There is no wildcard: a token whose lookup is not registered answers
  400 "Lookup service not supported", never an empty list (which would
  mean "not spendable").

## The discovery topic

`tm_color` (#120 item 11; BRC-207 "Deployment discovery"): one fixed
topic, not per token, that admits deploy outputs only, of every token,
whatever the carrier's satoshis (no one-satoshi filter), legacy BRC-161
deploys at a non-zero output included. It is a registry of what tokens
exist and the metadata each was deployed with (the deploy's payload:
decimals, symbol, icon, ...).

- `color-topic` judges it when called with that topic name (token.zig
  `judgeDeploys`): an output is admitted when it is a valid deploy by the
  rules above, a BRC-162 deploy (id `OP_0`) at output 0 or a BRC-161
  `deploy+mint` / `deploy+auth` inscription at any output. Nothing else is
  admitted, and nothing about governance is checked. The coins an admitted
  transaction spends are retained.
- `ls_color_deploys` is `color-lookup` called as that service. Its map
  `deploys` (token → nothing; a token id is its deploy outpoint), in the
  program's one index, holds every deploy the topic admitted. `{tokenId}` answers the deploy output, an
  output-list of one (empty if none); any other key is refused. A deploy
  stays listed once spent (a registry); a rejected transaction's deploys are
  removed. This is the shape of ts-stack's `metadataTokenId`, under its own
  key.
- It is switched like a token: registered with `register {topic:
  "tm_color", program: "color-topic"}`, dropped with
  `deregister`. It is not in `config.overlay.topics`: an entry there is
  served from the install on, which no message can turn off.

## The token list

Decided (shruggr/skein#120, 2026-10-06): the token list is a read function
of the 1Color components, not a BRC-24 query. `color-lookup`'s fn
`tokens`, served by the read route `/<app>/color/tokens` (the manifest's
`{"transport": "http", "address": "/color/tokens", "filters": ["tokens"]}`,
`filters.tokens = "color-lookup.tokens"`, shruggr/skein#143: the function
runs as the route's filter over the current state and answers `{answer:
<the http answer>}`; any method, signed or not, no entry, nothing logged).

- **Query**: `{limit?, skip?}`, in the query string
  (`?limit=20&skip=40`) or a JSON body (both: the body's win). `limit` is 1
  to 100 (default 100), `skip` 0 to 100000 (default 0). Any other key, or a
  value out of range, is a 400 `{status: "error", message}`.
- **Answer**: 200, a JSON array, one entry per deploy the discovery topic
  `tm_color` admitted (the map `deploys` of the program's index,
  `<app>/ls_color`; nothing when the topic is not registered):

  ```
  [{tokenId, topic, sym, dec, icon?, txid, vout}]
  ```

  `tokenId` `<txid>_<vout>` (`<txid>_0` at output 0, a binary deploy's or a
  BRC-161 one's alike), `topic` the token's (`tm_color_<txid>_0` or
  `tm_color_<txid>_<vout>`), `txid` / `vout` the deploy outpoint. `sym`,
  `dec` and `icon` are the deploy's display fields: a BRC-161 deploy's JSON
  `sym`, `dec`, `icon`; a BRC-162 deploy's payload, a DAG-CBOR map read by
  the `1color` module (`brc162.metadataOf`: `sym` a text string, `dec` an
  unsigned integer 0 to 18, `icon` the embedded image, the array
  `[mediaType, bytes]` of a text string and a byte string, untagged — the
  BRC-162 draft bsv-blockchain/BRCs#308; the pointer forms, a 36-byte
  outpoint or a 4-byte output index, are gone, and any other shape is
  absent; a malformed field is absent, as in `@1sat/templates`). `sym` is
  `""` and `dec` 0 when the deploy carries none; `icon` is left out when it
  has none. **The icon's shape** (0.9.0, for David's review): a binary
  (1Color) deploy's is a data URL, `data:<mediaType>;base64,<bytes>`
  (left out when the media type is not an RFC 6838 `type/subtype`, which a
  data URL could not carry as written); a BRC-161 JSON deploy's is its
  `icon` string as written (an outpoint), as before.
- **Order: newest first**, by the chain state (`chain/state`, read only):
  a deploy not yet mined first, then by block height, then by position in
  the block, highest first; ties (unmined) by deploy outpoint, highest
  first. `skip` then `limit` apply to that order.
- It reads only: the discovery index, the deploys' transactions in the
  store, and the chain state's proofs. A deploy rejected after admission
  has left the index (its `rejected` hook), so it is not listed; one spent
  stays (a registry).

## Registering a token

The overlay serves only the tokens root registered (#120 item 2; the
calls are the engine's, skein-overlay 0.6.0 and 0.11.0 (root's box
`<app>/register` since 0.7.7, `<app>/overlay` from 0.6.2), docs/OVERLAY.md
"Register a topic", "Register a lookup service"). The manifest declares no
topics; there are no topic prefixes anywhere, in the configuration or in
the routes. A token is two registrations (0.9.0, BRC-207; David Case,
2026-10-08), its topic, then its lookup:

```
{fn: "register",         args: {topic: "tm_color_<assetId>", program: "color-topic", seed?: [<deploy txid>]}}
{fn: "registerLookup",   args: {service: "ls_color_<assetId>", program: "color-lookup", topics: ["tm_color_<assetId>"]}}
```

and deregistering reverses both: `{fn: "deregisterLookup", args:
{service}}`, then `{fn: "deregister", args: {topic}}`. The discovery topic
`tm_color` is registered by `register` alone (its lookup
`ls_color_deploys` is the manifest's). The topic's register, in full:

1. Root sends `{fn: "register", args: {topic, program:
   "color-topic"}}` to the app's box `<app>/register`. The topic is
   `tm_color_<assetId>` or `tm_color`; it follows from
   how the token was deployed (the deploy page shows it). The route
   `{address: "register", handler: "overlay.register"}` (relative; the
   install resolves it to `<app>/register`, skein#128) takes it to the
   engine; `roles: {root: ["register", "registerLookup",
   "deregisterLookup"]}` gates it
   (shruggr/skein#143: a message from a key without root is recorded and
   runs nothing).
2. The engine adds `{topic, program}` to its registered set, the head
   `<app>/topics` (`{kind: "overlay-topics", topics: [{topic, program}, …]}`,
   sorted, each once), and advances the head.
3. In the same step it emits `{event: "subscribe", topic, program, fn}` for
   `<topic>` (`submit`: submit and admit messages, one mesh) and
   `<topic>-proof` (`peerProof`), `program` the engine's role (skein-overlay
   0.12.0; `<topic>-admit` before). The host subscribes them and routes
   their messages by these events (skein #119). Then `liveness` and
   `beacon` on `<topic>-live` (every skein a market and a validator,
   always; the beat body the topic's view digest and, skein-overlay 0.14.0,
   its tip anchor and tail digest).
4. With `seed: [txid, …]` (skein-overlay 0.7.8; the tokens page sends
   the deploy's txid), the engine then judges each seed the instance's
   chain state holds under the new topic only, oldest first over its held
   ancestry, and admits it from the state — a token's topic gets its own
   deploy without a resubmission.
5. The step's result record is `{kind: "overlay-result", op: "register",
   topic, active: true, changed, seeded?, missing?}`; the engine also
   answers `{fn, request, replyTo, result: {topic, active, seeded?,
   missing?}}` to a sender a message can reach. A seed `missing` (the
   overlay never held it) is submitted the usual way.
6. From the next step the engine serves the topic, judged by
   `color-topic`: `/submit` with it in `X-Topics`, gossip on it, the
   listing, and the lookups (`ls_color` and `ls_color_deploys` list no
   `topics`, so they listen to every topic served; `color-lookup` hears
   each admission once).
7. Then root sends `registerLookup` for `ls_color_<assetId>`: the engine
   adds it to its registered lookups, the head `<app>/lookups`, and serves
   it from the next step (`/lookup`, the listing), answered `{service,
   active}`.

`{fn: "deregister", args: {topic}}` removes it and emits `unsubscribe` for
the same three. Both are idempotent: registering a registered topic, or
deregistering one that is not, writes and emits nothing. A topic registered
with another program is refused (deregister it first). Deregistering does
not remove what the topic admitted or the lookup's index of it.

## The manifest

`etc/app.json`, and what an app that carries the components puts in its own
(README "Carry the components in another app"):

- `programs`: `overlay` (`bin/overlay.wasm`), `color-topic`,
  `color-lookup`;
- `config.overlay`: no `topics`; `lookups` `ls_color` and
  `ls_color_deploys`, each `{"program": "color-lookup"}` with no
  `topics` list;
- the routes, filters and roles (shruggr/skein#143; no senders): the
  route `{"address": "register", "handler": "overlay.register"}` (root's
  `register` / `deregister`, `registerLookup` / `deregisterLookup`, box
  `<app>/register`; `roles: {"root": ["register", "registerLookup",
  "deregisterLookup"]}`), `{"address": "submit",
  "filters": ["kernel.beef"], "handler": "overlay.submit"}` (the submission
  box `<app>/submit`: submissions by message, anyone whose BEEF validates,
  skein-overlay 0.7.6; no route of its own on `<app>`);
- the read routes (an http route with no handler: its filters answer,
  anyone, signed or not, nothing logged): the engine's four listing and
  documentation paths, `/listTopicManagers`,
  `/listLookupServiceProviders`, `/getDocumentationForTopicManager`,
  `/getDocumentationForLookupServiceProvider` (each with its filter, the
  engine's function, declared in `filters`), and the token list
  `/color/tokens` (the filter `tokens`, `color-lookup.tokens`).
  `/lookup` (a read route, the filter `lookup`) and `/submit` (`kernel.beef`
  → `overlay.submit`) and the box `<app>` (event and mailbox routes) are
  derived by the install from `config.overlay`;
- `requires: ["chain/1"]`.

A manifest MAY pre-declare topics in `config.overlay.topics` (an overlay
with fixed topics, e.g. OpNS's one global topic); they are served beside
the registered ones. 1Color's topics are dynamic, so it declares none.

## Not built

- **Governance** (#120 item 4: layers B to D). Ownership by BRC-42 key
  linkage (B); authority chains and `deploySig` from trusted issuers (C);
  controls: freeze, pause, access mode, sanctions screening, registry
  membership (D). For skein they are one profile set per token at
  registration, with that token's trusted issuers and registry; a token
  without one is the protocol alone, as now. The port follows Deggen's
  BRC-162 manager in ts-stack `packages/overlays/topics` (since
  0211fd965): `ownership.ts`, `verifyKeyLinkage.ts`, `authority.ts`,
  `deploySig.ts`, `controls.ts`, `AssetStateReducer.ts`.
- **The registry**: the registry token and its topic and lookup, ts-stack's
  registry overlay beside that manager.
- **The other three queries**: `metadataTokenId` (the deploy output; the
  discovery lookup answers the same as `{tokenId}`),
  `assetStateTokenId` (the token's admin state), `adminHistoryTokenId`
  (committed admin actions in fold order); the lookup service of Deggen's
  ts-stack manager. They answer from governance state.
- **An all-tokens topic**: one topic for every output of every 1Color
  token (wanted later for the 1sat hosted service). It gets its own name
  when it comes (Deggen's has a registry topic). The discovery topic
  holds deploys only; it is `tm_color`, BRC-207's deployment discovery
  topic.
- A registration profile (#120 item 5: the manager's settings in the app
  record), and an equivalence test in skein.
