/**
 * The deploy form → @1sat/actions' `deploy1Color` input (BRC-162: symbol,
 * decimals, icon, a fixed supply or an authority deploy), and the names the
 * deploy gives the token. Pure; the page hands the input to the SDK action.
 *
 * The icon is embedded in the deploy (BRC-162 draft bsv-blockchain/BRCs#308:
 * `icon` is the DAG-CBOR array `[mediaType, bytes]`; the pointer forms, an
 * outpoint or an output index, are gone): the page reads an image file and
 * passes `{mediaType, bytes}` (b-open-io/1sat-sdk#92).
 */
import type { Deploy1ColorInput } from "@1sat-actions/1color/deploy.js";

/** BRC-162 amounts are u64. */
export const MAX_AMOUNT = 0xffffffffffffffffn;

export interface DeployForm {
  symbol: string;
  /** Text as typed: an integer 0-18. */
  decimals: string;
  supply: "fixed" | "authority";
  /** Text as typed, in whole units (`decimals` places allowed); fixed supply only. */
  amount: string;
  /** The image file chosen, as read: its media type and bytes; none chosen, undefined. */
  icon?: Icon;
}

/** An image to embed: its media type (the file's) and its bytes. */
export interface Icon {
  mediaType: string;
  bytes: Uint8Array;
}

/** Whole units with up to `decimals` places → base units. */
export function baseUnits(text: string, decimals: number): bigint {
  const t = text.trim().replace(/_/g, "");
  const m = /^(\d+)(?:\.(\d*))?$/.exec(t);
  if (!m) throw new Error("amount: a number, e.g. 1000 or 12.5");
  const frac = m[2] ?? "";
  if (frac.length > decimals) throw new Error(`amount: at most ${decimals} decimal places`);
  return BigInt(m[1]! + frac.padEnd(decimals, "0"));
}

/** The icon as embedded: an image's media type (`image/…`, RFC 6838) and its bytes, not empty. */
export function iconOf(i: Icon): Icon {
  const mt = i.mediaType.trim().toLowerCase();
  if (!/^image\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$/.test(mt)) throw new Error("icon: an image file (its media type image/…)");
  if (i.bytes.length === 0) throw new Error("icon: the file is empty");
  return { mediaType: mt, bytes: i.bytes };
}

/** The SDK action's input. Throws with the field's name on a bad value. */
export function deployInput(f: DeployForm): Deploy1ColorInput {
  const symbol = f.symbol.trim();
  if (!symbol) throw new Error("symbol: required");
  const dec = f.decimals.trim() === "" ? 0 : Number(f.decimals.trim());
  if (!Number.isInteger(dec) || dec < 0 || dec > 18) throw new Error("decimals: an integer 0-18");
  let amount = 0n;
  if (f.supply === "fixed") {
    amount = baseUnits(f.amount, dec);
    if (amount <= 0n) throw new Error("amount: more than 0 for a fixed supply");
    if (amount > MAX_AMOUNT) throw new Error("amount: at most 2^64-1 base units");
  }
  const input: Deploy1ColorInput = { amount: amount.toString(), symbol, decimals: dec };
  if (f.icon) input.icon = iconOf(f.icon);
  return input;
}

/**
 * The names a 1Color deploy gives the token: its id `<txid>_0` (every token
 * is `<txid>_<vout>`, `_0` included; the bare txid is the wire form only:
 * BRC-162 "Token identification", David 2026-10-07), and the overlay topic
 * and lookup root registers, `tm_color_<assetId>` and `ls_color_<assetId>`
 * (BRC-207; David Case, 2026-10-08).
 */
export function namesOf(txid: string): { tokenId: string; topic: string; lookup: string } {
  const t = txid.toLowerCase();
  return { tokenId: `${t}_0`, topic: `tm_color_${t}_0`, lookup: `ls_color_${t}_0` };
}
