/**
 * Identifiers on the pages (David, 2026-10-08): "anytime we show a token ID or
 * a transaction ID anywhere in the site ever, it has to be expandable so we
 * can copy the whole thing or needs to have an explicit copy button." `<Id>`
 * shows a txid, a token id, an outpoint or a topic carrying a txid shortened;
 * a click shows it whole, and "copy" copies the whole value. `<Ids>` renders
 * a status line with every id in it as an `<Id>`.
 *
 * Outpoints are written `<txid>.<vout>`; the one underscore form is a token
 * id, `<txid>_<vout>` for every token (`_0` included; BRC-162 "Token
 * identification", David 2026-10-07), not an outpoint (David, 2026-10-08).
 */
import { useState } from "react";

/** Each 64-hex run (a txid) shortened to its first and last 8 characters. */
export function shortId(value: string): string {
  return value.replace(/[0-9a-fA-F]{64}/g, (h) => `${h.slice(0, 8)}…${h.slice(-8)}`);
}

/**
 * The ids in a line of text: a txid (64 hex), with an optional `tm_color_`
 * or `ls_color_` before (a token's topic or lookup, BRC-207) and an optional
 * `.<vout>` / `_<vout>` after (an outpoint, a token id or a token's topic).
 * Other hex (a 66-character key) is left out.
 */
const ID = /(?<![0-9A-Za-z_])(?:(?:tm|ls)_color_)?[0-9a-fA-F]{64}(?:[._](?:0|[1-9]\d*))?(?![0-9A-Za-z])/g;

/** A line split into text and ids, in order. */
export function idParts(text: string): Array<{ id: boolean; text: string }> {
  const out: Array<{ id: boolean; text: string }> = [];
  let at = 0;
  for (const m of text.matchAll(ID)) {
    if (m.index > at) out.push({ id: false, text: text.slice(at, m.index) });
    out.push({ id: true, text: m[0] });
    at = m.index + m[0].length;
  }
  if (at < text.length) out.push({ id: false, text: text.slice(at) });
  return out;
}

/** An id: shortened, whole on a click, and a copy button that copies the whole value. */
export function Id({ value }: { value: string }) {
  const [whole, setWhole] = useState(false);
  const [copied, setCopied] = useState<"" | "copied" | "not copied">("");
  const short = shortId(value);
  const expandable = short !== value;

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied("copied");
    } catch {
      setCopied("not copied");
      setWhole(true);
    }
    setTimeout(() => setCopied(""), 1500);
  }

  return (
    <span className="id">
      <code
        title={expandable ? (whole ? "Click to shorten" : "Click to show it whole") : value}
        className={expandable ? "toggle" : undefined}
        onClick={expandable ? () => setWhole(!whole) : undefined}
      >
        {whole || !expandable ? value : short}
      </code>
      <button type="button" className="copy" onClick={() => void copy()} title={`Copy ${value}`}>{copied || "copy"}</button>
    </span>
  );
}

/** A line of text with each id in it rendered as an `<Id>`. */
export function Ids({ text }: { text: string }) {
  return <>{idParts(text).map((p, i) => (p.id ? <Id key={i} value={p.text} /> : p.text))}</>;
}
