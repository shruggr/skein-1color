/**
 * The overlay the pages are served from, over its HTTP routes
 * (skein-overlay docs/OVERLAY.md "Submitting" and the routes table). The
 * submit is a plain `fetch`, unsigned: the skein admits an unsigned POST at a
 * row whose filter validates the payload (shruggr/skein#135), and the
 * overlay's `submit` row is `sender "*", filter "beef"` (David 2026-10-08:
 * "We shouldn't be using authfetch for the submit http method"; AuthFetch
 * refuses the X-Topics header). The lookup goes through the connected
 * wallet's BRC-104 client (`signedFetch`, skein's `RawBox` AuthFetch). The
 * `Fetch` parameters are there for tests.
 *
 * - `POST <app base>/submit`: the BEEF as the body, `X-Topics` a comma list;
 *   BRC-22 (skein-overlay 0.9.1): the request waits and answers the STEAK
 *   `{<topic>: {outputsToAdmit, coinsToRetain, coinsRemoved}}`; 503 with
 *   Retry-After when nothing is decided yet (the submission stands; a
 *   resubmission polls it).
 * - `POST <app base>/lookup {service, query}` →
 *   `{type: "output-list", outputs: [{beef, outputIndex}]}`.
 * - `GET <app base>/color/tokens?limit&skip` (a read, plain fetch): the
 *   deploys `tm_color` admitted, `[{tokenId, topic, sym, dec, icon?, txid,
 *   vout}]`, `icon` a 1Color deploy's embedded image as a data URL (a BRC-161
 *   JSON deploy's icon string as written).
 *
 * `<app base>` is `<base>/<app>` (the page's place, src/where.ts). The engine
 * ignores a topic it does not serve, so a submit to an unregistered topic
 * still lands (and is admitted by no one).
 */
import type { WalletInterface } from "@bsv/sdk";
import { assetBasket } from "@bsv/color-permission-module";
import { RawBox } from "skein/src/client/raw.ts";
import { DISCOVERY } from "./tokens/list";

export { DISCOVERY };

/**
 * The lookup over the discovery topic `tm_color` (skein-1color 0.12.0): `ls_color`, the deploy asked
 * by its outpoint `{txid, outputIndex}` (the token id `<txid>_<vout>` IS that outpoint).
 * `ls_color_deploys` is gone.
 */
export const DEPLOYS_LOOKUP = "ls_color";

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

/** The browser's own `fetch`, unsigned: the submit's. */
export const plainFetch: Fetch = (url, init) => fetch(url, init);

/**
 * The connected wallet's BRC-104 client to the instance at `base` (the
 * instance's place, `where.base`, not the app's): skein's `RawBox` AuthFetch,
 * which shakes hands under a `/@<handle>` prefix too.
 */
export function signedFetch(wallet: WalletInterface, base: string): Fetch {
  return authFetchOf(new RawBox(wallet, base));
}

/** A `RawBox`'s AuthFetch as a `Fetch` (the tokens page reuses its instance's). */
export function authFetchOf(box: RawBox): Fetch {
  return (url, init) => box.af.fetch(url, init as Parameters<RawBox["af"]["fetch"]>[1]);
}

/** The app's routes' base: `<base>/<app>`. */
export function appBaseOf(w: { base: string; app: string }): string {
  return `${w.base}/${w.app}`;
}

/**
 * Submit a BEEF under topics (BRC-22): the answer, in words — the topics that
 * admitted outputs (from the STEAK), "taken by no topic", or, on a 503, "not
 * decided yet". Any other status is an error. Unsigned: plain `fetch` unless
 * a test passes `f`.
 */
export async function submitBeef(appBase: string, beef: ArrayLike<number>, topics: string[], f: Fetch = plainFetch): Promise<string> {
  const r = await f(`${appBase}/submit`, {
    method: "POST",
    headers: { "content-type": "application/octet-stream", "x-topics": topics.join(",") },
    body: Uint8Array.from(beef) as unknown as BodyInit,
  });
  const text = await r.text();
  if (r.status === 503) return `not decided yet (resubmit after ${r.headers.get("retry-after") ?? "a while"} s)`;
  if (r.status !== 200) throw new Error(`submit: HTTP ${r.status} ${text.slice(0, 200)}`);
  let steak: unknown;
  try { steak = JSON.parse(text); } catch { /* below */ }
  if (!steak || typeof steak !== "object" || Array.isArray(steak)) throw new Error(`submit: not a STEAK: ${text.slice(0, 200)}`);
  const took = Object.entries(steak as Record<string, { outputsToAdmit?: unknown }>)
    .filter(([, e]) => Array.isArray(e?.outputsToAdmit) && e.outputsToAdmit.length > 0)
    .map(([t, e]) => `${t} (outputs ${(e.outputsToAdmit as number[]).join(", ")})`);
  return took.length ? `admitted under ${took.join("; ")}` : "taken by no topic";
}

/** The token a topic serves: `tm_color_<assetId>`, `tm_color_<txid>_<vout>` → `<txid>_<vout>`, `_0` included (BRC-207; BRC-162 "Token identification"). */
export function tokenOfTopic(topic: string): { tokenId: string; txid: string; vout: number } {
  const m = /^tm_color_([0-9a-f]{64})_(0|[1-9]\d*)$/.exec(topic);
  if (!m) throw new Error(`${topic}: not a token's topic (tm_color_<txid>_<vout>)`);
  const vout = Number(m[2]);
  return { tokenId: `${m[1]}_${vout}`, txid: m[1]!, vout };
}

/** The deploy's BEEF from the discovery lookup (`ls_color {txid, outputIndex}` at the deploy's outpoint); undefined when it has none. */
export async function lookupDeployBeef(appBase: string, tokenId: string, f: Fetch): Promise<Uint8Array | undefined> {
  const m = /^([0-9a-f]{64})_(0|[1-9]\d*)$/.exec(tokenId);
  if (!m) throw new Error(`${tokenId}: not a token id (<txid>_<vout>)`);
  const r = await f(`${appBase}/lookup`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ service: DEPLOYS_LOOKUP, query: { txid: m[1], outputIndex: Number(m[2]) } }),
  });
  const text = await r.text();
  if (r.status !== 200) throw new Error(`lookup ${DEPLOYS_LOOKUP}: HTTP ${r.status} ${text.slice(0, 200)}`);
  const a = JSON.parse(text) as { type?: unknown; outputs?: Array<{ beef?: unknown }> };
  if (a.type !== "output-list" || !Array.isArray(a.outputs)) throw new Error(`lookup ${DEPLOYS_LOOKUP}: not an output-list: ${text.slice(0, 200)}`);
  const beef = a.outputs[0]?.beef;
  return Array.isArray(beef) && beef.length > 0 ? Uint8Array.from(beef as number[]) : undefined;
}

/**
 * The deploy's BEEF from the connected wallet: the deploy output in the
 * token's basket as the wallet's BRC-207 `color` module files it,
 * `p color <txid>v<vout>` (a fixed-supply deploy) or
 * `p color <txid>v<vout> authority` (an authority deploy), its transaction as
 * BEEF (`include: "entire transactions"`). Undefined when the wallet holds it
 * in neither (not the deployer's, or the output spent).
 */
export async function walletDeployBeef(wallet: WalletInterface, txid: string, vout: number): Promise<ArrayLike<number> | undefined> {
  for (const basket of deployBaskets(txid, vout)) {
    const r = await wallet.listOutputs({ basket, include: "entire transactions", limit: 100 });
    const held = r.outputs.some((o) => o.outpoint === `${txid}.${vout}`);
    if (held && r.BEEF && r.BEEF.length > 0) return r.BEEF;
  }
  return undefined;
}

/** The two baskets a deploy output can be in (BRC-207 `assetBasket`): value, then authority. */
export function deployBaskets(txid: string, vout: number): [string, string] {
  const assetId = `${txid}_${vout}`;
  return [assetBasket(assetId, "value"), assetBasket(assetId, "authority")];
}

export type Submitted = { answer: string; via: "lookup" | "wallet"; topics: string[] };

/**
 * Submit a token's deploy to its own topic: the deploy's BEEF from the
 * discovery lookup, submitted under the token's topic; if the lookup has none
 * (a token deployed before the deploy page submitted to discovery), the
 * wallet's copy, submitted under both the discovery topic and the token's.
 * `f` is the lookup's (signed); the submit is plain `fetch` (`submitF`, for
 * tests).
 */
export async function submitDeployToTopic(appBase: string, topic: string, wallet: WalletInterface | undefined, f: Fetch, submitF: Fetch = plainFetch): Promise<Submitted> {
  const { tokenId } = tokenOfTopic(topic);
  const found = await lookupDeployBeef(appBase, tokenId, f);
  if (found) {
    const topics = [topic];
    return { answer: await submitBeef(appBase, found, topics, submitF), via: "lookup", topics };
  }
  return submitWalletDeploy(appBase, topic, wallet, `the discovery lookup has no deploy for ${tokenId}`, submitF);
}

/**
 * The wallet's copy of a token's deploy submitted under the discovery topic
 * and the token's: for a deploy the overlay never held (a register's seeding
 * answered it `missing`, skein-overlay 0.7.8). `why` begins the error when the
 * wallet cannot give it. The submit is plain `fetch` (`submitF`, for tests).
 */
export async function submitWalletDeploy(appBase: string, topic: string, wallet: WalletInterface | undefined, why = "the overlay does not hold the deploy", submitF: Fetch = plainFetch): Promise<Submitted> {
  const { txid, vout } = tokenOfTopic(topic);
  if (!wallet) throw new Error(`${why}, and no wallet is connected to give it`);
  const beef = await walletDeployBeef(wallet, txid, vout);
  if (!beef) throw new Error(`${why}, and this wallet does not hold it (baskets ${deployBaskets(txid, vout).join(", ")})`);
  const topics = [DISCOVERY, topic];
  return { answer: await submitBeef(appBase, beef, topics, submitF), via: "wallet", topics };
}

/** One deploy on the token list (`/<app>/color/tokens`). */
export interface Listed {
  tokenId: string;
  topic: string;
  sym: string;
  dec: number;
  /** A 1Color deploy's embedded image, `data:<mediaType>;base64,…`; a BRC-161 JSON deploy's icon string as written. */
  icon?: string;
  txid: string;
  vout: number;
}

/** The token list, every page of it (100 a page, at most `pages` of them), by plain fetch: a read. */
export async function listTokens(appBase: string, f: Fetch = plainFetch, pages = 10): Promise<Listed[]> {
  const out: Listed[] = [];
  for (let i = 0; i < pages; i++) {
    const r = await f(`${appBase}/color/tokens?limit=100&skip=${i * 100}`, { method: "GET" });
    const text = await r.text();
    if (r.status !== 200) throw new Error(`color/tokens: HTTP ${r.status} ${text.slice(0, 200)}`);
    const page = JSON.parse(text) as Listed[];
    if (!Array.isArray(page)) throw new Error(`color/tokens: not a list: ${text.slice(0, 200)}`);
    out.push(...page);
    if (page.length < 100) break;
  }
  return out;
}
