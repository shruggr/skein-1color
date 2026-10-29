/**
 * The tokens this overlay serves: root's page (the key holding root on the
 * instance, shruggr/skein#143). Reads the overlay engine's registered topics
 * and lookups (the heads `<app>/topics` and `<app>/lookups`, through the
 * explorer, root's read), and changes them by root's messages to the app's
 * box `<app>/register` (skein-overlay 0.7.7+; the route's handler
 * `overlay.register` is gated by root, skein-overlay 0.10.0). A token is two
 * registrations (BRC-207; David Case, 2026-10-08): `register` of its topic
 * `tm_color_<assetId>`, then `registerLookup` of `ls_color_<assetId>`
 * (skein-overlay 0.11.0); deregistering reverses both. Each token shows its
 * symbol and icon from its deploy (the read `/<app>/color/tokens`: a
 * 1Color deploy's embedded image as a data URL).
 * A token's register seeds its topic with the token's deploy (skein-overlay
 * 0.7.8, `seed: [<deploy txid>]`): the engine judges it from what the
 * instance's chain state holds, and the answer says `seeded` or `missing`.
 * Missing (the overlay never held the deploy), the page submits the wallet's
 * copy (src/overlay.ts `submitWalletDeploy`). "Submit deploy to this
 * overlay" submits the deploy on demand (`submitDeployToTopic`: the discovery
 * lookup's, else the wallet's). The lookup goes signed, through the
 * instance's BRC-104 client; the submit is a plain `fetch`, unsigned
 * (shruggr/skein#135).
 *
 * Market and validator are not switches (skein-overlay 0.12.0; David,
 * 2026-10-09: every skein is a market and a validator from install, always):
 * registering a token starts both for it, deregistering stops them. The page
 * says so and offers no switch.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useWallet } from "@1sat/react";
import { mount } from "../shell";
import { Id, Ids } from "../Id";
import { whereOf } from "../where";
import { Instance } from "./instance";
import { appBaseOf, authFetchOf, listTokens, submitDeployToTopic, submitWalletDeploy, type Listed, type Submitted } from "../overlay";
import { DISCOVERY, answerOf, deployTxidOf, deregisterToken, discovery, lookupAnswerOf, lookupOf, lookupsOf, register, registerToken, topicsOf, type Call, type Seeding } from "./list";

const where = whereOf(location.href);

function TokensPage() {
  const { wallet, status } = useWallet();
  const inst = useMemo(() => (wallet && status === "connected" && where ? new Instance(wallet, where.base) : undefined), [wallet, status]);
  const [topics, setTopics] = useState<string[]>();
  const [readErr, setReadErr] = useState("");
  const [busy, setBusy] = useState("");
  const [note, setNote] = useState<{ ok: boolean; text: string }>();
  const [topic, setTopic] = useState("");
  const [lookups, setLookups] = useState<string[]>([]);
  const [listed, setListed] = useState<Map<string, Listed>>(new Map());

  const load = useCallback(async () => {
    if (!inst || !where) return;
    try {
      const set = await inst.head(`${where.app}/topics`);
      setTopics(topicsOf(set));
      setLookups(lookupsOf(await inst.head(`${where.app}/lookups`)));
      setReadErr("");
    }
    catch (e) { setTopics(undefined); setReadErr((e as Error).message); }
    // The deploys' display fields (a read; a page without them still works).
    try { setListed(new Map((await listTokens(appBaseOf(where))).map((t) => [t.topic, t]))); } catch { /* none shown */ }
  }, [inst]);
  useEffect(() => { void load(); }, [load]);

  /** The token's deploy submitted under its topic: from the discovery lookup, or the wallet's copy; `walletOnly` the wallet's. */
  async function submitDeploy(t: string, prefix = "", walletOnly = false): Promise<{ ok: boolean; text: string }> {
    if (!where || !inst) return { ok: false, text: where ? "no wallet connected" : "no app" };
    try {
      const f = authFetchOf(inst.box);
      const r: Submitted = walletOnly
        ? await submitWalletDeploy(appBaseOf(where), t, wallet ?? undefined, "the overlay's chain state does not hold the deploy")
        : await submitDeployToTopic(appBaseOf(where), t, wallet ?? undefined, f);
      const from = r.via === "lookup" ? "from the discovery lookup" : walletOnly ? "from your wallet" : "from your wallet (the discovery lookup had none)";
      return { ok: true, text: `${prefix}deploy submitted ${from} under ${r.topics.join(", ")}: ${r.answer}.` };
    } catch (e) { return { ok: false, text: `${prefix}deploy not submitted: ${(e as Error).message}` }; }
  }

  /** What a token's register seeded (skein-overlay 0.7.8): the deploy seeded, or missing (→ the wallet's copy), or held but not taken. */
  async function afterSeeding(topic: string, s: Seeding | undefined): Promise<{ ok: boolean; text: string }> {
    const deploy = deployTxidOf(topic);
    const seeded = `seeded: ${s?.seeded.length ? s.seeded.join(", ") : "none"}; missing: ${s?.missing.length ? s.missing.join(", ") : "none"}`;
    if (s?.seeded.includes(deploy)) return { ok: true, text: `${topic}: registered; the deploy was seeded from the overlay's chain state (${seeded}).` };
    if (s?.untaken.includes(deploy)) return { ok: false, text: `${topic}: registered; the overlay holds the deploy, but the topic took nothing of it (${seeded}).` };
    // Missing (or an engine before 0.7.8, which answers no seeding): the wallet's copy.
    setBusy(`${topic}:submit`);
    return submitDeploy(topic, `${topic}: registered (${s ? seeded : "no seeding in the answer"}); `, true);
  }

  /**
   * Root's calls, in order, each answered before the next: a token's register (its topic, seeded,
   * then its lookup), its deregister (its lookup, then its topic), or one call (the discovery switch).
   * The first refusal stops the rest.
   */
  async function run(label: string, cs: Call[]) {
    if (!inst || !where) return;
    setBusy(label); setNote(undefined);
    const said: string[] = [];
    let ok = true;
    let seeded: { topic: string; seeding?: Seeding } | undefined;
    try {
      for (const c of cs) {
        const v = await inst.call(`${where.app}/register`, c);
        if (c.fn === "registerLookup" || c.fn === "deregisterLookup") {
          const a = lookupAnswerOf(v);
          if (!a.ok) { ok = false; said.push(a.message); break; }
          said.push(`${a.service}: ${a.active ? "registered" : "not registered"}`);
          continue;
        }
        const a = answerOf(v);
        if (!a.ok) { ok = false; said.push(a.message); break; }
        if (a.active && c.fn === "register" && a.topic !== DISCOVERY) seeded = { topic: a.topic, seeding: a.seeding };
        else said.push(`${a.topic}: ${a.active ? "registered" : "not registered"}`);
      }
    } catch (e) { ok = false; said.push((e as Error).message); }
    if (seeded) {
      const s = await afterSeeding(seeded.topic, seeded.seeding);
      setNote({ ok: ok && s.ok, text: [s.text, ...said].join(" ") });
    } else setNote({ ok, text: said.join("; ") });
    setBusy("");
    await load();
  }

  async function resubmit(t: string) {
    setBusy(`submit:${t}`); setNote(undefined);
    setNote(await submitDeploy(t, `${t}: `));
    setBusy("");
  }

  if (!where) return <p className="bad">This page is served at <code>/&lt;app&gt;/color/tokens/</code>; its URL names no app.</p>;
  let idProblem = "";
  try { register(topic); } catch (e) { idProblem = (e as Error).message; }
  const tokenTopics = (topics ?? []).filter((t) => t !== DISCOVERY);
  const discoveryOn = topics?.includes(DISCOVERY) ?? false;

  return (
    <>
      <h1>Tokens on this overlay</h1>
      <p className="mut small">The overlay serves only the tokens registered with it, each a topic <code>tm_color_&lt;assetId&gt;</code> and its lookup <code>ls_color_&lt;assetId&gt;</code> (BRC-207), the asset id the token's id: <code>&lt;txid&gt;_0</code> for a token deployed at output 0, <code>&lt;txid&gt;_&lt;vout&gt;</code> for a BRC-161 token at another output. The deploy page shows the topic of a new token. Changing it is root's (the key that claimed the instance, or one root granted): messages from your wallet to the box <code>{where.app}/register</code> of <code>{where.base}</code>.</p>
      {status !== "connected" && <p className="mut">Connect the wallet holding root on this skein.</p>}
      {readErr && <p className="status bad">The list: <Ids text={readErr} /></p>}
      {inst && (
        <>
          <div className="card">
            <h2>Register a topic</h2>
            <form className="row" onSubmit={(e) => { e.preventDefault(); if (!idProblem) void run("register", registerToken(topic)); }}>
              <input type="text" value={topic} onChange={(e) => setTopic(e.target.value)} placeholder="tm_color_<txid>_<vout>" />
              <button type="submit" className="go" disabled={!!busy || !!idProblem}>{busy === "register" ? "Registering…" : "Register"}</button>
            </form>
            {topic && idProblem && <p className="mut small">{idProblem}</p>}
          </div>
          <div className="card">
            <h2>Registered tokens</h2>
            {topics === undefined ? <p className="mut small">{readErr ? "Not read." : "Reading…"}</p> : tokenTopics.length === 0 ? <p className="mut small">None.</p> : (
              <table>
                <thead><tr><th></th><th>topic</th><th>lookup</th><th></th></tr></thead>
                <tbody>
                  {tokenTopics.map((t) => (
                    <tr key={t}>
                      <td><TokenIcon t={listed.get(t)} /></td>
                      <td><Id value={t} /></td>
                      <td>{lookups.includes(lookupOf(t)) ? <Id value={lookupOf(t)} /> : <span className="mut small" title="Register the token again to register its lookup">not registered</span>}</td>
                      <td>
                        <button type="button" disabled={!!busy} onClick={() => void resubmit(t)} title="The token's deploy, from the discovery lookup or your wallet, submitted under this topic">{busy === `submit:${t}` ? "Submitting…" : "Submit deploy to this overlay"}</button>{" "}
                        <button type="button" disabled={!!busy} onClick={() => void run(t, deregisterToken(t))}>{busy === t ? "Deregistering…" : "Deregister"}</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
          <div className="card">
            <h2>Discovery</h2>
            <label className="inline">
              <input type="checkbox" checked={discoveryOn} disabled={!!busy || topics === undefined} onChange={(e) => void run("discovery", [discovery(e.target.checked)])} />
              Serve <code>{DISCOVERY}</code>: every token's deploy output, so the metadata each token was deployed with can be found (lookup <code>ls_color</code>: BRC-207 <code>color-admission</code> of a deploy over <code>tm_color</code>).
            </label>
          </div>
          <p className="mut small">This overlay is a market and a validator for every registered token, always: registering a token starts both (the beats on <code>tm_color_&lt;assetId&gt;-live</code>), deregistering stops them.</p>
          {busy && <p className="status wait">{busy.startsWith("submit:") || busy.endsWith(":submit") ? "Submitting the deploy…" : "Sent; waiting for the answer…"}</p>}
          {note && <p className={`status ${note.ok ? "ok" : "bad"}`}><Ids text={note.text} /></p>}
        </>
      )}
    </>
  );
}

/** A token's icon and symbol from its deploy: a 1Color deploy's embedded image (a data URL); none otherwise. */
function TokenIcon({ t }: { t?: Listed }) {
  if (!t) return null;
  const img = t.icon?.startsWith("data:") ? t.icon : undefined;
  return <span className="small">{img && <img src={img} alt="" width={20} height={20} style={{ verticalAlign: "middle", marginRight: 4 }} />}{t.sym}</span>;
}

mount("Tokens", <TokensPage />);
