//! The topic's judgement, independent of the topic contract's transport: the
//! BSV-21 rules (both forms, bsv21.zig) for the topic's token and nothing else (decided
//! 2026-10-01: the topic is the token's topic). It knows no application: any
//! output, a contract's or a wallet's, is admitted exactly when the token
//! rules admit it. What an application indexes of it (AMM's pool checks) is
//! its own lookup's judgement, not this topic's.
const std = @import("std");
const bsv21 = @import("bsv21.zig");
const name = @import("name.zig");

/// The token a topic name carries (`tm_color_<txid>_0` native,
/// `tm_color_<txid>_<vout>` legacy, name.zig), as the rules take it.
pub fn tokenIdOf(topic: []const u8) ?bsv21.TokenId {
    return fromName(name.tokenIdOf(topic) orelse return null);
}

/// The token a lookup service name carries (`ls_color_<txid>_<vout>`, name.zig), as the rules take it.
pub fn tokenIdOfLookup(service: []const u8) ?bsv21.TokenId {
    return fromName(name.tokenIdOfLookup(service) orelse return null);
}

/// The token a token id string names (`<txid>`, `<txid>_<vout>`, `<txid>.<vout>`; name.zig
/// `tokenIdOfString`), as the rules take it.
pub fn tokenIdOfString(s: []const u8) ?bsv21.TokenId {
    return fromName(name.tokenIdOfString(s) orelse return null);
}

fn fromName(n: name.TokenId) bsv21.TokenId {
    return .{ .txid = n.txid, .vout = n.vout, .kind = switch (n.kind) {
        .native => .native,
        .legacy => .legacy,
    } };
}

/// The token whose deploy output `vout` of `txid` is, or null when that output is not a valid
/// deploy (BRC-162 / BRC-161 through bsv21.zig): a binary deploy at output 0 (the token
/// `<txid>_0`), or a BRC-161 `deploy+mint` / `deploy+auth` inscription at any output (`<txid>_<vout>`).
pub fn deployOf(a: std.mem.Allocator, txid: [32]u8, vout: u32, script: []const u8) error{OutOfMemory}!?bsv21.TokenId {
    const id: bsv21.TokenId = .{ .txid = txid, .vout = vout, .kind = if (vout == 0) .native else .legacy };
    const t = (try bsv21.tokenOf(a, id, txid, vout, script)) orelse return null;
    return if (t.role == .deploy) id else null;
}

/// The discovery topic's verdict (`tm_color`): every output that is a valid deploy of
/// any token, nothing else; the coins it spends retained (a registry keeps what it admitted).
pub fn judgeDeploys(a: std.mem.Allocator, tx: bsv21.Tx, previous_coins: []const u32) !Verdict {
    var admit: std.ArrayList(u32) = .empty;
    for (tx.outputs, 0..) |o, i| {
        if ((try deployOf(a, tx.txid, @intCast(i), o.script)) != null) try admit.append(a, @intCast(i));
    }
    return .{ .outputs_to_admit = admit.items, .coins_to_retain = if (admit.items.len > 0) try a.dupe(u32, previous_coins) else &.{} };
}

/// Whether the judgement of `tx` for token `id` is complete with what it reads (0.13.0): every
/// output of the token is admitted, or refused by the one-way migration rule. When it is not (a
/// shortfall, a mint or authority output with no authority in), an input whose source the caller
/// cannot read might be the token's — the topic is then undecided, not rejected (color_topic.zig).
pub fn complete(a: std.mem.Allocator, id: bsv21.TokenId, tx: bsv21.Tx, previous_coins: []const u32) !bool {
    const j = try bsv21.judge(a, id, tx, previous_coins);
    var n: usize = 0;
    for (tx.outputs, 0..) |o, i| {
        if ((try bsv21.tokenOf(a, id, tx.txid, @intCast(i), o.script)) != null) n += 1;
    }
    return j.outputs.len + j.refused.len >= n;
}

pub const Verdict = struct {
    outputs_to_admit: []const u32 = &.{},
    coins_to_retain: []const u32 = &.{},
    /// Why nothing was admitted, when the transaction was rejected.
    rejected: ?Reason = null,

    pub const Reason = enum { inflation };
};

/// Judge `tx` for token `id`: admit its valid token outputs and retain the
/// token coins it spends, or, when it breaks the token rules, admit and
/// retain nothing.
pub fn judge(a: std.mem.Allocator, id: bsv21.TokenId, tx: bsv21.Tx, previous_coins: []const u32) !Verdict {
    const j = try bsv21.judge(a, id, tx, previous_coins);
    if (!j.ok) return .{ .rejected = .inflation };

    const admit = try a.alloc(u32, j.outputs.len);
    for (j.outputs, admit) |o, *x| x.* = o.index;
    const retain = try a.alloc(u32, j.inputs.len);
    for (j.inputs, retain) |i, *x| x.* = i.index;
    return .{ .outputs_to_admit = admit, .coins_to_retain = retain };
}
