//! color-lookup: the 1Color (BRC-162) lookup program (shruggr/skein#120
//! item 3), a RECOGNIZER (0.18.0, agent-env plans/research/plan-pass-recognizers-2026-11-09.md):
//! through the skein-overlay lookup hooks (once per admitted transaction and topic) it keeps no
//! index; what is found or listed is an EVENT (the kernel's event index, skein docs/VM.md "The
//! event index"), and only the running SUMMARIES are stored, in the head `<app>/ls_color`
//! (`spec.index`), whatever name it is called as:
//!
//!   ls_color               over the discovery topic tm_color, BRC-207's two queries with
//!                            `topic: "tm_color"` (0.12.1)
//!   ls_color_<assetId>     a token's BRC-207 lookup beside its topic tm_color_<assetId>
//!
//! A lookup is this program under a name; the name pairs it with the topics that feed it
//! (David, 2026-10-29). 0.18.0: the three freeform queries ({tokenId}, {authoritiesTokenId},
//! {txid, outputIndex}) are gone (no consumer); BRC-207's queries are all it answers.
//!
//! WHAT IT READS (events, `<app>` the app the engine names in every call):
//!
//!   <app>/topic/output/<txid>.<vout>   the overlay's own fact {state: admitted | spent | reverted,
//!                                      spentBy?}; the latest is the output's standing: admitted
//!                                      (spent or not) unless `reverted` (BRC-207 admission; the
//!                                      hooks' "already credited" guard; the deploy list on
//!                                      discovery). The name carries no topic (skein-overlay 0.25.1),
//!                                      so the token of an output is read by parsing its stored
//!                                      transaction for the asset asked about.
//!
//! WHAT IT EMITS (the engine emits a hook's events in the step):
//!
//!   <app>/color/burn/<txid>                         {tokenId, amount, at} | {reverted: true}
//!   <app>/color/symbol/<hex(lower sym)>/<txid>.<vout>  {tokenId} | {reverted: true}  (discovery deploys)
//!
//! A burn: a transaction whose consumed value inputs (outputs of the token admitted here, unspent
//! or spent by it) carry more of the token than its admitted value outputs burns the difference;
//! its `rejected` hook emits `{reverted: true}` under the same name. A discovery deploy with a
//! symbol emits its symbol name (the token list's `q`); its rejection the revert.
//!
//! WHAT IT STORES (summaries, `tok` = the token's deploy txid in display order ‖ vout BE):
//!
//!   balances     tok ‖ pkh (20) → amount (u64 BE)                   a P2PKH address's balance, > 0
//!   byBalance    tok ‖ (2^64 − 1 − amount) (u64 BE) ‖ pkh → null      largest first
//!   holders      tok → count (u64 BE)                                 the addresses with a balance
//!   counters     tok → supply ‖ authorities ‖ burned ‖ burns (4 × u64 BE)
//!
//! An output of the token entering (admitted, or given back by a rejection) credits its P2PKH
//! address and the counters (`supply` by a value output's amount, `authorities` by one for an
//! authority output); leaving (spent, or its transaction rejected) debits them. A deploy is filed
//! by what it holds (0.15.1). Spent-ness for BRC-207 spendability is the chain state's
//! (`ch.spentBy`, skein-chain 0.9.0).
//!
//! **BRC-207** (David Case, 2026-10-08): called as `ls_color_<assetId>`, it answers
//!
//!   {type: "color-spendability" | "color-admission", version: 1, assetId,
//!    topic: "tm_color_<assetId>", outpoints: ["<txid>.<vout>", …]}
//!
//! validated strictly (these five keys and no other; version 1; assetId and topic exactly the
//! service name's; each outpoint canonical BRC-36 dot form, lowercase, the index without leading
//! zeros), as an output-list of exactly the queried outpoints, each once, in the query's order:
//! admission — those whose latest `<app>/topic/output` fact is not `reverted` and that are the
//! asset's outputs by their stored transaction; spendability — and the chain state names no
//! spender. Called as `ls_color` with `topic: "tm_color"`: of the queried outpoints, the asset's
//! deploy (its token id's outpoint) on the same rule. An empty list is a valid "no"; any other
//! query is refused.
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
    .maps = &.{ "balances", "byBalance", "holders", "counters" },
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

fn cat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

/// The kind of output `vout` of `tx` is for token `id`, or null (not its, or a BRC-161 burn).
fn kindOf(a: Allocator, id: bsv21.TokenId, tx: lookup.Tx, vout: u32) !?Kind {
    if (vout >= tx.tx.outputs.len) return error.BadArgs;
    const f = (try filedOf(a, id, tx.txid, tx.tx, vout)) orelse return null;
    return f.kind;
}

/// The kind and amount of output `vout` of transaction `t` (txid `txid`) for token `id`, or null.
fn filedOf(a: Allocator, id: bsv21.TokenId, txid: [32]u8, t: c.bsvz.transaction.Transaction, vout: u32) !?struct { kind: Kind, amount: u64 } {
    if (vout >= t.outputs.len) return null;
    const tk = (try bsv21.tokenOf(a, id, txid, vout, t.outputs[vout].locking_script.bytes)) orelse return null;
    // By what it holds (0.15.1): a deploy carrying the supply is a value output, an authority-only one an authority.
    const k: Kind = switch (tk.role) {
        .deploy => if (tk.authority or tk.amount == 0) .authority else .value,
        .authority => .authority,
        .value => .value,
        .burn => return null,
    };
    return .{ .kind = k, .amount = if (k == .value) tk.amount else 0 };
}

/// A stored transaction by its txid, decoded; null when the store does not hold it.
fn storedTx(a: Allocator, s: c.store.Store, txid: [32]u8) ?c.bsvz.transaction.Transaction {
    const raw = s.tryGet(a, &c.store.hashCid(.tx, txid)) orelse return null;
    return c.bsvz.transaction.Transaction.parse(a, raw) catch null;
}

// ---------------------------------------------------------------- the event index (0.18.0)

/// A read of the kernel's event index (skein docs/VM.md "The event index"): the query `{name |
/// prefix, after?, limit?, latest?}` → `[{name, place, cid, record}]`, newest last. Set by `run`
/// to the `events` import; a native test sets its own. Null: no index to read (error.NoEventIndex).
pub const EventsFn = *const fn (a: Allocator, query: Value) anyerror!Value;
pub var events_fn: ?EventsFn = null;

var app_buf: [256]u8 = undefined;
/// The app the call names (`<app>`, the first segment of every event name it reads or emits; the
/// engine names it in every hook and lookup call, a read route by its row). Set by `run`.
pub var app_name: []const u8 = "1color";

pub fn setApp(app: []const u8) !void {
    if (app.len > app_buf.len) return error.BadArgs;
    @memcpy(app_buf[0..app.len], app);
    app_name = app_buf[0..app.len];
}

/// One fact read back: its name and its record.
pub const Fact = struct { name: []const u8, record: Value };

fn readFacts(a: Allocator, key: []const u8, name: []const u8, latest: bool) ![]const Fact {
    const f = events_fn orelse return error.NoEventIndex;
    var es: std.ArrayList(c.cbor.Entry) = .empty;
    try es.append(a, .{ .key = key, .value = .{ .text = name } });
    if (latest) try es.append(a, .{ .key = "latest", .value = .{ .boolean = true } });
    const v = try f(a, .{ .map = es.items });
    if (v != .array) return error.BadEvents;
    const out = try a.alloc(Fact, v.array.len);
    for (v.array, out) |row, *o| o.* = .{ .name = row.getText("name") orelse return error.BadEvents, .record = row.get("record") orelse return error.BadEvents };
    return out;
}

/// The latest fact under exactly `name`, or null.
fn latestOf(a: Allocator, name: []const u8) !?Value {
    const fs = try readFacts(a, "name", name, true);
    return if (fs.len == 0) null else fs[fs.len - 1].record;
}

/// The latest fact under every name `prefix` starts (one per name, in place order).
fn latestUnder(a: Allocator, prefix: []const u8) ![]const Fact {
    return readFacts(a, "prefix", prefix, true);
}

fn isReverted(r: Value) bool {
    return r.getBool("reverted") orelse false;
}

/// The overlay's name for an output's standing (skein-overlay 0.25.1 submit.zig `topicOutputName`):
/// `<app>/topic/output/<txid hex>.<vout>`.
pub fn topicOutputName(a: Allocator, txid: [32]u8, vout: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/topic/output/{s}.{d}", .{ app_name, &c.header.toHex(txid), vout });
}

pub const OutputState = enum { admitted, spent, reverted };
pub const OutputFact = struct { state: OutputState, spent_by: ?[32]u8 = null };

/// The latest `<app>/topic/output/<txid>.<vout>` fact, or null (never admitted here).
pub fn outputFact(a: Allocator, txid: [32]u8, vout: u32) !?OutputFact {
    const r = (try latestOf(a, try topicOutputName(a, txid, vout))) orelse return null;
    return try outputFactOf(r);
}

fn outputFactOf(r: Value) !OutputFact {
    const st = std.meta.stringToEnum(OutputState, r.getText("state") orelse return error.BadEvents) orelse return error.BadEvents;
    const by: ?[32]u8 = if (r.getText("spentBy")) |t| c.header.fromHex(t) catch return error.BadEvents else null;
    return .{ .state = st, .spent_by = by };
}

/// Whether the overlay has the output admitted, spent or not (its latest fact not `reverted`).
fn standing(f: ?OutputFact) bool {
    const x = f orelse return false;
    return x.state != .reverted;
}

/// The outpoint a `<…>/<txid hex>.<vout>` name ends in, or null.
fn outpointOfName(name: []const u8) ?lookup.Output {
    const i = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
    const t = name[i + 1 ..];
    if (t.len < 66 or t[64] != '.') return null;
    const txid = c.header.fromHex(t[0..64]) catch return null;
    const vout = std.fmt.parseInt(u32, t[65..], 10) catch return null;
    return .{ .txid = txid, .vout = vout };
}

/// The burn of `txid`: `<app>/color/burn/<txid hex>`.
pub fn burnName(a: Allocator, txid: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/color/burn/{s}", .{ app_name, &c.header.toHex(txid) });
}

/// The prefix of a symbol's names, `<app>/color/symbol/<hex(lower sym)>` (a hex prefix of a
/// symbol's names is a prefix of its own: hex keeps a byte prefix a prefix).
fn symbolPrefix(a: Allocator, lower: []const u8) ![]const u8 {
    const digits = "0123456789abcdef";
    const hex = try a.alloc(u8, lower.len * 2);
    for (lower, 0..) |x, i| {
        hex[2 * i] = digits[x >> 4];
        hex[2 * i + 1] = digits[x & 15];
    }
    return std.fmt.allocPrint(a, "{s}/color/symbol/{s}", .{ app_name, hex });
}

/// A deploy's symbol name: `<app>/color/symbol/<hex(lower sym)>/<txid hex>.<vout>`.
pub fn symbolName(a: Allocator, sym: []const u8, txid: [32]u8, vout: u32) ![]const u8 {
    const lower = try std.ascii.allocLowerString(a, sym);
    return std.fmt.allocPrint(a, "{s}/{s}.{d}", .{ try symbolPrefix(a, lower), &c.header.toHex(txid), vout });
}

fn tokenIdTextAlloc(a: Allocator, id: bsv21.TokenId) ![]const u8 {
    const nid: color.name.TokenId = .{ .txid = id.txid, .vout = id.vout, .kind = if (id.kind == .native) .native else .legacy };
    var tb: [color.name.max_suffix_len]u8 = undefined;
    return a.dupe(u8, color.name.tokenIdText(&tb, nid));
}

fn emitFact(a: Allocator, svc: *Service, name: []const u8, fields: []const c.cbor.Entry) !void {
    try svc.emit(.{ .map = try std.mem.concat(a, c.cbor.Entry, &.{ &.{.{ .key = "event", .value = .{ .text = name } }}, fields }) });
}

fn emitReverted(a: Allocator, svc: *Service, name: []const u8) !void {
    try emitFact(a, svc, name, &.{.{ .key = "reverted", .value = .{ .boolean = true } }});
}

// ---------------------------------------------------------------- the counters (0.17.0)

/// The time of the step whose hook this call runs in (ms): the in-VM call input's `now` (skein
/// docs/VM.md, "call"; replay-exact), set by `run` before the hook; a burn's `at`.
pub var now_ms: u64 = 0;

/// A token's counters (the record under `counters`).
pub const Counters = struct { supply: u64 = 0, authorities: u64 = 0, burned: u64 = 0, burns: u64 = 0 };

pub fn countersOf(svc: *Service, tk: []const u8) !Counters {
    const v = (try svc.map("counters").get(tk)) orelse return .{};
    if (v != .bytes or v.bytes.len != 32) return error.BadIndex;
    const b = v.bytes;
    return .{
        .supply = std.mem.readInt(u64, b[0..8], .big),
        .authorities = std.mem.readInt(u64, b[8..16], .big),
        .burned = std.mem.readInt(u64, b[16..24], .big),
        .burns = std.mem.readInt(u64, b[24..32], .big),
    };
}

fn putCounters(a: Allocator, svc: *Service, tk: []const u8, n: Counters) !void {
    if (n.supply == 0 and n.authorities == 0 and n.burned == 0 and n.burns == 0) {
        _ = try svc.map("counters").remove(tk);
        return;
    }
    try svc.map("counters").put(tk, .{ .bytes = try cat(a, &.{ &be64(n.supply), &be64(n.authorities), &be64(n.burned), &be64(n.burns) }) });
}

/// An output of `tk` entering (`enter`) or leaving: `supply` by a value output's amount,
/// `authorities` by one for an authority output.
fn counted(a: Allocator, svc: *Service, tk: []const u8, kind: Kind, amount: u64, enter: bool) !void {
    var n = try countersOf(svc, tk);
    switch (kind) {
        .value => n.supply = if (enter) std.math.add(u64, n.supply, amount) catch std.math.maxInt(u64) else n.supply -| amount,
        .authority => n.authorities = if (enter) n.authorities + 1 else n.authorities -| 1,
    }
    try putCounters(a, svc, tk, n);
}

/// Output `vout` of `t` (txid `txid`) entering or leaving: its holding (a value output's P2PKH
/// address) and the counters. Nothing for an output that is not the token's (or a burn).
fn outputMoved(a: Allocator, svc: *Service, id: bsv21.TokenId, txid: [32]u8, t: c.bsvz.transaction.Transaction, vout: u32, enter: bool) !void {
    const f = (try filedOf(a, id, txid, t, vout)) orelse return;
    if (f.kind == .value) try holdingMoved(a, svc, id, txid, t, vout, enter);
    try counted(a, svc, &tokKey(id), f.kind, f.amount, enter);
}

/// The same, for an output read from the store by its txid (a spent or given-back previous coin).
fn storedMoved(a: Allocator, svc: *Service, id: bsv21.TokenId, txid: [32]u8, vout: u32, enter: bool) !void {
    const t = storedTx(a, svc.store, txid) orelse return;
    try outputMoved(a, svc, id, txid, t, vout, enter);
}

/// The amount of the value output `vout` of the stored transaction `txid`, 0 when not held or not one.
fn storedAmount(a: Allocator, id: bsv21.TokenId, s: c.store.Store, txid: [32]u8, vout: u32) !u64 {
    const t = storedTx(a, s, txid) orelse return 0;
    const f = (try filedOf(a, id, txid, t, vout)) orelse return 0;
    return f.amount;
}

/// Whether `tx` burns token `id` (`tk`): its consumed value inputs — the token's outputs the overlay
/// has admitted, unspent or spent by `tx` itself (a dupe hook call) — carry more than its admitted
/// value outputs; the difference counted once (the burn's fact not yet standing) and emitted.
fn burnCheck(a: Allocator, svc: *Service, id: bsv21.TokenId, tk: []const u8, tx: lookup.Tx, outputs_to_admit: []const u32) !void {
    var in_sum: u128 = 0;
    for (tx.tx.inputs) |in| {
        const po = in.previous_outpoint;
        const f = (try outputFact(a, po.txid.bytes, po.index)) orelse continue;
        switch (f.state) {
            .admitted => {},
            .spent => if (f.spent_by == null or !eql(u8, &f.spent_by.?, &tx.txid)) continue,
            .reverted => continue,
        }
        in_sum += try storedAmount(a, id, svc.store, po.txid.bytes, po.index);
    }
    if (in_sum == 0) return;
    var out_sum: u128 = 0;
    for (outputs_to_admit) |vout| {
        const f = (try filedOf(a, id, tx.txid, tx.tx, vout)) orelse continue;
        out_sum += f.amount;
    }
    if (in_sum <= out_sum) return;
    const name = try burnName(a, tx.txid);
    if (try latestOf(a, name)) |r| if (!isReverted(r)) return;
    const amount: u64 = std.math.cast(u64, in_sum - out_sum) orelse std.math.maxInt(u64);
    var n = try countersOf(svc, tk);
    n.burned = std.math.add(u64, n.burned, amount) catch std.math.maxInt(u64);
    n.burns += 1;
    try putCounters(a, svc, tk, n);
    try emitFact(a, svc, name, &.{
        .{ .key = "tokenId", .value = .{ .text = try tokenIdTextAlloc(a, id) } },
        .{ .key = "amount", .value = .{ .uint = amount } },
        .{ .key = "at", .value = .{ .uint = now_ms } },
    });
}

/// A rejected `tx`'s burn, unwound: the total debited by the amount its fact carries, `{reverted: true}` emitted.
fn burnUndo(a: Allocator, svc: *Service, id: bsv21.TokenId, tk: []const u8, txid: [32]u8) !void {
    const name = try burnName(a, txid);
    const r = (try latestOf(a, name)) orelse return;
    if (isReverted(r)) return;
    if (!eql(u8, r.getText("tokenId") orelse "", try tokenIdTextAlloc(a, id))) return;
    const amount = r.getUint("amount") orelse return error.BadEvents;
    var n = try countersOf(svc, tk);
    n.burned -|= amount;
    n.burns -|= 1;
    try putCounters(a, svc, tk, n);
    try emitReverted(a, svc, name);
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
    // A value output as `filedOf` files it (0.15.1: a supply-holding deploy is one).
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

/// The output `vout` of `t` (txid `txid`) entering (`credit`) or leaving: its holding, if any, adjusted.
fn holdingMoved(a: Allocator, svc: *Service, id: bsv21.TokenId, txid: [32]u8, t: c.bsvz.transaction.Transaction, vout: u32, credit: bool) !void {
    if (vout >= t.outputs.len) return;
    const h = (try holdingOf(a, id, txid, vout, t.outputs[vout].locking_script.bytes)) orelse return;
    try adjust(a, svc, &tokKey(id), h.pkh, h.amount, credit);
}

// ---------------------------------------------------------------- the symbol facts (0.16.0; events 0.18.0)

/// A deploy's display symbol from its output (a binary deploy's payload `sym`, a BRC-161 JSON
/// deploy's `sym`), "" when it carries none; null when the output is no deploy of `id`.
pub fn symOfDeploy(a: Allocator, id: bsv21.TokenId, txid: [32]u8, vout: u32, script: []const u8) !?[]const u8 {
    const t = (try bsv21.tokenOf(a, id, txid, vout, script)) orelse return null;
    if (t.role != .deploy) return null;
    return switch (t.form) {
        .binary => color.brc162.metadataOf(t.binary.?.payload orelse "").sym orelse "",
        .json => t.json.?.sym orelse "",
    };
}

/// A deploy's symbol fact name, null when it has no symbol.
fn deploySymbolName(a: Allocator, id: bsv21.TokenId, txid: [32]u8, vout: u32, script: []const u8) !?[]const u8 {
    const sym = (try symOfDeploy(a, id, txid, vout, script)) orelse return null;
    if (sym.len == 0) return null;
    return try symbolName(a, sym, txid, vout);
}

// The hooks come once per admitted transaction and topic, under whichever of the program's names
// listens first (skein-overlay 0.11.0): they go by the topic, never by the name. Every prior fact
// they read is an earlier step's (an in-step read does not see the step's own emits, skein
// docs/VM.md): the overlay emits this admission's `topic/output` facts after the hooks.

fn admitted(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx, outputs_to_admit: []const u32, _: []const u32) anyerror!void {
    if (eql(u8, topic, deploys_topic)) {
        for (outputs_to_admit) |vout| {
            if (vout >= tx.tx.outputs.len) return error.BadArgs;
            const script = tx.tx.outputs[vout].locking_script.bytes;
            const id = (try token.deployOf(a, tx.txid, vout, script)) orelse continue;
            const name = (try deploySymbolName(a, id, tx.txid, vout, script)) orelse continue;
            if (try latestOf(a, name)) |r| if (!isReverted(r)) continue;
            try emitFact(a, svc, name, &.{.{ .key = "tokenId", .value = .{ .text = try tokenIdTextAlloc(a, id) } }});
        }
        return;
    }
    const id = token.tokenIdOf(topic) orelse return;
    const tk = tokKey(id);
    // 0.17.0: before the outputs are counted, while the inputs it consumes still stand admitted.
    try burnCheck(a, svc, id, &tk, tx, outputs_to_admit);
    for (outputs_to_admit) |vout| {
        if (vout >= tx.tx.outputs.len) return error.BadArgs;
        _ = (try kindOf(a, id, tx, vout)) orelse continue;
        // Already credited when the overlay has it standing (a dupe hook call credits nothing).
        if (standing(try outputFact(a, tx.txid, vout))) continue;
        try outputMoved(a, svc, id, tx.txid, tx.tx, vout, true);
    }
}

fn spent(a: Allocator, svc: *Service, topic: []const u8, outpoint: lookup.Outpoint, _: lookup.Tx) anyerror!void {
    if (eql(u8, topic, deploys_topic)) return; // a registry: a deploy stays listed once spent
    const id = token.tokenIdOf(topic) orelse return;
    // Debited once: only while the overlay has it admitted and not yet spent.
    const f = (try outputFact(a, outpoint.txid, outpoint.vout)) orelse return;
    if (f.state != .admitted) return;
    try storedMoved(a, svc, id, outpoint.txid, outpoint.vout, false);
}

fn rejected(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx) anyerror!void {
    if (eql(u8, topic, deploys_topic)) {
        for (tx.tx.outputs, 0..) |o, vout| {
            const id = (try token.deployOf(a, tx.txid, @intCast(vout), o.locking_script.bytes)) orelse continue;
            const name = (try deploySymbolName(a, id, tx.txid, @intCast(vout), o.locking_script.bytes)) orelse continue;
            const r = (try latestOf(a, name)) orelse continue;
            if (!isReverted(r)) try emitReverted(a, svc, name);
        }
        return;
    }
    const id = token.tokenIdOf(topic) orelse return;
    // 0.17.0: its burn, if it burned.
    try burnUndo(a, svc, id, &tokKey(id), tx.txid);
    // Its outputs still unspent leave (a spent one was debited by its spender).
    for (0..tx.tx.outputs.len) |vout| {
        const f = (try outputFact(a, tx.txid, @intCast(vout))) orelse continue;
        if (f.state == .admitted) try outputMoved(a, svc, id, tx.txid, tx.tx, @intCast(vout), false);
    }
    // What it spent is unspent again.
    for (tx.tx.inputs) |in| {
        const po = in.previous_outpoint;
        const f = (try outputFact(a, po.txid.bytes, po.index)) orelse continue;
        if (f.state != .spent) continue;
        const by = f.spent_by orelse continue;
        if (!eql(u8, &by, &tx.txid)) continue;
        try storedMoved(a, svc, id, po.txid.bytes, po.index, true);
    }
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

/// A BRC-207 answer: of the queried outpoints, those the overlay has admitted (the latest
/// `<app>/topic/output/<op>` fact not `reverted`) that are the asset's by their stored transaction
/// (the fact's name carries no topic: on an instance serving several, the token is read from the
/// output), and, for spendability, that the chain state names no spender for (skein-chain 0.9.0
/// `spentBy`; `chain/output/<op>` once skein-chain 0.10.0 posts it).
pub fn answer207(a: Allocator, svc: *Service, ch: *lookup.Chain, q: Brc207) ![]const lookup.Output {
    const tk = tokKey(q.id);
    var out: std.ArrayList(lookup.Output) = .empty;
    for (q.outpoints) |o| {
        if (q.discovery) {
            // The discovery topic admits a token's deploy output, at the token id's outpoint.
            if (!eql(u8, &opKey(o.txid, o.vout), &tk)) continue;
        }
        if (!standing(try outputFact(a, o.txid, o.vout))) continue;
        if (!(try isAssetOutput(a, svc.store, q.id, o, q.discovery))) continue;
        if (q.kind == .spendability and (try spentByChain(ch, o)) != null) continue;
        try out.append(a, o);
    }
    return out.items;
}

/// Whether output `o` is token `id`'s by its stored transaction: any of its outputs (BSV-21
/// `tokenOf`), or (`deploy`) its deploy.
fn isAssetOutput(a: Allocator, s: c.store.Store, id: bsv21.TokenId, o: lookup.Output, deploy: bool) !bool {
    const t = storedTx(a, s, o.txid) orelse return false;
    if (o.vout >= t.outputs.len) return false;
    const script = t.outputs[o.vout].locking_script.bytes;
    if (deploy) {
        const d = (try token.deployOf(a, o.txid, o.vout, script)) orelse return false;
        return eql(u8, &d.txid, &id.txid) and d.vout == id.vout;
    }
    return (try bsv21.tokenOf(a, id, o.txid, o.vout, script)) != null;
}

/// SEAM (skein-chain 0.10.0): the output's spender as the chain state names it today (the lowest-txid
/// non-rejected held spender, skein-sdk 0.18.0 `State.spentBy`); to read `chain/output/<op>` latest
/// ("spent by T") when that is posted.
fn spentByChain(ch: *lookup.Chain, o: lookup.Output) !?[32]u8 {
    return ch.spentBy(o.txid, o.vout);
}

/// BRC-207's queries, and nothing else (0.18.0: the freeform queries are gone).
pub fn answer(a: Allocator, svc: *Service, ch: *lookup.Chain, query: Value) anyerror!lookup.Answer {
    if (color.name.tokenIdOfLookup(svc.name) != null) return .{ .output_list = try answer207(a, svc, ch, try parse207(a, svc.name, query)) };
    if (!eql(u8, svc.name, service_name)) return error.UnknownService;
    // BRC-207's query over the discovery topic (0.12.1: it carries a `type`).
    if (query == .map and query.get("type") != null) return .{ .output_list = try answer207(a, svc, ch, try parse207(a, svc.name, query)) };
    return error.BadQuery;
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
        .short_description = "1Color (BRC-162; BRC-207): over the discovery topic tm_color, BRC-207's color-admission and color-spendability of a token's deploy.",
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
    \\Over the discovery topic `tm_color`, every token's deploy output. A token id is the deploy
    \\outpoint, the txid in display byte order, lowercase, written `<txid>_<vout>` for every token,
    \\`<txid>_0` included (BRC-162 "Token identification": the bare 32-byte txid is the wire form only).
    \\
    \\## Queries
    \\
    \\BRC-207's query with `topic: "tm_color"` (a deploy's outpoint is its token id): `{ type:
    \\"color-admission" | "color-spendability", version: 1, assetId: "<txid>_<vout>", topic:
    \\"tm_color", outpoints: ["<txid>.<vout>"] }` answers the asset's deploy if `tm_color` admitted it
    \\(admission: spent or not; spendability: unspent). Anything else is refused. Answers are
    \\output-lists, each output with its transaction's BEEF.
    \\
    \\## The token list (a read, not a query)
    \\
    \\`GET /<app>/tokens` lists every deploy `tm_color` admitted, newest first by the chain
    \\(`limit`, `skip`, or `ids`). 0.16.0: `q=<text>` keeps the tokens whose symbol starts with
    \\it (ASCII case-insensitive) or whose token id starts with it, in the same order; `after=
    \\<txid>_<vout>` the rows strictly after that token (400 when the list does not hold it, or
    \\beside `skip`).
    \\
    ;
}

// ---------------------------------------------------------------- the token reads (fns "tokens" and "token", reads)

/// The token list's query: `{limit?, skip?}` from the query string or a JSON body (both: the body's
/// win), or `ids` (the query string only, comma-separated token ids `<txid>_<vout>`; 0.14.0), which
/// takes neither `limit` nor `skip`. 0.16.0, the query string only: `q` (a search: the tokens whose
/// symbol starts with it, ASCII case-insensitively, or whose token id starts with it; "" no filter;
/// at most `max_q` bytes) and `after` (a token id `<txid>_<vout>`: the rows strictly after it in the
/// list's order), neither beside `ids`, `after` not beside `skip`.
pub const TokensQuery = struct {
    limit: u64 = max_limit,
    skip: u64 = 0,
    ids: ?[]const []const u8 = null,
    paged: bool = false,
    q: ?[]const u8 = null,
    after: ?[]const u8 = null,
    skipped: bool = false,
};

/// The longest `q` the list takes (0.16.0).
pub const max_q = 100;

fn tokensField(q: *TokensQuery, key: []const u8, v: u64) !void {
    if (eql(u8, key, "limit")) {
        if (v < 1 or v > max_limit) return error.BadQuery;
        q.limit = v;
    } else if (eql(u8, key, "skip")) {
        if (v > max_skip) return error.BadQuery;
        q.skip = v;
        q.skipped = true;
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
        if (eql(u8, kv[0..i], "q")) {
            if (q.q != null) return error.BadQuery;
            // `URLSearchParams` writes a space as `+`.
            const raw = try a.dupe(u8, kv[i + 1 ..]);
            std.mem.replaceScalar(u8, raw, '+', ' ');
            const t = try percentDecoded(a, raw);
            if (t.len > max_q) return error.BadQuery;
            q.q = t;
            continue;
        }
        if (eql(u8, kv[0..i], "after")) {
            if (q.after != null) return error.BadQuery;
            const t = try percentDecoded(a, kv[i + 1 ..]);
            if (tokenKeyOf(t) == null) return error.BadQuery;
            q.after = t;
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
    if (q.ids != null and (q.paged or q.q != null or q.after != null)) return error.BadQuery;
    if (q.after != null and q.skipped) return error.BadQuery;
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
/// components, not a BRC-24 query): every deploy the discovery topic `tm_color` admitted — 0.18.0:
/// the outputs whose latest `<app>/topic/output` fact is not `reverted` and that are deploys by
/// their stored transaction (`deployOf`) — newest first by the chain state (`chain_state`; unmined
/// first, then by block height and position, highest first), `skip` then `limit` of them. Reads
/// only. (The `ids` form is `byIds`.) COST (plan M18): every `<app>/topic/output` name is read on
/// each request (the event read pages by place, not by name).
///
/// 0.16.0: a non-empty `q` lists only the tokens `searched` finds (the same rows, in the same order);
/// `after` only the rows strictly after that token in the order (its own place read from the chain
/// state by its key), error.UnknownAfter when the discovery topic admitted no such deploy.
pub fn tokens(a: Allocator, s: c.store.Store, _: ?[]const u8, chain_state: ?[]const u8, overlay_state: ?[]const u8, q: TokensQuery) ![]const Listed {
    var placed = try Placed.load(a, s, overlay_state);
    // The chain app's state through the SDK's one opener (shruggr/skein-sdk#1): its record's network, else main.
    var ch = try c.open(a, s, chain_state, .main);
    const after: ?Age = if (q.after) |t| blk: {
        const key = try a.dupe(u8, &(tokenKeyOf(t) orelse return error.BadQuery));
        if (!(try isListed(a, s, key))) return error.UnknownAfter;
        break :blk try ageOf(&ch, key);
    } else null;
    const keys: []const []const u8 = if (q.q) |text| (if (text.len > 0) try searched(a, text) else try allDeploys(a)) else try allDeploys(a);
    var ages: std.ArrayList(Age) = .empty;
    for (keys) |k| {
        if (k.len != 36) return error.BadIndex;
        const x = try ageOf(&ch, k);
        if (after) |af| if (!newerFirst({}, af, x)) continue;
        try ages.append(a, x);
    }
    std.mem.sort(Age, ages.items, {}, newerFirst);
    var out: std.ArrayList(Listed) = .empty;
    var skipped: u64 = 0;
    for (ages.items, 0..) |x, i| {
        if (out.items.len >= q.limit) break;
        // A token both sides of `q` found is listed once.
        if (i > 0 and eql(u8, ages.items[i - 1].key, x.key)) continue;
        const l = (try listedOf(a, s, x.key, &placed)) orelse continue;
        if (skipped < q.skip) {
            skipped += 1;
            continue;
        }
        try out.append(a, l);
    }
    return out.items;
}

/// Whether the deploy at `key` (txid display ‖ vout BE) is on the list: the overlay has it admitted
/// and its stored output is a deploy.
fn isListed(a: Allocator, s: c.store.Store, key: []const u8) !bool {
    const op = opOf(key);
    if (!standing(try outputFact(a, op.txid, op.vout))) return false;
    const t = storedTx(a, s, op.txid) orelse return false;
    if (op.vout >= t.outputs.len) return false;
    return (try token.deployOf(a, op.txid, op.vout, t.outputs[op.vout].locking_script.bytes)) != null;
}

/// The keys of the outputs whose latest fact under `prefix` (a `<app>/topic/output/…` prefix) is not
/// `reverted`, in name order; a row that is no deploy is dropped by the reader (`listedOf`).
fn standingUnder(a: Allocator, prefix: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try latestUnder(a, prefix)) |f| {
        const o = outpointOfName(f.name) orelse return error.BadEvents;
        if (!standing(try outputFactOf(f.record))) continue;
        try out.append(a, try a.dupe(u8, &opKey(o.txid, o.vout)));
    }
    return out.items;
}

fn allDeploys(a: Allocator) ![]const []const u8 {
    return standingUnder(a, try std.fmt.allocPrint(a, "{s}/topic/output/", .{app_name}));
}

/// The token keys `q` finds (0.16.0), possibly one twice: the deploys whose symbol starts with `q`
/// (ASCII case-insensitively; the symbol facts `<app>/color/symbol/<hex(lower sym)>/…` under the
/// prefix of `q` lower-cased, not reverted), and the deploys whose token id text `<txid>_<vout>`
/// starts with `q` (the `<app>/topic/output/<hex>` names under `q`'s leading lower-case hex digits,
/// up to 64).
pub fn searched(a: Allocator, q: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const lower = try std.ascii.allocLowerString(a, q);
    for (try latestUnder(a, try symbolPrefix(a, lower))) |f| {
        if (isReverted(f.record)) continue;
        const o = outpointOfName(f.name) orelse return error.BadEvents;
        try out.append(a, try a.dupe(u8, &opKey(o.txid, o.vout)));
    }
    // The id side: the txid's hex digits `q` begins with, as a prefix of the output facts' names.
    const n = @min(q.len, 64);
    for (q[0..n]) |ch| if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return out.items;
    for (try standingUnder(a, try std.fmt.allocPrint(a, "{s}/topic/output/{s}", .{ app_name, q[0..n] }))) |k| {
        const text = try std.fmt.allocPrint(a, "{s}_{d}", .{ &std.fmt.bytesToHex(k[0..32].*, .lower), std.mem.readInt(u32, k[32..36], .big) });
        if (std.mem.startsWith(u8, text, q)) try out.append(a, k);
    }
    return out.items;
}

/// The `ids` form (0.14.0, D17): one row per id in the query's order, the token as listed when the
/// discovery topic admitted its deploy, else `{tokenId, listed: false}`.
pub fn byIds(a: Allocator, s: c.store.Store, overlay_state: ?[]const u8, ids: []const []const u8) ![]const Row {
    var placed = try Placed.load(a, s, overlay_state);
    const out = try a.alloc(Row, ids.len);
    for (ids, out) |id, *r| {
        r.* = .{ .unknown = id };
        const key = tokenKeyOf(id) orelse continue;
        if (!(try isListed(a, s, &key))) continue;
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

/// The read `/<app>/tokens` (the route handler contract, any method): `{limit?, skip?}` (and 0.16.0's
/// `q`, `after`; an `after` not on the list 400) → 200
/// `[{tokenId, topic, sym, dec, iconUrl?, txid, vout}]`; `?ids=a,b` → one row per id in order,
/// `{tokenId, listed: false}` for an id not listed; 400 `{status: "error", message}` on a bad query.
/// `Cache-Control: public, max-age=5`. `deploys_state` is the program's index's record (the head
/// `<app>/ls_color`), `chain_state` the head `chain/state`'s.
pub fn tokensRoute(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, chain_state: ?[]const u8, overlay_state: ?[]const u8, req: Value) !Value {
    const q = parseTokensQuery(a, req.getText("query") orelse "", req.getBytes("body") orelse "") catch
        return respond(a, 400, "{\"status\":\"error\",\"message\":\"the query is {limit?: 1..100, skip?: 0..100000}, in the query string or a JSON body, with q=<text> (at most 100 bytes) and after=<txid>_<vout> (not beside skip) in the query string; or ids=<txid>_<vout>,… in the query string alone\"}");
    const body = if (q.ids) |ids| try jsonOf(a, try byIds(a, s, overlay_state, ids)) else try jsonOf(a, tokens(a, s, deploys_state, chain_state, overlay_state, q) catch |e| switch (e) {
        error.UnknownAfter => return respond(a, 400, "{\"status\":\"error\",\"message\":\"after: no such token on the list\"}"),
        else => return e,
    });
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
///   `<token>/holders` (0.15.0) 200 JSON `{count, rows: [{address, balance}], supply, authorities, burned, burns}`
///                     (the counters 0.17.0) largest first, `?limit=1..100&skip=`,
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
    if (!(try isListed(a, s, &tp.key))) return respond(a, 404, not_found);
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

/// `<token>/holders`' JSON: `{count, rows: [{address, balance}], supply, authorities, burned, burns}`
/// (0.17.0: the token's counters beside its holders).
fn holdersJson(a: Allocator, svc: *Service, tk: []const u8, network: c.chain.Network, q: HoldersQuery) ![]const u8 {
    const h = try holdersOf(a, svc, tk, network, q);
    const n = try countersOf(svc, tk);
    return jsonOf(a, .{ .count = h.count, .rows = h.rows, .supply = n.supply, .authorities = n.authorities, .burned = n.burned, .burns = n.burns });
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

/// The kernel's `events` import (skein docs/VM.md "The event index"; skein-overlay 0.25.1's vm.zig
/// declares none).
extern "skein" fn events(q: [*]const u8, len: u32, out: [*]u8, cap: u32) i32;

fn eventsImport(a: Allocator, query: Value) anyerror!Value {
    const q = try c.cbor.encode(a, query);
    return c.cbor.decode(a, try sk.result(a, events, .{ q.ptr, @as(u32, @intCast(q.len)) }));
}

fn run(a: Allocator) anyerror!void {
    const in = try sk.input(a);
    const func = in.getText("fn") orelse "";
    // 0.17.0: the step's time for the hooks (a burn's `at`).
    now_ms = in.getUint("now") orelse 0;
    // 0.18.0: the event index, and the app every name it reads or emits is under.
    events_fn = &eventsImport;
    const route = if (eql(u8, func, "tokens")) &tokensRoute else if (eql(u8, func, "token")) &tokenRoute else {
        if (sk.callArg(a, in)) |arg| try setApp(lookup.appOf(arg)) else |_| {}
        delegate = true;
        return;
    };
    const req = try sk.callArg(a, in);
    const s = sk.store();
    const app = try appOfRead(a, s, req);
    try setApp(app);
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
