/**
 * The tokens this overlay serves: the overlay engine's registered topics
 * and lookup services (skein-overlay 0.6.0 / 0.11.0, docs/OVERLAY.md
 * "Register a topic", "Register a lookup service"), the messages that change
 * them, the answers. Pure; the page sends and reads.
 *
 * A token is two registrations (BRC-207; David Case, 2026-10-08): its topic
 * `tm_color_<assetId>` (judged by color-topic) and its lookup
 * `ls_color_<assetId>` (answered by color-lookup), the asset id
 * `<txid>_<vout>` (`<txid>_0` at output 0). Registered in that order,
 * deregistered in the reverse (`registerToken`, `deregisterToken`).
 *
 * The topic set is the engine's head `<app>/topics`, `{kind: "overlay-topics",
 * topics: [{topic, program}]}`; the lookup set `<app>/lookups`, `{kind:
 * "overlay-lookups", lookups: [{service, program, topics?}]}`. Messages to the
 * app's box `<app>/register` (skein-overlay 0.7.7): `{fn: "register", args:
 * {topic, program: "color-topic", seed?}}`, `{fn: "deregister", args:
 * {topic}}`, `{fn: "registerLookup", args: {service, program:
 * "color-lookup", topics}}`, `{fn: "deregisterLookup", args: {service}}`;
 * the topic a token's `tm_color_<txid>_<vout>` or `tm_color`. A token's register seeds its topic with its deploy
 * (skein-overlay 0.7.8): `seed: [<the deploy txid>]`, judged from what the
 * instance's chain state holds. The step's answer is its result record (its
 * CID on stdout): `{kind: "overlay-result", op, topic, active, changed,
 * seeded?, missing?, untaken?}` or `{kind: "overlay-result", op, error}` for a
 * refusal.
 */

export const DISCOVERY = "tm_color";
/** The role in the app's `programs` that judges a 1Color topic. */
export const PROGRAM = "color-topic";
/** The role in the app's `programs` that answers a token's lookup (`ls_color_<assetId>`). */
export const LOOKUP_PROGRAM = "color-lookup";
/** A token's topic and lookup: the prefix before its asset id (BRC-207). */
export const TOPIC_PREFIX = "tm_color_";
export const LOOKUP_PREFIX = "ls_color_";

export type Call =
  | { fn: "register"; args: { topic: string; program: string; seed?: string[] } }
  | { fn: "deregister"; args: { topic: string } }
  | { fn: "registerLookup"; args: { service: string; program: string; topics: string[] } }
  | { fn: "deregisterLookup"; args: { service: string } };

const TOKEN_TOPIC = /^tm_color_([0-9a-f]{64})_(0|[1-9]\d*)$/;

/**
 * A token's topic as typed: `tm_color_<assetId>`, `tm_color_<txid>_<vout>` for
 * every token (`tm_color_<txid>_0` a token deployed at output 0, any other
 * vout a BRC-161 token deployed there); 64 lowercase hex. The old
 * `tm_<txid>_<vout>` is no topic (no alias).
 */
export function tokenTopicOf(text: string): string {
  const t = text.trim();
  const m = TOKEN_TOPIC.exec(t);
  if (!m || Number(m[2]) > 0xffffffff) {
    throw new Error("a token's topic: tm_color_<txid>_<vout> (64 lowercase hex characters; tm_color_<txid>_0 at output 0)");
  }
  return t;
}

/** The asset id a token's topic names: `tm_color_<txid>_<vout>` → `<txid>_<vout>`. */
export function assetIdOf(topic: string): string {
  return tokenTopicOf(topic).slice(TOPIC_PREFIX.length);
}

/** The deploy txid a token's topic names: `tm_color_<txid>_<vout>` → `<txid>`. */
export function deployTxidOf(topic: string): string {
  return assetIdOf(topic).slice(0, 64);
}

/** A token's lookup service, beside its topic: `tm_color_<assetId>` → `ls_color_<assetId>`. */
export function lookupOf(topic: string): string {
  return LOOKUP_PREFIX + assetIdOf(topic);
}

/** Register a token's topic, judged by color-topic, seeded with its deploy (skein-overlay 0.7.8). */
export function register(topic: string): Call {
  const t = tokenTopicOf(topic);
  return { fn: "register", args: { topic: t, program: PROGRAM, seed: [deployTxidOf(t)] } };
}

/** Register a token's lookup `ls_color_<assetId>`, answered by color-lookup, hearing its topic (skein-overlay 0.11.0). */
export function registerLookup(topic: string): Call {
  const t = tokenTopicOf(topic);
  return { fn: "registerLookup", args: { service: lookupOf(t), program: LOOKUP_PROGRAM, topics: [t] } };
}

/** A token registered: its topic, then its lookup. */
export function registerToken(topic: string): Call[] {
  return [register(topic), registerLookup(topic)];
}

/** Deregister a topic. */
export function deregister(topic: string): Call {
  return { fn: "deregister", args: { topic } };
}

/** A token deregistered: the reverse of `registerToken`, its lookup, then its topic. */
export function deregisterToken(topic: string): Call[] {
  const t = tokenTopicOf(topic);
  return [{ fn: "deregisterLookup", args: { service: lookupOf(t) } }, deregister(t)];
}

/** The discovery topic switched on or off. */
export function discovery(on: boolean): Call {
  return on ? { fn: "register", args: { topic: DISCOVERY, program: PROGRAM } } : deregister(DISCOVERY);
}

export interface Registered {
  topic: string;
  program: string;
}

/** The registered set's record; [] for none (the head not written yet). */
export function registeredOf(record: unknown): Registered[] {
  if (record === undefined) return [];
  const r = record as { kind?: unknown; topics?: unknown };
  const ok = (e: unknown) => typeof (e as Registered)?.topic === "string" && typeof (e as Registered)?.program === "string";
  if (r.kind !== "overlay-topics" || !Array.isArray(r.topics) || !r.topics.every(ok)) {
    throw new Error('the head is not the registered topics ({kind: "overlay-topics", topics: [{topic, program}]})');
  }
  return (r.topics as Registered[]).map(({ topic, program }) => ({ topic, program }));
}

/** The topics of the set that color-topic judges. */
export function topicsOf(record: unknown): string[] {
  return registeredOf(record).filter((e) => e.program === PROGRAM).map((e) => e.topic);
}

/** The registered lookup set's record (`<app>/lookups`): the services color-lookup answers; [] for none. */
export function lookupsOf(record: unknown): string[] {
  if (record === undefined) return [];
  const r = record as { kind?: unknown; lookups?: unknown };
  const ok = (e: unknown) => typeof (e as { service?: unknown })?.service === "string" && typeof (e as { program?: unknown })?.program === "string";
  if (r.kind !== "overlay-lookups" || !Array.isArray(r.lookups) || !r.lookups.every(ok)) {
    throw new Error('the head is not the registered lookups ({kind: "overlay-lookups", lookups: [{service, program, topics?}]})');
  }
  return (r.lookups as Array<{ service: string; program: string }>).filter((e) => e.program === LOOKUP_PROGRAM).map((e) => e.service);
}

/**
 * A register's seeding (skein-overlay 0.7.8): `seeded` the seeds the topic
 * holds now, `missing` the seeds the instance's chain state does not hold,
 * `untaken` the held seeds the topic took nothing of.
 */
export interface Seeding {
  seeded: string[];
  missing: string[];
  untaken: string[];
}

export type Answer = { ok: true; topic: string; active: boolean; seeding?: Seeding } | { ok: false; message: string };
export type LookupAnswer = { ok: true; service: string; active: boolean } | { ok: false; message: string };

const txids = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

/** The step's result record read as the outcome of the call. */
export function answerOf(v: unknown): Answer {
  const r = (v ?? {}) as { kind?: unknown; topic?: unknown; active?: unknown; error?: unknown; seeded?: unknown; missing?: unknown; untaken?: unknown };
  if (r.kind === "overlay-result" && r.error !== undefined) return { ok: false, message: String(r.error) };
  if (r.kind === "overlay-result" && typeof r.topic === "string" && typeof r.active === "boolean") {
    const a: Answer = { ok: true, topic: r.topic, active: r.active };
    if (r.seeded !== undefined || r.missing !== undefined) a.seeding = { seeded: txids(r.seeded), missing: txids(r.missing), untaken: txids(r.untaken) };
    return a;
  }
  return { ok: false, message: `an answer not in the overlay-result shape: ${JSON.stringify(v)}` };
}

/** A registerLookup / deregisterLookup step's result record (skein-overlay 0.11.0): `{service, active}`, or the refusal. */
export function lookupAnswerOf(v: unknown): LookupAnswer {
  const r = (v ?? {}) as { kind?: unknown; service?: unknown; active?: unknown; error?: unknown };
  if (r.kind === "overlay-result" && r.error !== undefined) return { ok: false, message: String(r.error) };
  if (r.kind === "overlay-result" && typeof r.service === "string" && typeof r.active === "boolean") return { ok: true, service: r.service, active: r.active };
  return { ok: false, message: `an answer not in the overlay-result shape: ${JSON.stringify(v)}` };
}

