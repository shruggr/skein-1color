//! The BSV-21 rules for one token over one transaction: one rule set over a
//! form-agnostic view of the token's inputs and outputs (`Token`: role,
//! amount, id), fed by either decoder, BRC-162 binary (brc162.zig) or
//! BRC-161 JSON (brc161.zig). They work on parsed transactions (`Tx`), not
//! on how the topic contract hands them over.
//!
//! Which form an output is: binary when it carries a valid BRC-162 prefix
//! (binary wins, BRC-162 "Wire format"), else JSON when it carries a valid
//! bsv-20 inscription, else not a token output.
//!
//! Which outputs are this token's (`tokenOf`), by its deploy output (BRC-162
//! "Token identification"):
//! - deployed at output 0 (`tm_color_<txid>_0`): the genesis is output 0 of the
//!   deploy txid, a BRC-162 deploy or a BRC-161 `deploy+mint` /
//!   `deploy+auth` inscription (the same token in both forms); later outputs
//!   are binary with the 32-byte id, or JSON with `id` `<txid>_0`. A token
//!   deployed in binary never has a JSON output admitted: its coins are
//!   binary, and the one-way migration rule refuses JSON beside them.
//! - deployed under BRC-161 at a non-zero output (`tm_color_<txid>_<vout>`): the
//!   genesis is the inscription at the deploy outpoint (a binary deploy is
//!   never its genesis); later outputs are JSON with `id` `<txid>_<vout>`, or
//!   binary with the 36-byte id.
//!
//! The rules (BRC-162 and BRC-161 "Validation rules"):
//! - Deploy: the genesis, admitted unconditionally.
//! - Authority (binary amount 0, JSON `auth`): only when the transaction
//!   spends an authority of this token (an authority output, a binary deploy
//!   with amount 0, or a JSON `deploy+auth`).
//! - Mint: a JSON `mint` output only when the transaction spends an
//!   authority, never balance-checked; a binary value output is a mint
//!   exactly when the transaction spends an authority (BRC-162).
//! - Balance: every other value output (a binary value output without an
//!   authority input, a JSON `transfer`) and every JSON `burn` output is
//!   balance-checked, all of them together across both forms: with `I` the
//!   value inputs (binary value or deploy, JSON `deploy+mint`, `mint`,
//!   `transfer`; authority and burn inputs contribute 0) and `O` their sum,
//!   they are admitted when `I >= O`, all or none. When `O > I` they are all
//!   invalid and the inputs are burned. An authority input does not relax
//!   this for JSON `transfer` and `burn` outputs (BRC-161), which is the
//!   one place the forms differ. Any excess `I - O` is an implicit burn.
//! - One-way migration (per token id per transaction): when any of the
//!   token's inputs is binary, a JSON output of the token is not admitted
//!   (`refused`) and counts for nothing: the amount it claims is not in `O`,
//!   so it is implicitly burned like any other shortfall. JSON-only inputs
//!   may produce JSON, binary or mixed outputs; value is conserved across
//!   forms.
//! - A transaction whose balance-checked outputs fail and which has no other
//!   admissible output of the token (no mint, authority or deploy) breaks the
//!   rules: it admits nothing and retains nothing (`ok = false`). Otherwise
//!   the valid outputs stand and the token's inputs are retained.
//!
//! Inputs count only when they are previous coins (outputs of this token the
//! topic holds). A JSON `burn` input is not one of the token's inputs (it
//! carries nothing; 1sat-stack does not retain it either).
const std = @import("std");
const brc162 = @import("brc162.zig");
const brc161 = @import("brc161.zig");

/// Where a token was deployed (name.zig's `Kind`, repeated here so this file imports no other
/// file of this package but the decoders): `native` at output 0, in either form; `legacy` under
/// BRC-161 at a non-zero output. The rules read the deploy output, not this.
pub const Kind = enum { native, legacy };

/// A token: its deploy outpoint and how it was deployed.
pub const TokenId = struct {
    /// The deploy txid, internal byte order.
    txid: [32]u8,
    /// The deploy output; always 0 for a native token.
    vout: u32 = 0,
    kind: Kind = .native,

    pub fn wire(self: TokenId) brc162.Id {
        return .{ .txid = self.txid, .vout = self.vout };
    }
};

pub const Form = enum { binary, json };

pub const Role = enum {
    /// The token's genesis (binary deploy, JSON `deploy+mint` / `deploy+auth`).
    deploy,
    /// Token value (binary amount > 0, JSON `mint` / `transfer`).
    value,
    /// Minting authority (binary amount 0, JSON `auth`).
    authority,
    /// A JSON `burn`: admitted for supply accounting, spends as nothing.
    burn,
};

/// A token output in either form, as the rules see it.
pub const Token = struct {
    form: Form,
    role: Role,
    amount: u64 = 0,
    /// Is, or when spent grants, minting authority: an authority output, or a
    /// deploy that creates the first authority (binary amount 0, JSON
    /// `deploy+auth`).
    authority: bool = false,
    /// A JSON `mint` output: created by an authority, never balance-checked.
    mint: bool = false,
    /// The BRC-162 record, for a binary output.
    binary: ?brc162.Token = null,
    /// The BRC-161 record, for a JSON output.
    json: ?brc161.Token = null,
};

pub const Output = struct {
    script: []const u8,
    satoshis: u64,
};

pub const Input = struct {
    /// The spent outpoint (txid in internal byte order).
    txid: [32]u8,
    vout: u32,
    /// The output it spends, when known. Required for previous coins.
    source: ?Output = null,
    /// This input's unlocking script. The rules do not read it; an
    /// application's own checks may (AMM's: the method a pool spend selects).
    unlocking_script: []const u8 = &.{},
};

/// A transaction as the rules see it.
pub const Tx = struct {
    /// Internal byte order.
    txid: [32]u8,
    inputs: []const Input,
    outputs: []const Output,
};

pub const Indexed = struct {
    index: u32,
    token: Token,
};

pub const Judgement = struct {
    /// False when the transaction breaks the rules (its balance-checked
    /// outputs exceed its value inputs and nothing else of the token is
    /// admissible): it admits nothing and retains nothing.
    ok: bool,
    /// The token's inputs (previous coins of this token), in input order.
    inputs: []const Indexed,
    /// The token's outputs that are admitted (empty unless ok).
    outputs: []const Indexed,
    /// JSON outputs of the token refused by the one-way migration rule (the
    /// transaction spends a binary input of the token).
    refused: []const u32 = &.{},
    /// Whether the transaction spends an authority of this token.
    minted: bool = false,
    /// Value inputs not carried by admitted balance-checked outputs (implicit
    /// burn; all of `I` when those outputs fail). Explicit JSON `burn`
    /// outputs are not counted here.
    burned: u128 = 0,
};

pub const Error = error{ MissingSource, OutOfMemory };

/// This token's record for an output of `txid` at `vout`, or null when the
/// script is not an output of token `id` there (see the file comment).
pub fn tokenOf(a: std.mem.Allocator, id: TokenId, txid: [32]u8, vout: u32, script: []const u8) error{OutOfMemory}!?Token {
    // Binary wins, even when the binary output is another token's.
    if (brc162.decode(script)) |b| {
        const role: Role = if (b.id) |bid| blk: {
            if (!bid.eql(id.wire())) return null;
            break :blk if (b.role == .authority) .authority else .value;
        } else blk: {
            // A binary deploy is the genesis of a token deployed at output 0 only.
            if (id.vout != 0 or vout != 0 or !std.mem.eql(u8, &txid, &id.txid)) return null;
            break :blk .deploy;
        };
        return .{ .form = .binary, .role = role, .amount = b.amount, .authority = b.amount == 0, .binary = b };
    }
    const j = (try brc161.decode(a, script)) orelse return null;
    if (j.op.isDeploy()) {
        if (vout != id.vout or !std.mem.eql(u8, &txid, &id.txid)) return null;
    } else if (!j.id.?.eql(id.wire())) return null;
    var t: Token = .{ .form = .json, .role = undefined, .amount = j.amount, .json = j };
    switch (j.op) {
        .deploy_mint => t.role = .deploy,
        .deploy_auth => {
            t.role = .deploy;
            t.authority = true;
        },
        .mint => {
            t.role = .value;
            t.mint = true;
        },
        .transfer => t.role = .value,
        .auth => {
            t.role = .authority;
            t.authority = true;
        },
        .burn => t.role = .burn,
    }
    return t;
}

fn lessThan(_: void, x: u32, y: u32) bool {
    return x < y;
}

/// Judge `tx` for token `id`, given which of its inputs are previous coins.
pub fn judge(a: std.mem.Allocator, id: TokenId, tx: Tx, previous_coins: []const u32) Error!Judgement {
    const coins = try a.dupe(u32, previous_coins);
    std.mem.sort(u32, coins, {}, lessThan);

    var ins: std.ArrayList(Indexed) = .empty;
    var authority_in = false;
    var binary_in = false;
    var value_in: u128 = 0;
    for (coins, 0..) |i, k| {
        if (k > 0 and coins[k - 1] == i) continue;
        if (i >= tx.inputs.len) continue;
        const in = tx.inputs[i];
        const src = in.source orelse return error.MissingSource;
        const t = (try tokenOf(a, id, in.txid, in.vout, src.script)) orelse continue;
        if (t.role == .burn) continue; // a burn carries nothing
        try ins.append(a, .{ .index = i, .token = t });
        if (t.form == .binary) binary_in = true;
        if (t.authority) authority_in = true else value_in += t.amount;
    }

    // Candidates, in output order, with whether each is balance-checked.
    const Candidate = struct { out: Indexed, checked: bool };
    var cands: std.ArrayList(Candidate) = .empty;
    var refused: std.ArrayList(u32) = .empty;
    var checked_out: u128 = 0;
    for (tx.outputs, 0..) |o, i| {
        const t = (try tokenOf(a, id, tx.txid, @intCast(i), o.script)) orelse continue;
        if (t.form == .json and binary_in) {
            try refused.append(a, @intCast(i)); // one-way migration
            continue;
        }
        const checked = switch (t.role) {
            .deploy => false,
            .authority => if (authority_in) false else continue,
            .value => if (t.mint)
                (if (authority_in) false else continue)
            else
                !(t.form == .binary and authority_in),
            .burn => true,
        };
        if (checked) checked_out += t.amount;
        try cands.append(a, .{ .out = .{ .index = @intCast(i), .token = t }, .checked = checked });
    }

    const covered = checked_out <= value_in;
    var outs: std.ArrayList(Indexed) = .empty;
    for (cands.items) |c| if (covered or !c.checked) try outs.append(a, c.out);
    if (!covered and outs.items.len == 0) return .{ .ok = false, .inputs = ins.items, .outputs = &.{}, .refused = refused.items };
    return .{
        .ok = true,
        .inputs = ins.items,
        .outputs = outs.items,
        .refused = refused.items,
        .minted = authority_in,
        .burned = if (covered) value_in - checked_out else value_in,
    };
}
