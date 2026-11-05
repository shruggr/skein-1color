//! color-lookup: the 1Color (BRC-162) lookup program (shruggr/skein#120
//! item 3). It indexes the outputs the 1Color topics admit, through the
//! skein-overlay lookup hooks (once per admitted transaction and topic,
//! skein-overlay 0.11.0), in one index, the head `<app>/ls_color`
//! (`spec.index`), whatever name it is called as:
//!
//!   ls_color               the queries below; over the discovery topic tm_color, BRC-207's
//!                            two queries with `topic: "tm_color"` (0.12.1)
//!   ls_color_<assetId>     a token's BRC-207 lookup beside its topic tm_color_<assetId>
//!
//! A lookup is this program under a name; the name pairs it with the topics
//! that feed it, and the queries are the same under every name (David,
//! 2026-10-29: "There should be no difference between what these things are
//! looking up. The only difference is which topic the instance has got access
//! to."). 0.11.x's discovery lookup `ls_color_deploys` is gone, no alias: a
//! deploy is looked up under the name over `tm_color`, `ls_color`, by BRC-207's
//! `color-admission` query (David, 2026-10-29), its outpoint the token id
//! `<txid>_<vout>` read as `<txid>.<vout>`.
//!
//! Three queries in the shapes of the ts-stack
//! BRC-162 lookup (Deggen's, ts-stack packages/overlays/topics):
//!
//!   {tokenId, limit?, skip?}             the token's unspent value outputs (a supply-holding deploy among them), in outpoint order
//!   {authoritiesTokenId, limit?, skip?}  the token's unspent authority outputs (an authority-only deploy among them), in outpoint order
//!   {txid, outputIndex}                  the value or authority output at that outpoint, if unspent
//!
//! The first of `authoritiesTokenId`, `tokenId` present answers; else the
//! outpoint. `limit` is 1 to 100 (default 100), `skip` 0 to 100000 (default
//! 0). Any other key, or a value out of shape, is refused. A token id is
//! taken as `<txid>`, `<txid>_<vout>` or `<txid>.<vout>` (name.zig
//! `tokenIdOfString`): `<txid>` and `<txid>_0` are the token deployed at
//! output 0 (either form), a non-zero vout the deploy outpoint of a BRC-161
//! one. A token id is written `<txid>_<vout>` for every token, `_0` included
//! (BRC-162 "Token identification"; David, 2026-10-07): the bare txid is the
//! wire form only. Answers are output-lists (outpoints, no token id strings); the engine
//! builds each output's BEEF from the chain state.
//!
//! The maps (`tok` = the token's deploy txid in display order ‖ vout, u32 BE;
//! `op` = an outpoint's txid in display order ‖ vout, u32 BE, so key order is
//! outpoint order: txid hex, then index):
//!
//!   values       tok ‖ op → null                 unspent value outputs (and supply-holding deploys)
//!   authorities  tok ‖ op → null                 unspent authority outputs (and authority-only deploys)
//!   outputs      op → kind (0 value, 1 authority) ‖ tok [‖ spending txid, internal order]
//!   admitted     tok ‖ op → null                 every output the token's topic validly admitted
//!                                                (BRC-207: kept once spent, dropped on rejection)
//!
//! `admitted` classifies each admitted output by the BSV-21 rules for the
//! topic's token (bsv21.zig `tokenOf`) by what it holds: a value (transfer, mint,
//! or a deploy that carries the supply) goes in `values`, an authority (an authority
//! output, or an authority-only deploy) in `authorities`, a BRC-161 burn in neither
//! (0.15.1: until 0.15.0 every deploy was filed as an authority, an error). `spent` takes the output out of its index and records its
//! spender; `rejected` drops the transaction's outputs and gives back the
//! ones it had spent. A hook for a topic that is not a token's does nothing.
//!
//! The BALANCE TABLE (0.15.0, D4: agent-env plans/history-api-2026-11-05.md), per token, over the
//! unspent value outputs (`values`) whose locking script is P2PKH (a binary output's lock after the
//! prefix; a JSON output's script around the envelope: the P2PKH on one side, nothing on the other);
//! other outputs (pools, contracts) are not counted:
//!
//!   balances     tok ‖ pkh (20) → amount (u64 BE, 8 bytes)        the address's balance, > 0
//!   byBalance    tok ‖ (2^64 − 1 − amount) (u64 BE) ‖ pkh → null  largest first
//!   holders      tok → count (u64 BE, 8 bytes)                     the addresses with a balance
//!
//! kept exactly as `values` is: an output entering `values` (admitted, or given back by a
//! rejection) credits its address, one leaving it (spent, or its transaction rejected) debits it;
//! `byBalance` re-keyed on every change; a zero balance leaves both. No backfill: outputs indexed
//! before 0.15.0 are not counted.
//!
//! The discovery topic `tm_color` feeds (by the topic, as every hook) the map
//!
//!   deploys      tok → null                       every admitted deploy (a token id is its deploy outpoint)
//!
//! `admitted` adds each valid deploy output (token.zig `deployOf`), `spent`
//! does nothing (a registry), `rejected` removes the transaction's deploys;
//! under `ls_color` BRC-207's query with `topic: "tm_color"` and the token's
//! `assetId` answers, of the queried outpoints, the asset's deploy if the
//! topic admitted it (`color-admission`: spent or not, a registry;
//! `color-spendability`: and unspent by the chain state). The three queries
//! above read the token topics' maps only.
//!
//! **BRC-207** (David Case, 2026-10-08): called as `ls_color_<assetId>`, it
//! answers
//!
//!   {type: "color-spendability" | "color-admission", version: 1, assetId,
//!    topic: "tm_color_<assetId>", outpoints: ["<txid>.<vout>", …]}
//!
//! validated strictly (these five keys and no other; version 1; assetId and
//! topic exactly the service name's; each outpoint canonical BRC-36 dot form,
//! lowercase, the index without leading zeros), as an output-list of exactly
//! the queried outpoints, each once, in the query's order: spendability —
//! those in `admitted` for the asset and unspent (the chain state names no
//! spender, as the engine's `inTopic` reads it); admission — those in
//! `admitted`, spent or not. An empty list is a valid "no". Any other query
//! there is refused.
const std = @import("std");
const c = @import("chain");
const lookup = @import("lookup");
const color = @import("1color");

const bsv21 = color.bsv21;
const token = color.token;

const Value = c.cbor.Value;
const Allocator = std.mem.Allocator;
const Service = lookup.Service;
const eql = std.mem.eql;

pub const service_name = "ls_color";
/// The index every name of the program reads and writes (skein-overlay 0.11.0): `<app>/ls_color`.
pub const index_name = service_name;
/// The discovery topic (BRC-207 "Deployment discovery"): it feeds the map `deploys`.
const deploys_topic = color.name.deploys_topic;

pub const spec: lookup.Spec = .{
    .maps = &.{ "values", "authorities", "outputs", "deploys", "admitted", "balances", "byBalance", "holders" },
    .index = index_name,
    .answer = answer,
    .admitted = admitted,
    .spent = spent,
    .rejected = rejected,
};

pub const max_limit = 100;
pub const max_skip = 100_000;

const Kind = enum(u8) { value = 0, authority = 1 };

fn display(txid: [32]u8) [32]u8 {
    var r = txid;
    std.mem.reverse(u8, &r);
    return r;
}

/// A token's key: its deploy txid in display order ‖ vout (BE).
fn tokKey(id: bsv21.TokenId) [36]u8 {
    return display(id.txid) ++ c.store.be32(id.vout);
}

/// An outpoint's key: its txid in display order ‖ vout (BE).
fn opKey(txid: [32]u8, vout: u32) [36]u8 {
    return display(txid) ++ c.store.be32(vout);
}

fn opOf(key: []const u8) lookup.Output {
    return .{ .txid = display(key[0..32].*), .vout = std.mem.readInt(u32, key[32..36], .big) };
}

fn indexName(k: Kind) []const u8 {
    return switch (k) {
        .value => "values",
        .authority => "authorities",
    };
}

fn cat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

/// The kind of output `vout` of `tx` is for token `id`, or null (not its, or a BRC-161 burn).
fn kindOf(a: Allocator, id: bsv21.TokenId, tx: lookup.Tx, vout: u32) !?Kind {
    if (vout >= tx.tx.outputs.len) return error.BadArgs;
    const t = (try bsv21.tokenOf(a, id, tx.txid, vout, tx.tx.outputs[vout].locking_script.bytes)) orelse return null;
    // By what it holds (0.15.1): a deploy carrying the supply is a value output, an authority-only one an authority.
    return switch (t.role) {
        .deploy => if (t.authority or t.amount == 0) .authority else .value,
        .authority => .authority,
        .value => .value,
        .burn => null,
    };
}

// ---------------------------------------------------------------- the balance table (0.15.0)

/// The key hash of a P2PKH lock (`76 a9 14 <20> 88 ac`), or null.
fn p2pkhOf(lock: []const u8) ?[20]u8 {
    if (lock.len != 25 or lock[0] != 0x76 or lock[1] != 0xa9 or lock[2] != 0x14 or lock[23] != 0x88 or lock[24] != 0xac) return null;
    return lock[3..23].*;
}

/// What a value output of token `id` credits: its address's key hash and its amount, when its lock is
/// P2PKH (binary: the lock after the prefix; JSON: the script around the envelope, P2PKH on one side
/// and nothing on the other); null for any other output.
pub fn holdingOf(a: Allocator, id: bsv21.TokenId, txid: [32]u8, vout: u32, script: []const u8) !?struct { pkh: [20]u8, amount: u64 } {
    const t = (try bsv21.tokenOf(a, id, txid, vout, script)) orelse return null;
    // A value output as `kindOf` files it (0.15.1: a supply-holding deploy is one).
    if (t.amount == 0 or t.authority or !(t.role == .value or t.role == .deploy)) return null;
    const pkh = switch (t.form) {
        .binary => p2pkhOf(t.binary.?.lock),
        .json => blk: {
            const j = t.json.?;
            if (j.prefix.len == 0) break :blk p2pkhOf(j.suffix);
            if (j.suffix.len == 0) break :blk p2pkhOf(j.prefix);
            break :blk null;
        },
    } orelse return null;
    return .{ .pkh = pkh, .amount = t.amount };
}

fn be64(n: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n, .big);
    return b;
}

fn u64Of(v: ?c.store.MValue) !u64 {
    const x = v orelse return 0;
    if (x != .bytes or x.bytes.len != 8) return error.BadIndex;
    return std.mem.readInt(u64, x.bytes[0..8], .big);
}

/// `tk`'s address `pkh` gains (`credit`) or loses `amount`: `balances` set or dropped at zero,
/// `byBalance` re-keyed, `holders` counted.
fn adjust(a: Allocator, svc: *Service, tk: []const u8, pkh: [20]u8, amount: u64, credit: bool) !void {
    const bk = try cat(a, &.{ tk, &pkh });
    const old = try u64Of(try svc.map("balances").get(bk));
    const new = if (credit) std.math.add(u64, old, amount) catch std.math.maxInt(u64) else old -| amount;
    if (old == new) return;
    if (old > 0) _ = try svc.map("byBalance").remove(try cat(a, &.{ tk, &be64(std.math.maxInt(u64) - old), &pkh }));
    if (new > 0) {
        try svc.map("balances").put(bk, .{ .bytes = try a.dupe(u8, &be64(new)) });
        try svc.map("byBalance").add(try cat(a, &.{ tk, &be64(std.math.maxInt(u64) - new), &pkh }));
    } else _ = try svc.map("balances").remove(bk);
    if ((old == 0) != (new == 0)) {
        const n = try u64Of(try svc.map("holders").get(tk));
        const m = if (new > 0) n + 1 else n -| 1;
        if (m == 0) _ = try svc.map("holders").remove(tk) else try svc.map("holders").put(tk, .{ .bytes = try a.dupe(u8, &be64(m)) });
    }
}

/// The output `vout` of `t` (txid `txid`) entering (`credit`) or leaving `values`: its holding, if any, adjusted.
fn holdingMoved(a: Allocator, svc: *Service, id: bsv21.TokenId, txid: [32]u8, t: c.bsvz.transaction.Transaction, vout: u32, credit: bool) !void {
    if (vout >= t.outputs.len) return;
    const h = (try holdingOf(a, id, txid, vout, t.outputs[vout].locking_script.bytes)) orelse return;
    try adjust(a, svc, &tokKey(id), h.pkh, h.amount, credit);
}

/// The same, for an output read from the store by its txid (a spent or given-back previous coin).
fn heldMoved(a: Allocator, svc: *Service, id: bsv21.TokenId, txid: [32]u8, vout: u32, credit: bool) !void {
    const raw = svc.store.tryGet(a, &c.store.hashCid(.tx, txid)) orelse return;
    const t = c.bsvz.transaction.Transaction.parse(a, raw) catch return;
    try holdingMoved(a, svc, id, txid, t, vout, credit);
}

// The hooks come once per admitted transaction and topic, under whichever of the program's names
// listens first (skein-overlay 0.11.0): they go by the topic, never by the name.

fn admitted(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx, outputs_to_admit: []const u32, _: []const u32) anyerror!void {
    if (eql(u8, topic, deploys_topic)) {
        for (outputs_to_admit) |vout| {
            if (vout >= tx.tx.outputs.len) return error.BadArgs;
            const id = (try token.deployOf(a, tx.txid, vout, tx.tx.outputs[vout].locking_script.bytes)) orelse continue;
            try svc.map("deploys").add(&tokKey(id));
        }
        return;
    }
    const id = token.tokenIdOf(topic) orelse return;
    const tk = tokKey(id);
    for (outputs_to_admit) |vout| {
        if (vout >= tx.tx.outputs.len) return error.BadArgs;
        try svc.map("admitted").add(try cat(a, &.{ &tk, &opKey(tx.txid, vout) }));
        const k = (try kindOf(a, id, tx, vout)) orelse continue;
        const op = opKey(tx.txid, vout);
        try svc.map("outputs").put(&op, .{ .bytes = try cat(a, &.{ &.{@intFromEnum(k)}, &tk }) });
        const ik = try cat(a, &.{ &tk, &op });
        // 0.15.0: an output new to `values` credits its holding (a dupe hook call credits nothing).
        if (k == .value and !(try svc.map("values").has(ik))) try holdingMoved(a, svc, id, tx.txid, tx.tx, vout, true);
        try svc.map(indexName(k)).add(ik);
    }
}

/// An `outputs` entry: its kind, its token key, its spender if spent.
const Entry = struct { kind: Kind, tok: []const u8, spender: ?[]const u8 };

fn entryOf(v: c.store.MValue) !Entry {
    if (v != .bytes or (v.bytes.len != 37 and v.bytes.len != 69) or v.bytes[0] > 1) return error.BadIndex;
    return .{ .kind = @enumFromInt(v.bytes[0]), .tok = v.bytes[1..37], .spender = if (v.bytes.len == 69) v.bytes[37..69] else null };
}

fn spent(a: Allocator, svc: *Service, topic: []const u8, outpoint: lookup.Outpoint, spending: lookup.Tx) anyerror!void {
    if (eql(u8, topic, deploys_topic)) return; // a registry: a deploy stays listed once spent
    const id = token.tokenIdOf(topic) orelse return;
    const op = opKey(outpoint.txid, outpoint.vout);
    const v = (try svc.map("outputs").get(&op)) orelse return; // not one it indexed
    const e = try entryOf(v);
    if (e.spender != null) return;
    if (try svc.map(indexName(e.kind)).remove(try cat(a, &.{ e.tok, &op })) and e.kind == .value)
        try heldMoved(a, svc, id, outpoint.txid, outpoint.vout, false);
    try svc.map("outputs").put(&op, .{ .bytes = try cat(a, &.{ v.bytes, &spending.txid }) });
}

fn rejected(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx) anyerror!void {
    if (eql(u8, topic, deploys_topic)) {
        for (tx.tx.outputs, 0..) |o, vout| {
            const id = (try token.deployOf(a, tx.txid, @intCast(vout), o.locking_script.bytes)) orelse continue;
            _ = try svc.map("deploys").remove(&tokKey(id));
        }
        return;
    }
    const id = token.tokenIdOf(topic) orelse return;
    // Its outputs vanish: never validly admitted (BRC-207 admission).
    for (0..tx.tx.outputs.len) |vout| _ = try svc.map("admitted").remove(try cat(a, &.{ &tokKey(id), &opKey(tx.txid, @intCast(vout)) }));
    for (0..tx.tx.outputs.len) |vout| {
        const op = opKey(tx.txid, @intCast(vout));
        const v = (try svc.map("outputs").get(&op)) orelse continue;
        const e = try entryOf(v);
        if (try svc.map(indexName(e.kind)).remove(try cat(a, &.{ e.tok, &op })) and e.kind == .value)
            try holdingMoved(a, svc, id, tx.txid, tx.tx, @intCast(vout), false);
        _ = try svc.map("outputs").remove(&op);
    }
    // What it spent is unspent again.
    for (tx.tx.inputs) |in| {
        const op = opKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index);
        const v = (try svc.map("outputs").get(&op)) orelse continue;
        const e = try entryOf(v);
        const by = e.spender orelse continue;
        if (!eql(u8, by, &tx.txid)) continue;
        try svc.map("outputs").put(&op, .{ .bytes = try a.dupe(u8, v.bytes[0..37]) });
        const ik = try cat(a, &.{ e.tok, &op });
        if (e.kind == .value and !(try svc.map("values").has(ik))) try heldMoved(a, svc, id, in.previous_outpoint.txid.bytes, in.previous_outpoint.index, true);
        try svc.map(indexName(e.kind)).add(ik);
    }
}

const allowed = [_][]const u8{ "tokenId", "authoritiesTokenId", "txid", "outputIndex", "limit", "skip" };

/// An integer field in [lo, hi], `default` when absent.
fn intField(q: Value, key: []const u8, default: u64, lo: u64, hi: u64) !u64 {
    const v = q.get(key) orelse return default;
    if (v != .uint or v.uint < lo or v.uint > hi) return error.BadQuery;
    return v.uint;
}

fn tokenField(q: Value, key: []const u8) !?bsv21.TokenId {
    const v = q.get(key) orelse return null;
    if (v != .text) return error.BadQuery;
    return token.tokenIdOfString(v.text) orelse error.BadQuery;
}

/// The query, checked: every key one of the six, every value its shape.
pub const Query = union(enum) {
    values: struct { id: bsv21.TokenId, limit: u64, skip: u64 },
    authorities: struct { id: bsv21.TokenId, limit: u64, skip: u64 },
    outpoint: lookup.Output,
};

pub fn parseQuery(q: Value) !Query {
    if (q != .map) return error.BadQuery;
    for (q.map) |e| {
        for (allowed) |k| {
            if (eql(u8, e.key, k)) break;
        } else return error.BadQuery;
    }
    const auth = try tokenField(q, "authoritiesTokenId");
    const tok = try tokenField(q, "tokenId");
    const limit = try intField(q, "limit", max_limit, 1, max_limit);
    const skip = try intField(q, "skip", 0, 0, max_skip);
    var txid: ?[32]u8 = null;
    if (q.get("txid")) |t| {
        if (t != .text or t.text.len != 64) return error.BadQuery;
        txid = c.header.fromHex(t.text) catch return error.BadQuery;
    }
    const vout: ?u64 = if (q.get("outputIndex")) |_| try intField(q, "outputIndex", 0, 0, std.math.maxInt(u32)) else null;
    if (auth) |id| return .{ .authorities = .{ .id = id, .limit = limit, .skip = skip } };
    if (tok) |id| return .{ .values = .{ .id = id, .limit = limit, .skip = skip } };
    if (txid != null and vout != null) return .{ .outpoint = .{ .txid = txid.?, .vout = @intCast(vout.?) } };
    return error.UnsupportedQuery;
}

fn page(a: Allocator, svc: *Service, index: []const u8, id: bsv21.TokenId, limit: u64, skip: u64) ![]const lookup.Output {
    const tk = tokKey(id);
    const all = try svc.map(index).prefixed(&tk);
    const from: usize = @intCast(skip);
    if (from >= all.len) return &.{};
    const to = @min(all.len, from + @as(usize, @intCast(limit)));
    const out = try a.alloc(lookup.Output, to - from);
    for (all[from..to], out) |kv, *o| {
        if (kv.key.len != 72) return error.BadIndex;
        o.* = opOf(kv.key[36..]);
    }
    return out;
}

// ---------------------------------------------------------------- BRC-207 (ls_color_<assetId>)

/// The two BRC-207 queries.
pub const Brc207Type = enum { spendability, admission };

/// A BRC-207 query, checked against the service it was sent to: its type and the queried
/// outpoints, each once, in the query's order.
pub const Brc207 = struct {
    kind: Brc207Type,
    id: bsv21.TokenId,
    outpoints: []const lookup.Output,
    /// Asked of `ls_color` with `topic: "tm_color"` (0.12.1): answered from the discovery topic's deploys.
    discovery: bool = false,
};

const brc207_keys = [_][]const u8{ "type", "version", "assetId", "topic", "outpoints" };

/// A canonical BRC-36 outpoint, `<txid>.<vout>`: 64 lowercase hex characters in display order, a
/// dot, the output index in decimal without leading zeros, at most 2^32 - 1. Null for anything else.
pub fn outpointOfDot(t: []const u8) ?lookup.Output {
    if (t.len < 66 or t[64] != '.') return null;
    const v = t[65..];
    if (v.len > 1 and v[0] == '0') return null;
    for (v) |ch| if (!std.ascii.isDigit(ch)) return null;
    const vout = std.fmt.parseInt(u32, v, 10) catch return null;
    const id = color.name.idOfHex(t[0..64]) orelse return null;
    return .{ .txid = id, .vout = vout };
}

/// A BRC-207 query sent to `service` (`ls_color_<assetId>`), validated strictly: exactly the keys
/// type, version, assetId, topic, outpoints; `type` "color-spendability" or "color-admission";
/// `version` 1; `assetId` and `topic` the service's own (`<assetId>`, `tm_color_<assetId>`);
/// `outpoints` a list of canonical `<txid>.<vout>`. Anything else: error.BadQuery.
pub fn parse207(a: Allocator, service: []const u8, q: Value) !Brc207 {
    // `ls_color` (0.12.1): the discovery topic's form, `topic: "tm_color"`, `assetId` any token's.
    const discovery = eql(u8, service, service_name);
    const sid = if (discovery) blk: {
        const t = (if (q == .map) q.getText("assetId") else null) orelse return error.BadQuery;
        const id = color.name.tokenIdOfString(t) orelse return error.BadQuery;
        break :blk id;
    } else color.name.tokenIdOfLookup(service) orelse return error.UnknownService;
    if (q != .map or q.map.len != brc207_keys.len) return error.BadQuery;
    for (q.map) |e| {
        for (brc207_keys) |k| {
            if (eql(u8, e.key, k)) break;
        } else return error.BadQuery;
    }
    const t = q.getText("type") orelse return error.BadQuery;
    const kind: Brc207Type = if (eql(u8, t, "color-spendability")) .spendability else if (eql(u8, t, "color-admission")) .admission else return error.BadQuery;
    const ver = q.get("version") orelse return error.BadQuery;
    if (ver != .uint or ver.uint != 1) return error.BadQuery;
    var ib: [color.name.max_suffix_len]u8 = undefined;
    var tb: [color.name.max_topic_len]u8 = undefined;
    if (!eql(u8, q.getText("assetId") orelse return error.BadQuery, color.name.tokenIdText(&ib, sid))) return error.BadQuery;
    const want_topic = if (discovery) deploys_topic else color.name.topicName(&tb, sid);
    if (!eql(u8, q.getText("topic") orelse return error.BadQuery, want_topic)) return error.BadQuery;
    const ops = q.getArray("outpoints") orelse return error.BadQuery;
    var out: std.ArrayList(lookup.Output) = .empty;
    outer: for (ops) |o| {
        if (o != .text) return error.BadQuery;
        const op = outpointOfDot(o.text) orelse return error.BadQuery;
        for (out.items) |x| if (x.vout == op.vout and eql(u8, &x.txid, &op.txid)) continue :outer;
        try out.append(a, op);
    }
    const id: bsv21.TokenId = .{ .txid = sid.txid, .vout = sid.vout, .kind = if (sid.kind == .native) .native else .legacy };
    return .{ .kind = kind, .id = id, .outpoints = out.items, .discovery = discovery };
}

/// A BRC-207 answer: of the queried outpoints, those the asset's topic validly admitted (`admitted`)
/// and, for spendability, that the chain state names no spender for (as the engine's `inTopic`).
pub fn answer207(a: Allocator, svc: *Service, ch: *lookup.Chain, q: Brc207) ![]const lookup.Output {
    const tk = tokKey(q.id);
    var out: std.ArrayList(lookup.Output) = .empty;
    for (q.outpoints) |o| {
        const op = opKey(o.txid, o.vout);
        if (q.discovery) {
            // The discovery topic admits a token's deploy output, at the token id's outpoint.
            if (!eql(u8, &op, &tk) or !(try svc.map("deploys").has(&tk))) continue;
        } else if (!(try svc.map("admitted").has(try cat(a, &.{ &tk, &op })))) continue;
        if (q.kind == .spendability and (try ch.spentBy(o.txid, o.vout)) != null) continue;
        try out.append(a, o);
    }
    return out.items;
}

pub fn answer(a: Allocator, svc: *Service, ch: *lookup.Chain, query: Value) anyerror!lookup.Answer {
    if (color.name.tokenIdOfLookup(svc.name) != null) return .{ .output_list = try answer207(a, svc, ch, try parse207(a, svc.name, query)) };
    if (!eql(u8, svc.name, service_name)) return error.UnknownService;
    // BRC-207's query over the discovery topic (0.12.1: it carries a `type`).
    if (query == .map and query.get("type") != null) return .{ .output_list = try answer207(a, svc, ch, try parse207(a, svc.name, query)) };
    switch (try parseQuery(query)) {
        .values => |p| return .{ .output_list = try page(a, svc, "values", p.id, p.limit, p.skip) },
        .authorities => |p| return .{ .output_list = try page(a, svc, "authorities", p.id, p.limit, p.skip) },
        .outpoint => |o| {
            const v = (try svc.map("outputs").get(&opKey(o.txid, o.vout))) orelse return .{ .output_list = &.{} };
            if ((try entryOf(v)).spender != null) return .{ .output_list = &.{} };
            return .{ .output_list = try a.dupe(lookup.Output, &.{o}) };
        },
    }
}

pub fn metadata(a: Allocator, service: []const u8) anyerror!lookup.Metadata {
    if (color.name.tokenIdOfLookup(service)) |id| {
        var tb: [color.name.max_suffix_len]u8 = undefined;
        return .{
            .short_description = try std.fmt.allocPrint(a, "1Color token {s} (BRC-207): color-spendability and color-admission over its topic tm_color_{s}.", .{ color.name.tokenIdText(&tb, id), color.name.tokenIdText(&tb, id) }),
            .version = version,
            .information_url = "https://github.com/shruggr/skein-1color",
        };
    }
    return .{
        .short_description = "1Color (BRC-162; BRC-207) token outputs: a token's unspent value outputs, its authority outputs, one output by outpoint; over the discovery topic tm_color, BRC-207's color-admission and color-spendability of a token's deploy.",
        .version = version,
        .information_url = "https://github.com/shruggr/skein-1color",
    };
}

pub const version = "0.5.1";

pub fn documentation(_: Allocator, service: []const u8) anyerror![]const u8 {
    if (color.name.tokenIdOfLookup(service) != null) return
    \\# 1Color token lookup service (ls_color_<assetId>)
    \\
    \\A token's BRC-207 lookup, beside its topic `tm_color_<assetId>`; `<assetId>` is the token id
    \\`<txid>_<vout>` (`<txid>_0` at output 0).
    \\
    \\## Queries
    \\
    \\```json
    \\{"type": "color-spendability", "version": 1, "assetId": "<assetId>",
    \\ "topic": "tm_color_<assetId>", "outpoints": ["<txid>.<vout>"]}
    \\```
    \\
    \\- `color-spendability`: of the queried outpoints, exactly those currently admitted to the
    \\  topic and unspent, each once, in the query's order. An empty list is a valid "no".
    \\- `color-admission`: the same shape; those ever validly admitted to the topic, spent or not
    \\  (a rejected transaction's outputs never were).
    \\
    \\Exactly these five keys; `version` 1; `assetId` and `topic` this service's own; each outpoint
    \\in canonical BRC-36 form (64 lowercase hex characters, a dot, the output index without
    \\leading zeros). Anything else is refused. Answers are output-lists, each output with its
    \\transaction's BEEF.
    \\
    ;
    return
    \\# 1Color token lookup service (ls_color)
    \\
    \\Indexes the outputs the topics that feed it admit: a token topic's (`tm_color_<txid>_<vout>`,
    \\BRC-207) by token id and outpoint, the discovery topic's (`tm_color`) deploys by token id. A token id is the deploy outpoint, the txid in display byte order,
    \\lowercase, written `<txid>_<vout>` for every token, `<txid>_0` included (BRC-162 "Token
    \\identification": the bare 32-byte txid is the wire form only). A query takes any of
    \\`<txid>`, `<txid>_<vout>`, `<txid>.<vout>`.
    \\
    \\## Queries
    \\
    \\The first key present, in this order, answers:
    \\
    \\- `{ authoritiesTokenId, limit?, skip? }`: the token's unspent authority outputs
    \\  (an authority-only deploy among them), in outpoint order.
    \\- `{ tokenId, limit?, skip? }`: the token's unspent value outputs (a deploy that carries
    \\  the supply among them), in outpoint order.
    \\- `{ txid, outputIndex }`: the value or authority output at that outpoint, if unspent.
    \\- Over the discovery topic, BRC-207's query with `topic: "tm_color"` (a deploy's outpoint is
    \\  its token id): `{ type: "color-admission" | "color-spendability", version: 1, assetId:
    \\  "<txid>_<vout>", topic: "tm_color", outpoints: ["<txid>.<vout>"] }` answers the asset's
    \\  deploy if `tm_color` admitted it (admission: spent or not; spendability: unspent).
    \\
    \\`limit` is 1 to 100 (default 100) and `skip` is 0 to 100000 (default 0). Anything
    \\else is refused. Outpoint order is the txid in display order, then the output index.
    \\Answers are output-lists, each output with its transaction's BEEF.
    \\
    ;
}

// ---------------------------------------------------------------- the token reads (fns "tokens" and "token", reads)

/// The token list's query: `{limit?, skip?}` from the query string or a JSON body (both: the body's
/// win), or `ids` (the query string only, comma-separated token ids `<txid>_<vout>`; 0.14.0), which
/// takes neither `limit` nor `skip`.
pub const TokensQuery = struct { limit: u64 = max_limit, skip: u64 = 0, ids: ?[]const []const u8 = null, paged: bool = false };

fn tokensField(q: *TokensQuery, key: []const u8, v: u64) !void {
    if (eql(u8, key, "limit")) {
        if (v < 1 or v > max_limit) return error.BadQuery;
        q.limit = v;
    } else if (eql(u8, key, "skip")) {
        if (v > max_skip) return error.BadQuery;
        q.skip = v;
    } else return error.BadQuery;
    q.paged = true;
}

/// A query string value percent-decoded (`%2C` is a comma as `URLSearchParams` writes it); a bad
/// escape is error.BadQuery.
fn percentDecoded(a: Allocator, v: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, v, '%') == null) return v;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] != '%') {
            try out.append(a, v[i]);
            continue;
        }
        if (i + 2 >= v.len) return error.BadQuery;
        try out.append(a, std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16) catch return error.BadQuery);
        i += 2;
    }
    return out.items;
}

/// The token list's query from a request: the query string's `limit` / `skip` (decimal) or `ids`,
/// then a JSON object body's `limit` / `skip` (integers). Any other key, a value out of range, an id
/// not exactly `<txid>_<vout>`, or `ids` beside `limit` / `skip`, is refused (error.BadQuery).
pub fn parseTokensQuery(a: Allocator, query: []const u8, body: []const u8) !TokensQuery {
    var q: TokensQuery = .{};
    var it = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, query, "?")) query[1..] else query, '&');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadQuery;
        if (eql(u8, kv[0..i], "ids")) {
            if (q.ids != null) return error.BadQuery;
            var ids: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, try percentDecoded(a, kv[i + 1 ..]), ',');
            while (parts.next()) |p| {
                if (tokenKeyOf(p) == null) return error.BadQuery;
                try ids.append(a, p);
            }
            q.ids = ids.items;
            continue;
        }
        const v = std.fmt.parseInt(u64, kv[i + 1 ..], 10) catch return error.BadQuery;
        try tokensField(&q, kv[0..i], v);
    }
    if (std.mem.trim(u8, body, " \t\r\n").len != 0) {
        const j = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.BadQuery;
        if (j != .object) return error.BadQuery;
        var jt = j.object.iterator();
        while (jt.next()) |e| {
            const v = e.value_ptr.*;
            if (v != .integer or v.integer < 0) return error.BadQuery;
            try tokensField(&q, e.key_ptr.*, @intCast(v.integer));
        }
    }
    if (q.ids != null and q.paged) return error.BadQuery;
    return q;
}

/// A token id exactly as the list writes it, `<txid>_<vout>` (the txid 64 lower-case hex in display
/// order, the vout decimal with no leading zero, `_0` included), as the discovery index's key; null
/// for any other text.
pub fn tokenKeyOf(t: []const u8) ?[36]u8 {
    if (t.len < 66 or t[64] != '_') return null;
    for (t[0..64]) |ch| if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return null;
    const v = t[65..];
    if (v.len > 1 and v[0] == '0') return null;
    for (v) |ch| if (!std.ascii.isDigit(ch)) return null;
    const vout = std.fmt.parseInt(u32, v, 10) catch return null;
    var key: [36]u8 = undefined;
    _ = std.fmt.hexToBytes(key[0..32], t[0..64]) catch return null;
    key[32..36].* = c.store.be32(vout);
    return key;
}

/// One token on the list: its id `<txid>_<vout>` (`_0` included), its topic `tm_color_<id>`, the
/// deploy's display fields (`sym` "" and `dec` 0 when the deploy carries none), `iconUrl` — a binary
/// (BRC-162) deploy's embedded image as `<tokenId>/icon`, relative to the list (absent when its media
/// type is not an RFC 6838 `type/subtype`); a BRC-161 JSON deploy's `icon` string only when it is an
/// http(s) URL — and the deploy outpoint.
pub const Listed = struct {
    tokenId: []const u8,
    topic: []const u8,
    sym: []const u8,
    dec: u8,
    iconUrl: ?[]const u8 = null,
    txid: []const u8,
    vout: u32,
    /// The deploy output's supply (0.15.0, D5): its amount, 0 for an authority-only deploy.
    amount: u64 = 0,
    /// The deploy's block height (0.15.0, D5): where the overlay has the deploy txid `placed` under
    /// the discovery topic (skein-overlay state.zig `placed`, written once its proof landed); null
    /// while not mined. Written as null, not left out.
    height: ?u32 = null,

    pub fn jsonStringify(self: Listed, jw: anytype) !void {
        try jw.beginObject();
        inline for (.{ "tokenId", "topic", "sym", "dec" }) |f| {
            try jw.objectField(f);
            try jw.write(@field(self, f));
        }
        if (self.iconUrl) |u| {
            try jw.objectField("iconUrl");
            try jw.write(u);
        }
        inline for (.{ "txid", "vout", "amount", "height" }) |f| {
            try jw.objectField(f);
            try jw.write(@field(self, f));
        }
        try jw.endObject();
    }
};

/// A row of the `ids` form: the token as listed, or `{tokenId, listed: false}` for an id discovery
/// does not list.
pub const Row = union(enum) {
    listed: Listed,
    unknown: []const u8,

    pub fn jsonStringify(self: Row, jw: anytype) !void {
        switch (self) {
            .listed => |l| try jw.write(l),
            .unknown => |id| {
                try jw.beginObject();
                try jw.objectField("tokenId");
                try jw.write(id);
                try jw.objectField("listed");
                try jw.write(false);
                try jw.endObject();
            },
        }
    }
};

/// Where a deploy stands for "newest first": its block height and position in the block from the
/// chain state's proof (null: not mined, the newest), then its deploy outpoint.
pub const Age = struct { key: []const u8, height: ?u32, offset: u64 };

pub fn newerFirst(_: void, x: Age, y: Age) bool {
    if (x.height == null and y.height != null) return true;
    if (y.height == null and x.height != null) return false;
    if (x.height) |hx| if (hx != y.height.?) return hx > y.height.?;
    if (x.height != null and x.offset != y.offset) return x.offset > y.offset;
    return std.mem.order(u8, x.key, y.key) == .gt;
}

fn ageOf(ch: *lookup.Chain, key: []const u8) !Age {
    const txid = display(key[0..32].*);
    const r = (try ch.proofRecord(txid)) orelse return .{ .key = key, .height = null, .offset = 0 };
    const block = c.store.bitcoinHash(r.block) orelse return error.BadIndex;
    const h = (try ch.chain().heightOf(block)) orelse return .{ .key = key, .height = null, .offset = 0 };
    return .{ .key = key, .height = h, .offset = r.pos.offset };
}

fn hexOf(a: Allocator, internal: [32]u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(display(internal), .lower));
}

/// A deploy as the reads serve it: its list row and, for a binary deploy, its embedded icon when
/// its media type is an RFC 6838 `type/subtype`.
pub const Deploy = struct { listed: Listed, icon: ?color.brc162.Icon = null };

/// The overlay's `placed` map (skein-overlay state.zig: `tp ‖ txid → height (u32 BE) ‖ offset (u64 BE)
/// ‖ block hash`) in its state record (the head `<app>/state`; null: none), for the discovery rows'
/// `height` (0.15.0).
pub const Placed = struct {
    map: ?c.store.Map = null,

    pub fn load(a: Allocator, s: c.store.Store, overlay_state: ?[]const u8) !Placed {
        const sc = overlay_state orelse return .{};
        const rec = try s.getValue(a, sc);
        const roots = rec.get("maps") orelse return .{};
        const maps = try c.store.Maps.create(a, s);
        return .{ .map = maps.map(roots.getCid("placed")) };
    }

    /// The height `txid` is placed at under the discovery topic, or null.
    pub fn heightOf(self: *Placed, a: Allocator, txid: [32]u8) !?u32 {
        const m = if (self.map) |*x| x else return null;
        const v = (try m.get(try c.store.nameKey(a, deploys_topic, &.{&txid}))) orelse return null;
        if (v != .bytes or v.bytes.len < 4) return error.BadIndex;
        return std.mem.readInt(u32, v.bytes[0..4], .big);
    }
};

/// A deploy the discovery index holds (its key: txid display ‖ vout BE), read from its transaction:
/// null when the store does not hold it or the output is no deploy.
fn deployOf(a: Allocator, s: c.store.Store, key: []const u8, placed: *Placed) !?Deploy {
    const op = opOf(key);
    const raw = s.tryGet(a, &c.store.hashCid(.tx, op.txid)) orelse return null;
    const tx = c.bsvz.transaction.Transaction.parse(a, raw) catch return null;
    if (op.vout >= tx.outputs.len) return null;
    const id: bsv21.TokenId = .{ .txid = op.txid, .vout = op.vout, .kind = if (op.vout == 0) .native else .legacy };
    const t = (try bsv21.tokenOf(a, id, op.txid, op.vout, tx.outputs[op.vout].locking_script.bytes)) orelse return null;
    if (t.role != .deploy) return null;
    const nid: color.name.TokenId = .{ .txid = id.txid, .vout = id.vout, .kind = if (op.vout == 0) .native else .legacy };
    var tb: [color.name.max_suffix_len]u8 = undefined;
    var nb: [color.name.max_topic_len]u8 = undefined;
    var out: Deploy = .{ .listed = .{
        .tokenId = try a.dupe(u8, color.name.tokenIdText(&tb, nid)),
        .topic = try a.dupe(u8, color.name.topicName(&nb, nid)),
        .sym = "",
        .dec = 0,
        .txid = try hexOf(a, op.txid),
        .vout = op.vout,
        .amount = t.amount,
        .height = try placed.heightOf(a, op.txid),
    } };
    switch (t.form) {
        .binary => {
            const m = color.brc162.metadataOf(t.binary.?.payload orelse "");
            out.listed.sym = m.sym orelse "";
            out.listed.dec = m.dec orelse 0;
            if (m.icon) |ic| if (isMediaType(ic.media_type)) {
                out.icon = ic;
                out.listed.iconUrl = try std.fmt.allocPrint(a, "{s}/icon", .{out.listed.tokenId});
            };
        },
        .json => {
            const j = t.json.?;
            out.listed.sym = j.sym orelse "";
            out.listed.dec = j.dec orelse 0;
            if (j.icon) |ic| if (isHttpUrl(ic)) {
                out.listed.iconUrl = ic;
            };
        },
    }
    return out;
}

fn listedOf(a: Allocator, s: c.store.Store, key: []const u8, placed: *Placed) !?Listed {
    return if (try deployOf(a, s, key, placed)) |d| d.listed else null;
}

/// Whether a BRC-161 icon string is an http(s) URL (the scheme in any case).
pub fn isHttpUrl(t: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(t, "http://") or std.ascii.startsWithIgnoreCase(t, "https://");
}

/// RFC 6838 §4.2: `type "/" subtype`, each a restricted-name (1 to 127 characters: a letter or
/// digit, then letters, digits and ! # $ & - ^ _ . +).
pub fn isMediaType(t: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, t, '/') orelse return false;
    return restrictedName(t[0..slash]) and restrictedName(t[slash + 1 ..]);
}

fn restrictedName(n: []const u8) bool {
    if (n.len == 0 or n.len > 127 or !std.ascii.isAlphanumeric(n[0])) return false;
    for (n[1..]) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "!#$&-^_.+", ch) == null) return false;
    return true;
}

/// The token list (shruggr/skein#120, decided 2026-10-06: a read function of the 1Color
/// components, not a BRC-24 query): every deploy the discovery topic `tm_color` admitted (the
/// map `deploys` of the program's index, its state record `deploys_state`), newest first by the
/// chain state (`chain_state`; unmined first, then by block height and position, highest first),
/// `skip` then `limit` of them. Reads only. (The `ids` form is `byIds`.)
pub fn tokens(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, chain_state: ?[]const u8, overlay_state: ?[]const u8, q: TokensQuery) ![]const Listed {
    var svc = try Service.loadIndex(a, s, service_name, index_name, spec.maps, deploys_state);
    var placed = try Placed.load(a, s, overlay_state);
    // The chain app's state through the SDK's one opener (shruggr/skein-sdk#1): its record's network, else main.
    var ch = try c.open(a, s, chain_state, .main);
    const all = try svc.map("deploys").prefixed(&.{});
    const ages = try a.alloc(Age, all.len);
    for (all, ages) |kv, *x| {
        if (kv.key.len != 36) return error.BadIndex;
        x.* = try ageOf(&ch, kv.key);
    }
    std.mem.sort(Age, ages, {}, newerFirst);
    var out: std.ArrayList(Listed) = .empty;
    var skipped: u64 = 0;
    for (ages) |x| {
        if (out.items.len >= q.limit) break;
        const l = (try listedOf(a, s, x.key, &placed)) orelse continue;
        if (skipped < q.skip) {
            skipped += 1;
            continue;
        }
        try out.append(a, l);
    }
    return out.items;
}

/// The `ids` form (0.14.0, D17): one row per id in the query's order, the token as listed when the
/// discovery topic admitted its deploy, else `{tokenId, listed: false}`.
pub fn byIds(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, overlay_state: ?[]const u8, ids: []const []const u8) ![]const Row {
    var svc = try Service.loadIndex(a, s, service_name, index_name, spec.maps, deploys_state);
    var placed = try Placed.load(a, s, overlay_state);
    const out = try a.alloc(Row, ids.len);
    for (ids, out) |id, *r| {
        r.* = .{ .unknown = id };
        const key = tokenKeyOf(id) orelse continue;
        if (!(try svc.map("deploys").has(&key))) continue;
        if (try listedOf(a, s, &key, &placed)) |l| r.* = .{ .listed = l };
    }
    return out;
}

/// The cache classes (exchange-api §routes): `state` for what moves; `imm` for the bytes of a
/// transaction the chain state holds proven (mined: its proof's block on the chain).
pub const cache_state = "public, max-age=5";
pub const cache_imm = "public, max-age=31536000, immutable";

fn respondWith(a: Allocator, status: u64, typ: []const u8, cache: ?[]const u8, body: []const u8) !Value {
    var es: std.ArrayList(c.cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "status", .value = .{ .uint = status } },
        .{ .key = "type", .value = .{ .text = typ } },
        .{ .key = "body", .value = .{ .bytes = body } },
    });
    if (cache) |cc| try es.append(a, .{ .key = "headers", .value = .{ .map = try a.dupe(c.cbor.Entry, &.{.{ .key = "cache-control", .value = .{ .text = cc } }}) } });
    return .{ .map = es.items };
}

fn respond(a: Allocator, status: u64, body: []const u8) !Value {
    return respondWith(a, status, "application/json", null, body);
}

fn jsonOf(a: Allocator, v: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(v, .{ .emit_null_optional_fields = false }, &w.writer);
    return w.written();
}

/// The read `/<app>/tokens` (the route handler contract, any method): `{limit?, skip?}` → 200
/// `[{tokenId, topic, sym, dec, iconUrl?, txid, vout}]`; `?ids=a,b` → one row per id in order,
/// `{tokenId, listed: false}` for an id not listed; 400 `{status: "error", message}` on a bad query.
/// `Cache-Control: public, max-age=5`. `deploys_state` is the program's index's record (the head
/// `<app>/ls_color`), `chain_state` the head `chain/state`'s.
pub fn tokensRoute(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, chain_state: ?[]const u8, overlay_state: ?[]const u8, req: Value) !Value {
    const q = parseTokensQuery(a, req.getText("query") orelse "", req.getBytes("body") orelse "") catch
        return respond(a, 400, "{\"status\":\"error\",\"message\":\"the query is {limit?: 1..100, skip?: 0..100000}, in the query string or a JSON body, or ids=<txid>_<vout>,… in the query string\"}");
    const body = if (q.ids) |ids| try jsonOf(a, try byIds(a, s, deploys_state, overlay_state, ids)) else try jsonOf(a, try tokens(a, s, deploys_state, chain_state, overlay_state, q));
    return respondWith(a, 200, "application/json", cache_state, body);
}

/// What a token's read names past the prefix row (`/<app>/`): `<token>`, `<token>/icon` or
/// `<token>/deploy`, `<token>` exactly `<txid>_<vout>`; null for anything else.
pub const TokenPath = struct { key: [36]u8, part: enum { detail, icon, deploy, holders } };

pub fn tokenPathOf(rest: []const u8) ?TokenPath {
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const key = tokenKeyOf(rest[0 .. slash orelse rest.len]) orelse return null;
    const tail = if (slash) |i| rest[i + 1 ..] else return .{ .key = key, .part = .detail };
    if (eql(u8, tail, "icon")) return .{ .key = key, .part = .icon };
    if (eql(u8, tail, "deploy")) return .{ .key = key, .part = .deploy };
    if (eql(u8, tail, "holders")) return .{ .key = key, .part = .holders };
    return null;
}

/// The part of the request's route past its prefix row's address (as served, `/<app>/`); null when
/// the route is not under it.
fn restOf(req: Value) ?[]const u8 {
    const route = req.getText("route") orelse req.getText("path") orelse return null;
    const m = req.get("match") orelse return null;
    const p = m.getText("address") orelse return null;
    if (!std.mem.startsWith(u8, route, p)) return null;
    return route[p.len..];
}

/// Whether the chain state holds `txid` proven: a proof whose block is on its chain (as its BEEF builder reads it).
fn provenIn(ch: *lookup.Chain, txid: [32]u8) !bool {
    return (try ch.minedStatus(txid)) == .proven;
}

/// The cache class of a transaction's bytes: `imm` when proven, else `state`.
pub fn cacheOf(proven: bool) []const u8 {
    return if (proven) cache_imm else cache_state;
}

const not_found = "{\"status\":\"error\",\"message\":\"not found\"}";

/// The prefix row `/<app>/` (0.14.0, D10; any method), by the route past the prefix:
///   `<token>`         200 JSON `{tokenId, topic, sym, dec, txid, vout, iconUrl?}`, `state`
///   `<token>/holders` (0.15.0) 200 JSON `{count, rows: [{address, balance}]}` largest first, `?limit=1..100&skip=`,
///                     `state`; from the balance table the token's own topic feeds (on its token instance)
///   `<token>/icon`    200 the embedded icon's bytes, its media type; `imm` when the deploy is proven, else `state`
///   `<token>/deploy`  200 the deploy's Atomic BEEF from the chain state, `application/octet-stream`; the same rule
/// `<token>` exactly `<txid>_<vout>`, its deploy one the discovery topic admitted; anything else 404
/// (a BRC-161 JSON deploy has no `/icon`: its `iconUrl` is its http(s) icon string).
pub fn tokenRoute(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, chain_state: ?[]const u8, overlay_state: ?[]const u8, req: Value) !Value {
    const tp = tokenPathOf(restOf(req) orelse "") orelse return respond(a, 404, not_found);
    var svc = try Service.loadIndex(a, s, service_name, index_name, spec.maps, deploys_state);
    // 0.15.0: the token's holders, from the balance table its own topic feeds (no deploy needed here).
    if (tp.part == .holders) {
        const hq = parseHoldersQuery(req.getText("query") orelse "") catch
            return respond(a, 400, "{\"status\":\"error\",\"message\":\"the query is limit=1..100, skip=0..100000\"}");
        const ch = try c.open(a, s, chain_state, .main);
        return respondWith(a, 200, "application/json", cache_state, try holdersJson(a, &svc, &tp.key, ch.network, hq));
    }
    if (!(try svc.map("deploys").has(&tp.key))) return respond(a, 404, not_found);
    var placed = try Placed.load(a, s, overlay_state);
    const d = (try deployOf(a, s, &tp.key, &placed)) orelse return respond(a, 404, not_found);
    if (tp.part == .detail) return respondWith(a, 200, "application/json", cache_state, try jsonOf(a, d.listed));
    var ch = try c.open(a, s, chain_state, .main);
    const txid = opOf(&tp.key).txid;
    switch (tp.part) {
        .detail, .holders => unreachable,
        .icon => {
            const ic = d.icon orelse return respond(a, 404, not_found);
            return respondWith(a, 200, ic.media_type, cacheOf(try provenIn(&ch, txid)), ic.bytes);
        },
        .deploy => {
            const beef = (try ch.beefOf(txid)) orelse return respond(a, 404, not_found);
            return respondWith(a, 200, "application/octet-stream", cacheOf(try provenIn(&ch, txid)), beef);
        },
    }
}

/// `<token>/holders`' query (0.15.0): `limit` 1 to 100 (default 100), `skip` 0 to 100000 (default 0),
/// from the query string; anything else refused.
pub const HoldersQuery = struct { limit: u64 = max_limit, skip: u64 = 0 };

pub fn parseHoldersQuery(query: []const u8) !HoldersQuery {
    var q: HoldersQuery = .{};
    var it = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, query, "?")) query[1..] else query, '&');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadQuery;
        const v = std.fmt.parseInt(u64, kv[i + 1 ..], 10) catch return error.BadQuery;
        if (eql(u8, kv[0..i], "limit")) {
            if (v < 1 or v > max_limit) return error.BadQuery;
            q.limit = v;
        } else if (eql(u8, kv[0..i], "skip")) {
            if (v > max_skip) return error.BadQuery;
            q.skip = v;
        } else return error.BadQuery;
    }
    return q;
}

/// One holder: the P2PKH address on `network` and the balance in token base units.
pub const Holder = struct { address: []const u8, balance: u64 };

/// The P2PKH address of `pkh` on `network` (base58check, the network's P2PKH version byte).
pub fn addressOf(a: Allocator, network: c.chain.Network, pkh: [20]u8) ![]const u8 {
    const net: c.bsvz.primitives.network.Network = switch (network) {
        .main => .mainnet,
        .@"test" => .testnet,
        .regtest => .regtest,
    };
    return c.bsvz.compat.address.encodeP2pkh(a, net, .{ .bytes = pkh });
}

/// The token `tk`'s holders, largest balance first (`byBalance`), `skip` then `limit` of them, and
/// their count (`holders`).
pub fn holdersOf(a: Allocator, svc: *Service, tk: []const u8, network: c.chain.Network, q: HoldersQuery) !struct { count: u64, rows: []const Holder } {
    const all = try svc.map("byBalance").prefixed(tk);
    const from: usize = @intCast(@min(q.skip, all.len));
    const to = @min(all.len, from + @as(usize, @intCast(q.limit)));
    const rows = try a.alloc(Holder, to - from);
    for (all[from..to], rows) |kv, *r| {
        if (kv.key.len != tk.len + 8 + 20) return error.BadIndex;
        r.* = .{
            .address = try addressOf(a, network, kv.key[tk.len + 8 ..][0..20].*),
            .balance = std.math.maxInt(u64) - std.mem.readInt(u64, kv.key[tk.len..][0..8], .big),
        };
    }
    return .{ .count = try u64Of(try svc.map("holders").get(tk)), .rows = rows };
}

/// `<token>/holders`' JSON: `{count, rows: [{address, balance}]}`.
fn holdersJson(a: Allocator, svc: *Service, tk: []const u8, network: c.chain.Network, q: HoldersQuery) ![]const u8 {
    const h = try holdersOf(a, svc, tk, network, q);
    return jsonOf(a, .{ .count = h.count, .rows = h.rows });
}

/// The app a read's call names: the read route's `app` (the install's; a read route names no program,
/// shruggr/skein#143), else its program record's, else "1color".
fn appOfRead(a: Allocator, s: c.store.Store, req: Value) ![]const u8 {
    const m = req.get("match") orelse return "1color";
    if (m.getText("app")) |x| return x;
    const p = m.getCid("program") orelse return "1color";
    return (try s.getValue(a, p)).getText("app") orelse "1color";
}

const sk = @import("overlay_sk");
var delegate = false;

fn run(a: Allocator) anyerror!void {
    const in = try sk.input(a);
    const func = in.getText("fn") orelse "";
    const route = if (eql(u8, func, "tokens")) &tokensRoute else if (eql(u8, func, "token")) &tokenRoute else {
        delegate = true;
        return;
    };
    const req = try sk.callArg(a, in);
    const s = sk.store();
    const app = try appOfRead(a, s, req);
    const deploys = try sk.head(a, try lookup.headName(a, app, index_name));
    const overlay = try sk.head(a, try std.fmt.allocPrint(a, "{s}/state", .{app}));
    const out = try route(a, s, deploys, try sk.head(a, lookup.chain_head), overlay, req);
    // A read route's filter (shruggr/skein#143): the http answer as the filter's `{answer: …}`.
    try sk.answer(a, if (isFilter(in)) try asFilterAnswer(a, out) else out);
}

/// Whether this call is a filter's: the input's `filter: true` (skein docs/APPS.md §2 "Filters").
pub fn isFilter(in: Value) bool {
    const f = in.get("filter") orelse return false;
    return f == .boolean and f.boolean;
}

/// An http answer `{status, type, body, headers?}` as a filter's `{answer: …}`.
pub fn asFilterAnswer(a: Allocator, http: Value) !Value {
    return .{ .map = try a.dupe(c.cbor.Entry, &.{.{ .key = "answer", .value = http }}) };
}

/// A call: fn "tokens" (the token list, a read), fn "token" (a token's detail, icon or deploy, a
/// read; 0.14.0), else the lookup contract's (fn "lookup", the hooks,
/// "metadata", "documentation").
pub fn main() u8 {
    const rc = sk.main("color-lookup", run);
    if (delegate) return lookup.main(spec);
    return rc;
}
