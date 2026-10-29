// The pages' requests to the overlay they are served from: the deploy's
// submit under the discovery topic, and a token topic's own deploy submitted
// after its register (from the discovery lookup, or the wallet's copy).
import { afterEach, describe, expect, it, vi } from "vitest";
import type { WalletInterface } from "@bsv/sdk";
import { appBaseOf, authFetchOf, listTokens, submitBeef, submitDeployToTopic, submitWalletDeploy, tokenOfTopic, type Fetch } from "../src/overlay";
import { whereOf } from "../src/where";

const txid = "ec".repeat(32);
const base = appBaseOf(whereOf("https://1color.skein.nexus/amm/color/deploy/")!);
const beef = [1, 1, 1, 1, 0xbe, 0xef];

type Sent = { url: string; method?: string; headers: Record<string, string>; body: unknown };

/** BRC-22's answer (skein-overlay 0.9.1): the STEAK, and the page's words for it. */
const STEAK = { tm_color: { outputsToAdmit: [0], coinsToRetain: [], coinsRemoved: [] } };
const ADMITTED = "admitted under tm_color (outputs 0)";

function stub(lookupOutputs: unknown[]): { f: Fetch; sent: Sent[] } {
  const sent: Sent[] = [];
  const f: Fetch = async (url, init) => {
    sent.push({ url, method: init?.method, headers: init?.headers as Record<string, string>, body: init?.body });
    if (url.endsWith("/lookup")) return new Response(JSON.stringify({ type: "output-list", outputs: lookupOutputs }), { status: 200 });
    if (url.endsWith("/submit")) return new Response(JSON.stringify(STEAK), { status: 200 });
    return new Response("no", { status: 404 });
  };
  return { f, sent };
}

describe("the deploy page's submit", () => {
  it("POST <base>/<app>/submit, the BEEF as the body, X-Topics the discovery topic only", async () => {
    const { f, sent } = stub([]);
    expect(base).toBe("https://1color.skein.nexus/amm");
    expect(await submitBeef(base, beef, ["tm_color"], f)).toBe(ADMITTED);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toBe("https://1color.skein.nexus/amm/submit");
    expect(sent[0]!.method).toBe("POST");
    expect(sent[0]!.headers["x-topics"]).toBe("tm_color");
    expect(sent[0]!.headers["content-type"]).toBe("application/octet-stream");
    expect(Array.from(sent[0]!.body as Uint8Array)).toEqual(beef);
  });
  it("a refusal or an answer that is not a STEAK is an error; a 503 is not decided yet", async () => {
    const bad: Fetch = async () => new Response('{"status":"error","message":"no X-Topics"}', { status: 400 });
    await expect(submitBeef(base, beef, ["tm_color"], bad)).rejects.toThrow(/HTTP 400/);
    const notSteak: Fetch = async () => new Response("[]", { status: 200 });
    await expect(submitBeef(base, beef, ["tm_color"], notSteak)).rejects.toThrow(/not a STEAK/);
    const later: Fetch = async () => new Response('{"status":"error"}', { status: 503, headers: { "retry-after": "30" } });
    expect(await submitBeef(base, beef, ["tm_color"], later)).toBe("not decided yet (resubmit after 30 s)");
  });
});

describe("unsigned: the submit is plain fetch (shruggr/skein#135; David 2026-10-08)", () => {
  afterEach(() => { vi.unstubAllGlobals(); });
  it("submitBeef with no Fetch is the browser's fetch, X-Topics kept", async () => {
    const { f, sent } = stub([]);
    vi.stubGlobal("fetch", f);
    expect(await submitBeef(base, beef, ["tm_color"])).toBe(ADMITTED);
    expect(sent.map((s) => s.url)).toEqual([`${base}/submit`]);
    expect(sent[0]!.headers["x-topics"]).toBe("tm_color");
  });
  it("a token's deploy: the lookup through the signed Fetch, the submit through plain fetch", async () => {
    const signed = stub([{ beef, outputIndex: 0 }]);
    const plain = stub([]);
    vi.stubGlobal("fetch", plain.f);
    expect(await submitDeployToTopic(base, `tm_color_${txid}_0`, undefined, signed.f)).toEqual({ answer: ADMITTED, via: "lookup", topics: [`tm_color_${txid}_0`] });
    expect(signed.sent.map((s) => s.url)).toEqual([`${base}/lookup`]);
    expect(plain.sent.map((s) => s.url)).toEqual([`${base}/submit`]);
  });
});

describe("signed: the lookup goes through the wallet's BRC-104 client", () => {
  it("authFetchOf hands the request to the box's AuthFetch", async () => {
    const calls: Array<[string, RequestInit | undefined]> = [];
    const box = { af: { fetch: async (u: string, i?: RequestInit) => { calls.push([u, i]); return new Response(JSON.stringify({ tm_color: { outputsToAdmit: [], coinsToRetain: [], coinsRemoved: [] } }), { status: 200 }); } } };
    const f = authFetchOf(box as never);
    expect(await submitBeef(base, beef, ["tm_color"], f)).toBe("taken by no topic");
    expect(calls).toHaveLength(1);
    expect(calls[0]![0]).toBe(`${base}/submit`);
    expect(calls[0]![1]!.method).toBe("POST");
  });
});

describe("a token topic's own deploy", () => {
  it("the token id from the topic", () => {
    expect(tokenOfTopic(`tm_color_${txid}_0`)).toEqual({ tokenId: `${txid}_0`, txid, vout: 0 });
    expect(() => tokenOfTopic(`tm_color_${txid}`)).toThrow(/token's topic/);
    expect(() => tokenOfTopic(`tm_${txid}_0`)).toThrow(/token's topic/); // the old name: no alias
    expect(tokenOfTopic(`tm_color_${txid}_3`)).toEqual({ tokenId: `${txid}_3`, txid, vout: 3 });
    expect(() => tokenOfTopic("tm_color")).toThrow(/token's topic/);
  });
  it("register → the discovery lookup (ls_color, BRC-207 color-admission over tm_color) → submit under tm_color_<txid>_0 only", async () => {
    const { f, sent } = stub([{ beef, outputIndex: 0 }]);
    const r = await submitDeployToTopic(base, `tm_color_${txid}_0`, undefined, f, f);
    expect(r).toEqual({ answer: ADMITTED, via: "lookup", topics: [`tm_color_${txid}_0`] });
    expect(sent.map((s) => s.url)).toEqual([`${base}/lookup`, `${base}/submit`]);
    expect(JSON.parse(sent[0]!.body as string)).toEqual({ service: "ls_color", query: { type: "color-admission", version: 1, assetId: `${txid}_0`, topic: "tm_color", outpoints: [`${txid}.0`] } });
    expect(sent[1]!.headers["x-topics"]).toBe(`tm_color_${txid}_0`);
    expect(Array.from(sent[1]!.body as Uint8Array)).toEqual(beef);
  });
  it("the legacy form looks up its deploy outpoint <txid>, <vout>", async () => {
    const { f, sent } = stub([{ beef, outputIndex: 2 }]);
    await submitDeployToTopic(base, `tm_color_${txid}_2`, undefined, f, f);
    expect(JSON.parse(sent[0]!.body as string).query).toEqual({ type: "color-admission", version: 1, assetId: `${txid}_2`, topic: "tm_color", outpoints: [`${txid}.2`] });
  });
  it("the lookup has none: the wallet's copy (basket p color <txid>v0, BRC-207), under tm_color and tm_color_<txid>_0", async () => {
    const { f, sent } = stub([]);
    const asked: unknown[] = [];
    const wallet = {
      listOutputs: async (a: unknown) => { asked.push(a); return { totalOutputs: 1, outputs: [{ outpoint: `${txid}.0`, satoshis: 1, spendable: true }], BEEF: beef }; },
    } as unknown as WalletInterface;
    const r = await submitDeployToTopic(base, `tm_color_${txid}_0`, wallet, f, f);
    expect(r).toEqual({ answer: ADMITTED, via: "wallet", topics: ["tm_color", `tm_color_${txid}_0`] });
    expect(asked).toEqual([{ basket: `p color ${txid}v0`, include: "entire transactions", limit: 100 }]);
    expect(sent[1]!.headers["x-topics"]).toBe(`tm_color,tm_color_${txid}_0`);
    expect(Array.from(sent[1]!.body as Uint8Array)).toEqual(beef);
  });
  it("an authority deploy: the wallet's copy from p color <txid>v0 authority, after the value basket has none", async () => {
    const { f } = stub([]);
    const asked: Array<{ basket: string }> = [];
    const wallet = {
      listOutputs: async (a: { basket: string }) => {
        asked.push(a);
        return a.basket.endsWith(" authority")
          ? { totalOutputs: 1, outputs: [{ outpoint: `${txid}.0`, satoshis: 1, spendable: true }], BEEF: beef }
          : { totalOutputs: 0, outputs: [] };
      },
    } as unknown as WalletInterface;
    const r = await submitDeployToTopic(base, `tm_color_${txid}_0`, wallet, f, f);
    expect(r.via).toBe("wallet");
    expect(asked.map((a) => a.basket)).toEqual([`p color ${txid}v0`, `p color ${txid}v0 authority`]);
  });
  it("neither has it: an error, nothing submitted", async () => {
    const { f, sent } = stub([]);
    const wallet = { listOutputs: async () => ({ totalOutputs: 0, outputs: [] }) } as unknown as WalletInterface;
    await expect(submitDeployToTopic(base, `tm_color_${txid}_0`, wallet, f, f)).rejects.toThrow(/does not hold it/);
    await expect(submitDeployToTopic(base, `tm_color_${txid}_0`, undefined, f, f)).rejects.toThrow(/no wallet/);
    expect(sent.every((s) => s.url.endsWith("/lookup"))).toBe(true);
  });
  it("a register's seeding answered the deploy missing (skein-overlay 0.7.8): the wallet's copy, no lookup, under tm_color and tm_color_<txid>_<vout>", async () => {
    const { f, sent } = stub([]);
    const wallet = {
      listOutputs: async () => ({ totalOutputs: 1, outputs: [{ outpoint: `${txid}.2`, satoshis: 1, spendable: true }], BEEF: beef }),
    } as unknown as WalletInterface;
    expect(await submitWalletDeploy(base, `tm_color_${txid}_2`, wallet, undefined, f)).toEqual({ answer: ADMITTED, via: "wallet", topics: ["tm_color", `tm_color_${txid}_2`] });
    expect(sent.map((x) => x.url)).toEqual([`${base}/submit`]);
    await expect(submitWalletDeploy(base, `tm_color_${txid}_0`, undefined, "missing", f)).rejects.toThrow(/^missing, and no wallet/);
  });
});

describe("the token list (/<app>/color/tokens, a read)", () => {
  it("every page, by plain GET, until a short one; a 1Color deploy's icon a data URL", async () => {
    const urls: string[] = [];
    const row = (i: number) => ({ tokenId: `${txid}_${i}`, topic: `tm_color_${txid}_${i}`, sym: "T", dec: 0, txid, vout: i, ...(i === 0 && { icon: "data:image/png;base64,AQID" }) });
    const f: Fetch = async (u, init) => {
      urls.push(`${init?.method} ${u}`);
      const skip = Number(new URL(u).searchParams.get("skip"));
      return new Response(JSON.stringify(skip === 0 ? Array.from({ length: 100 }, (_, i) => row(i)) : [row(100)]), { status: 200 });
    };
    const list = await listTokens(base, f);
    expect(list).toHaveLength(101);
    expect(list[0]!.icon).toBe("data:image/png;base64,AQID");
    expect(urls).toEqual([`GET ${base}/color/tokens?limit=100&skip=0`, `GET ${base}/color/tokens?limit=100&skip=100`]);
    await expect(listTokens(base, async () => new Response("no", { status: 404 }))).rejects.toThrow(/HTTP 404/);
  });
});
