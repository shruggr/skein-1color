//! skein-1color, natively. Moved from amm-poc programs/amm-topic (its
//! test.zig, less the pool library's tests, which stay with AMM): decoder
//! vectors, the BSV-21 rules on hand-built transactions, the topic's verdict
//! on the transactions amm-poc's gen/main.go builds from its Pool contract
//! (src/fixtures/vectors.zig: a contract output is a token output like any
//! other), and the program end to end through the topic contract's `judge`,
//! reading the subject and its previous coins' sources as records from a
//! store. Then the lookup service's three queries over its hooks.
const std = @import("std");
const w = @import("chain");
const topic = @import("topic");
const color = @import("1color");
const brc162 = color.brc162;
const brc161 = color.brc161;
const bsv21 = color.bsv21;
const token = color.token;
const names = color.name;
const program = @import("src/color_topic.zig");
const vec = @import("src/fixtures/vectors.zig");

const bsvz = w.bsvz;
const testing = std.testing;
const Value = w.cbor.Value;

fn unhex(a: std.mem.Allocator, h: []const u8) []u8 {
    const out = a.alloc(u8, h.len / 2) catch @panic("OOM");
    _ = std.fmt.hexToBytes(out, h) catch @panic("bad hex");
    return out;
}

fn cat(a: std.mem.Allocator, parts: []const []const u8) []u8 {
    return std.mem.concat(a, u8, parts) catch @panic("OOM");
}

const id_a: [32]u8 = .{0xa5} ** 32;
/// Token id_a as a native (BRC-162) token.
const tid_a: bsv21.TokenId = .{ .txid = id_a };
const p2pkh_lock = [_]u8{ 0x76, 0xa9, 0x14 } ++ [_]u8{0x33} ** 20 ++ [_]u8{ 0x88, 0xac };

/// A BRC-162 token script: id (null = OP_0), amount, optional payload push, P2PKH.
fn tokenScript(a: std.mem.Allocator, id: ?[32]u8, amount: u64, payload: ?[]const u8) []u8 {
    var buf: [10]u8 = undefined;
    const idp: []const u8 = if (id) |x| cat(a, &.{ &.{0x20}, &x }) else &.{0x00};
    const pl: []const u8 = if (payload) |p| cat(a, &.{ p, &.{0x75} }) else &.{};
    return cat(a, &.{ idp, brc162.pushAmount(&buf, amount), &.{0x6d}, pl, &p2pkh_lock });
}

// --- the decoder ---

test "decoder: value, deploy, authority" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = brc162.decode(tokenScript(a, id_a, 5000, null)).?;
    try testing.expectEqual(brc162.Role.value, v.role);
    try testing.expectEqual(@as(u64, 5000), v.amount);
    try testing.expectEqualSlices(u8, &id_a, &v.id.?.txid);
    try testing.expectEqual(@as(u32, 0), v.id.?.vout);
    try testing.expectEqualSlices(u8, &p2pkh_lock, v.lock);
    try testing.expect(v.payload == null);

    const small = brc162.decode(tokenScript(a, id_a, 7, null)).?; // OP_7
    try testing.expectEqual(@as(u64, 7), small.amount);

    // 16 (OP_16, the top of the OP_1..OP_16 range) and 17 (the smallest
    // amount that must use a direct push, minimally: `01 11`).
    const sixteen = brc162.decode(tokenScript(a, id_a, 16, null)).?;
    try testing.expectEqual(@as(u64, 16), sixteen.amount);
    const seventeen = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x11, 0x6d }, &p2pkh_lock });
    try testing.expectEqual(@as(u64, 17), brc162.decode(seventeen).?.amount);

    const d = brc162.decode(tokenScript(a, null, 21_000_000, null)).?;
    try testing.expectEqual(brc162.Role.deploy, d.role);
    try testing.expect(d.id == null);
    try testing.expectEqual(@as(u64, 21_000_000), d.amount);

    const d0 = brc162.decode(tokenScript(a, null, 0, null)).?;
    try testing.expectEqual(brc162.Role.deploy, d0.role);
    try testing.expect(d0.isAuthority());

    const auth = brc162.decode(tokenScript(a, id_a, 0, null)).?;
    try testing.expectEqual(brc162.Role.authority, auth.role);
    try testing.expectEqual(@as(u64, 0), auth.amount);

    // A 36-byte id (a legacy token deployed at a non-zero output): txid ‖ LE vout.
    const id36 = [_]u8{0xa5} ** 32 ++ [_]u8{ 7, 1, 0, 0 };
    const l = brc162.decode(cat(a, &.{ &.{0x24}, &id36, &.{ 0x55, 0x6d }, &p2pkh_lock })).?;
    try testing.expectEqualSlices(u8, &id_a, &l.id.?.txid);
    try testing.expectEqual(@as(u32, 263), l.id.?.vout);
    try testing.expectEqual(@as(u64, 5), l.amount);
    var ib: [37]u8 = undefined;
    try testing.expectEqualSlices(u8, &([_]u8{0x24} ++ id36), brc162.pushId(&ib, l.id.?));
    try testing.expectEqualSlices(u8, &([_]u8{0x20} ++ id_a), brc162.pushId(&ib, .{ .txid = id_a }));

    // The largest amount, 2^64 - 1, in nine bytes.
    const max = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x6d }, &p2pkh_lock });
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), brc162.decode(max).?.amount);
}

test "decoder: payloads are recorded, never validated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cbor_map = [_]u8{ 0x04, 0xa1, 0x61, 0x78, 0x01 }; // push {"x": 1}
    const t = brc162.decode(tokenScript(a, null, 1000, &cbor_map)).?;
    try testing.expectEqualSlices(u8, cbor_map[1..], t.payload.?);
    try testing.expectEqualSlices(u8, &p2pkh_lock, t.lock);

    // OP_0 OP_DROP: an empty payload; PUSHDATA1 works too.
    try testing.expectEqual(@as(usize, 0), brc162.decode(tokenScript(a, id_a, 5, &.{0x00})).?.payload.?.len);
    const big = cat(a, &.{ &.{ 0x4c, 0x50 }, &([_]u8{0xee} ** 0x50) });
    const tb = brc162.decode(tokenScript(a, id_a, 5, big)).?;
    try testing.expectEqual(@as(usize, 0x50), tb.payload.?.len);
    try testing.expectEqualSlices(u8, &p2pkh_lock, tb.lock);

    // A push not followed by OP_DROP is lock, not payload.
    const no = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x55, 0x6d, 0x01, 0x07, 0x76 } });
    const tn = brc162.decode(no).?;
    try testing.expect(tn.payload == null);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x07, 0x76 }, tn.lock);
}

test "decoder: rejected shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 36-byte id with vout 0 is non-canonical (that id is 32 bytes).
    const id36_0 = [_]u8{0xa5} ** 32 ++ [_]u8{ 0, 0, 0, 0 };
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x24}, &id36_0, &.{ 0x55, 0x6d }, &p2pkh_lock })) == null);
    // A 36-byte id through PUSHDATA1; ids of other lengths.
    const id36 = [_]u8{0xa5} ** 32 ++ [_]u8{ 1, 0, 0, 0 };
    try testing.expect(brc162.decode(cat(a, &.{ &.{ 0x4c, 0x24 }, &id36, &.{ 0x55, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x21}, &id_a, &.{ 0, 0x55, 0x6d }, &p2pkh_lock })) == null);
    // A 32-byte id through a non-minimal PUSHDATA1.
    try testing.expect(brc162.decode(cat(a, &.{ &.{ 0x4c, 0x20 }, &id_a, &.{ 0x55, 0x6d }, &p2pkh_lock })) == null);
    // Non-minimal amounts: 5 with a trailing zero byte; zero as a one-byte push.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x02, 0x05, 0x00, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x00, 0x6d }, &p2pkh_lock })) == null);
    // A direct push of 1..16 is not minimal for the whole push (MINIMALDATA):
    // 5 and 16 must be OP_5 and OP_16.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x05, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x10, 0x6d }, &p2pkh_lock })) == null);
    // Negative amounts.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x85, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x4f, 0x6d }, &p2pkh_lock })) == null);
    // Above 2^64 - 1.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x6d }, &p2pkh_lock })) == null);
    // No OP_2DROP; a plain P2PKH; truncated.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x55, 0x75 }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(&p2pkh_lock) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, id_a[0..10] })) == null);
}

// --- the BSV-21 rules ---

const Coin = struct { txid: [32]u8, vout: u32 = 0, script: []const u8 };

fn txOf(a: std.mem.Allocator, txid: [32]u8, ins: []const Coin, outs: []const []const u8) bsv21.Tx {
    const inputs = a.alloc(bsv21.Input, ins.len) catch @panic("OOM");
    for (ins, inputs) |c, *x| x.* = .{ .txid = c.txid, .vout = c.vout, .source = .{ .script = c.script, .satoshis = 1 } };
    const outputs = a.alloc(bsv21.Output, outs.len) catch @panic("OOM");
    for (outs, outputs) |s, *x| x.* = .{ .script = s, .satoshis = 1 };
    return .{ .txid = txid, .inputs = inputs, .outputs = outputs };
}

fn all(n: u32) []const u32 {
    const S = struct {
        const xs = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    };
    return S.xs[0..n];
}

test "bsv21: transfers conserve value; a shortfall is an implicit burn; an excess admits nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = struct {
        fn v(al: std.mem.Allocator, n: u64) []u8 {
            return tokenScript(al, id_a, n, null);
        }
    };
    const tx1 = [_]u8{1} ** 32;

    // In 1000 + 500, out 800 + 600 + 100, plus a plain output.
    const ok = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.v(a, 1000) }, .{ .txid = .{3} ** 32, .script = t.v(a, 500) } }, &.{ t.v(a, 800), t.v(a, 600), &p2pkh_lock, t.v(a, 100) });
    const v1 = try token.judge(a, tid_a, ok, all(2));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3 }, v1.outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v1.coins_to_retain);

    // In 500, out 300 + 400: nothing admitted, nothing retained.
    const over = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = t.v(a, 500) }}, &.{ t.v(a, 300), t.v(a, 400) });
    const v2 = try token.judge(a, tid_a, over, all(1));
    try testing.expectEqual(@as(usize, 0), v2.outputs_to_admit.len);
    try testing.expectEqual(@as(usize, 0), v2.coins_to_retain.len);
    try testing.expectEqual(token.Verdict.Reason.inflation, v2.rejected.?);

    // In 1000, out 250: 750 burned.
    const burn = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = t.v(a, 1000) }}, &.{t.v(a, 250)});
    const j = try bsv21.judge(a, tid_a, burn, all(1));
    try testing.expect(j.ok);
    try testing.expectEqual(@as(u128, 750), j.burned);
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, burn, all(1))).outputs_to_admit);

    // An input that is not a previous coin does not count.
    const not_coin = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.v(a, 500) }, .{ .txid = .{3} ** 32, .script = t.v(a, 500) } }, &.{t.v(a, 1000)});
    try testing.expect((try token.judge(a, tid_a, not_coin, &.{0})).rejected != null);
    try testing.expect((try token.judge(a, tid_a, not_coin, &.{ 1, 0 })).rejected == null);

    // Another token's outputs are not this topic's.
    const other = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = t.v(a, 500) }}, &.{ t.v(a, 500), tokenScript(a, .{0x5a} ** 32, 900, null) });
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, other, all(1))).outputs_to_admit);

    // A previous coin without its source cannot be judged.
    var missing = ok;
    const ins = try a.dupe(bsv21.Input, ok.inputs);
    ins[0].source = null;
    missing.inputs = ins;
    try testing.expectError(error.MissingSource, token.judge(a, tid_a, missing, all(2)));
}

test "bsv21: mint through an authority input; authority outputs need one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tx1 = [_]u8{1} ** 32;
    const auth = tokenScript(a, id_a, 0, null);

    // In: authority. Out: value 1,000,000 + authority.
    const mint = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = auth }}, &.{ tokenScript(a, id_a, 1_000_000, null), auth });
    const j = try bsv21.judge(a, tid_a, mint, all(1));
    try testing.expect(j.ok and j.minted);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try token.judge(a, tid_a, mint, all(1))).outputs_to_admit);

    // The genesis authority (a zero-amount deploy, spent from the deploy txid:0) mints too.
    const genesis = txOf(a, tx1, &.{.{ .txid = id_a, .script = tokenScript(a, null, 0, null) }}, &.{tokenScript(a, id_a, 42, null)});
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, genesis, all(1))).outputs_to_admit);

    // Without the authority input the same outputs inflate: nothing admitted.
    const plain = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = tokenScript(a, id_a, 10, null) }}, &.{ tokenScript(a, id_a, 1_000_000, null), auth });
    try testing.expectEqual(@as(usize, 0), (try token.judge(a, tid_a, plain, all(1))).outputs_to_admit.len);

    // A covered transfer with a stray authority output: the authority is left out.
    const stray = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = tokenScript(a, id_a, 10, null) }}, &.{ tokenScript(a, id_a, 10, null), auth });
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, stray, all(1))).outputs_to_admit);
}

test "bsv21: a deploy is admitted at output 0 of the token's own transaction only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = tokenScript(a, null, 10_000, null);

    const deploy = txOf(a, id_a, &.{.{ .txid = .{9} ** 32, .script = &p2pkh_lock }}, &.{ d, &p2pkh_lock });
    const v = try token.judge(a, tid_a, deploy, &.{});
    try testing.expectEqualSlices(u32, &.{0}, v.outputs_to_admit);

    // At output 1 it is not a deploy.
    const late = txOf(a, id_a, &.{}, &.{ &p2pkh_lock, d });
    try testing.expectEqual(@as(usize, 0), (try token.judge(a, tid_a, late, &.{})).outputs_to_admit.len);
    // Another transaction's deploy is another token.
    const other = txOf(a, .{7} ** 32, &.{}, &.{d});
    try testing.expectEqual(@as(usize, 0), (try token.judge(a, tid_a, other, &.{})).outputs_to_admit.len);
}

// --- BRC-161 (JSON, legacy) ---

/// A 1Sat ord envelope (content type `ct`, body `body`) before `lock`.
fn inscription(a: std.mem.Allocator, ct: []const u8, body: []const u8, lock: []const u8) []u8 {
    return cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, ct), &.{0x00}, pushOf(a, body), &.{0x68}, lock });
}

fn pushOf(a: std.mem.Allocator, data: []const u8) []u8 {
    if (data.len < 0x4c) return cat(a, &.{ &.{@intCast(data.len)}, data });
    if (data.len <= 0xff) return cat(a, &.{ &.{ 0x4c, @intCast(data.len) }, data });
    return cat(a, &.{ &.{ 0x4d, @intCast(data.len & 0xff), @intCast(data.len >> 8) }, data });
}

/// A bsv-20 output before a P2PKH lock.
fn bsv20(a: std.mem.Allocator, body: []const u8) []u8 {
    return inscription(a, brc161.content_type, body, &p2pkh_lock);
}

fn idString(a: std.mem.Allocator, txid: [32]u8, vout: u32) []const u8 {
    return std.fmt.allocPrint(a, "{s}_{d}", .{ &w.header.toHex(txid), vout }) catch @panic("OOM");
}

fn jsonOp(a: std.mem.Allocator, op: []const u8, txid: [32]u8, vout: u32, amt: ?u64) []u8 {
    const id = idString(a, txid, vout);
    return bsv20(a, if (amt) |n|
        std.fmt.allocPrint(a, "{{\"p\":\"bsv-20\",\"op\":\"{s}\",\"id\":\"{s}\",\"amt\":\"{d}\"}}", .{ op, id, n }) catch @panic("OOM")
    else
        std.fmt.allocPrint(a, "{{\"p\":\"bsv-20\",\"op\":\"{s}\",\"id\":\"{s}\"}}", .{ op, id }) catch @panic("OOM"));
}

fn decodeBody(a: std.mem.Allocator, body: []const u8) !?brc161.Token {
    return brc161.decode(a, bsv20(a, body));
}

test "brc161: the envelope, where 1sat-stack finds it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ "_3\",\"amt\":\"42\"}";

    // Before the lock (as 1sat-stack writes it) and after it.
    const before = (try brc161.decode(a, bsv20(a, body))).?;
    try testing.expectEqual(brc161.Op.transfer, before.op);
    try testing.expectEqual(@as(u64, 42), before.amount);
    try testing.expectEqual(@as(u32, 3), before.id.?.vout);
    try testing.expectEqual(@as(u8, 0xab), before.id.?.txid[0]);
    try testing.expectEqual(@as(usize, 0), before.prefix.len);
    try testing.expectEqualSlices(u8, &p2pkh_lock, before.suffix);
    const suffixed = cat(a, &.{ &p2pkh_lock, inscription(a, brc161.content_type, body, &.{}) });
    const t2 = (try brc161.decode(a, suffixed)).?;
    try testing.expectEqualSlices(u8, &p2pkh_lock, t2.prefix);
    try testing.expectEqual(@as(usize, 0), t2.suffix.len);

    // Named fields (a multi-byte tag) are skipped; content type 1 may repeat
    // (the last wins); a one-byte push tag works like OP_1.
    const named = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x02, 'x', 'y', 0x01, 0x07, 0x51, 0x04, 't', 'e', 'x', 't', 0x01, 0x01 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68}, &p2pkh_lock });
    try testing.expect((try brc161.decode(a, named)) != null);
    // The content followed by the end of the script (no OP_ENDIF) is still an envelope.
    const open_end = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body) });
    try testing.expect((try brc161.decode(a, open_end)) != null);

    // Not an envelope: anything but OP_ENDIF after the content; "ord" not
    // preceded by OP_0 OP_IF; "ord" through PUSHDATA1; a non-push tag.
    const no_endif = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x76}, &p2pkh_lock });
    try testing.expect((try brc161.decode(a, no_endif)) == null);
    const no_if = cat(a, &.{ &.{ 0x00, 0x00, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, no_if)) == null);
    const pd1 = cat(a, &.{ &.{ 0x00, 0x63, 0x4c, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, pd1)) == null);
    const bad_tag = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x76 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, bad_tag)) == null);
    // Another content type; no content type.
    try testing.expect((try brc161.decode(a, inscription(a, "application/json", body, &p2pkh_lock))) == null);
    const no_ct = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x00 }, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, no_ct)) == null);
}

test "brc161: the body's field rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "\"" ++ "ab" ** 32 ++ "_0\"";

    const dm = (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"21000000\",\"sym\":\"GOLD\",\"dec\":\"8\",\"icon\":\"_0\",\"id\":\"junk\"}")).?;
    try testing.expectEqual(brc161.Op.deploy_mint, dm.op);
    try testing.expectEqual(@as(u64, 21_000_000), dm.amount);
    try testing.expect(dm.id == null); // ignored on a deploy
    try testing.expectEqualStrings("GOLD", dm.sym.?);
    try testing.expectEqual(@as(u8, 8), dm.dec.?);
    try testing.expectEqualStrings("_0", dm.icon.?);
    const da = (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+auth\"}")).?;
    try testing.expectEqual(brc161.Op.deploy_auth, da.op);
    try testing.expectEqual(@as(u64, 0), da.amount);
    try testing.expectEqual(brc161.Op.auth, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"auth\",\"id\":" ++ id ++ "}")).?.op);
    try testing.expectEqual(brc161.Op.mint, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"mint\",\"id\":" ++ id ++ ",\"amt\":\"5\"}")).?.op);
    try testing.expectEqual(brc161.Op.burn, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"burn\",\"id\":" ++ id ++ ",\"amt\":\"5\"}")).?.op);

    // Tolerated as 1sat-stack tolerates it: op in any case, leading zeros
    // and "0" in amt, the largest uint64, the last of duplicate keys,
    // unknown keys, whitespace.
    try testing.expectEqual(brc161.Op.transfer, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"TRANSFER\",\"id\":" ++ id ++ ",\"amt\":\"5\"}")).?.op);
    try testing.expectEqual(@as(u64, 7), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"007\"}")).?.amount);
    try testing.expectEqual(@as(u64, 0), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"0\"}")).?.amount);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"18446744073709551615\"}")).?.amount);
    try testing.expectEqual(@as(u64, 2), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\",\"amt\":\"2\"}")).?.amount);
    try testing.expect((try decodeBody(a, " { \"x\": [1, {}], \"p\": \"bsv-20\", \"op\": \"transfer\", \"id\": " ++ id ++ ", \"amt\": \"1\" } ")) != null);
    // Display fields are deploy-only and never invalidate (BRC-161; 1sat-stack
    // rejects a malformed dec): a numeric or out-of-range dec is dropped.
    try testing.expect((try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"1\",\"dec\":8}")).?.dec == null);
    try testing.expect((try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"1\",\"dec\":\"19\",\"sym\":5}")).?.sym == null);
    try testing.expect((try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\",\"dec\":\"99\"}")) != null);

    // Not a token.
    for ([_][]const u8{
        "{\"p\":\"bsv-21\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // p
        "{\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // no p
        "{\"p\":\"bsv-20\",\"op\":\"send\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // op
        "{\"p\":\"bsv-20\",\"op\":7,\"id\":" ++ id ++ ",\"amt\":\"1\"}", // op not a string
        "{\"p\":\"bsv-20\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // no op
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":1}", // numeric amt
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"-1\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"+1\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1.0\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"18446744073709551616\"}", // 2^64
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ "}", // no amt
        "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\"}", // no amt
        "{\"p\":\"bsv-20\",\"op\":\"deploy+auth\",\"amt\":\"1\"}", // amt prohibited
        "{\"p\":\"bsv-20\",\"op\":\"auth\",\"id\":" ++ id ++ ",\"amt\":null}", // amt prohibited, in any form
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"amt\":\"1\"}", // no id
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "AB" ** 32 ++ "_0\",\"amt\":\"1\"}", // uppercase id
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ ".0\",\"amt\":\"1\"}", // dot form
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ "_01\",\"amt\":\"1\"}", // leading zero
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ "\",\"amt\":\"1\"}", // no vout
        "[\"p\",\"bsv-20\"]", // not an object
        "{\"p\":\"bsv-20\",", // not JSON
    }) |body| {
        if ((try decodeBody(a, body)) != null) {
            std.debug.print("accepted: {s}\n", .{body});
            return error.TestUnexpectedResult;
        }
    }
}

test "bsv21: binary wins; a token at output 0 is one token in both forms; a legacy token at output 5 takes both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const leg0: bsv21.TokenId = .{ .txid = id_a, .vout = 0, .kind = .legacy };
    const leg5: bsv21.TokenId = .{ .txid = id_a, .vout = 5, .kind = .legacy };
    const tx1 = [_]u8{1} ** 32;

    // A binary prefix followed by a JSON inscription for the same token: binary.
    const both = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x55, 0x6d }, jsonOp(a, "transfer", id_a, 0, 99) });
    const tb = (try bsv21.tokenOf(a, leg0, tx1, 0, both)).?;
    try testing.expectEqual(bsv21.Form.binary, tb.form);
    try testing.expectEqual(@as(u64, 5), tb.amount);
    // ... and when the binary prefix is another token's, it is not this one's at all.
    const other = cat(a, &.{ &.{0x20}, &([_]u8{0x5a} ** 32), &.{ 0x55, 0x6d }, jsonOp(a, "transfer", id_a, 0, 99) });
    try testing.expect((try bsv21.tokenOf(a, leg0, tx1, 0, other)) == null);
    // A 36-byte id with vout 0 is no binary prefix, so the inscription after it counts.
    const bad36 = cat(a, &.{ &.{0x24}, &id_a, &.{ 0, 0, 0, 0, 0x55, 0x6d }, jsonOp(a, "transfer", id_a, 0, 99) });
    try testing.expectEqual(bsv21.Form.json, (try bsv21.tokenOf(a, leg0, tx1, 0, bad36)).?.form);

    // A token deployed at output 0 (BRC-162 "Token identification": one token in both forms):
    // JSON naming <txid>_0 and binary with the 32-byte id are both its.
    try testing.expectEqual(bsv21.Form.json, (try bsv21.tokenOf(a, tid_a, tx1, 0, jsonOp(a, "transfer", id_a, 0, 1))).?.form);
    try testing.expect((try bsv21.tokenOf(a, tid_a, tx1, 0, tokenScript(a, id_a, 1, null))) != null);

    // A legacy token at output 5: JSON with id <txid>_5, binary with the 36-byte id only.
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 0, jsonOp(a, "transfer", id_a, 5, 1))) != null);
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 0, jsonOp(a, "transfer", id_a, 0, 1))) == null);
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 0, tokenScript(a, id_a, 1, null))) == null);
    const b36 = cat(a, &.{ &.{0x24}, &id_a, &.{ 5, 0, 0, 0, 0x51, 0x6d }, &p2pkh_lock });
    try testing.expectEqual(bsv21.Form.binary, (try bsv21.tokenOf(a, leg5, tx1, 0, b36)).?.form);
    try testing.expect((try bsv21.tokenOf(a, leg0, tx1, 0, b36)) == null);

    // Genesis by the deploy output: at output 0 a binary or a JSON deploy (one token, either
    // form); at a non-zero output a JSON deploy only, at the deploy outpoint.
    const bdeploy = tokenScript(a, null, 100, null);
    const jdeploy = bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"100\"}");
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, tid_a, id_a, 0, bdeploy)).?.role);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, leg0, id_a, 0, bdeploy)).?.role);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, tid_a, id_a, 0, jdeploy)).?.role);
    try testing.expect((try bsv21.tokenOf(a, leg5, id_a, 5, bdeploy)) == null);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, leg0, id_a, 0, jdeploy)).?.role);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, leg5, id_a, 5, jdeploy)).?.role);
    try testing.expect((try bsv21.tokenOf(a, leg5, id_a, 4, jdeploy)) == null);
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 5, jdeploy)) == null);
    // A JSON deploy+auth is an authority; a deploy+mint of "0" is not.
    const jauth = bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+auth\"}");
    try testing.expect((try bsv21.tokenOf(a, leg0, id_a, 0, jauth)).?.authority);
    const jzero = bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"0\"}");
    try testing.expect(!(try bsv21.tokenOf(a, leg0, id_a, 0, jzero)).?.authority);
}

test "bsv21: JSON rules per BRC-161 (mint, auth, burn; authority does not fund transfers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const L: bsv21.TokenId = .{ .txid = id_a, .vout = 2, .kind = .legacy };
    const tx1 = [_]u8{1} ** 32;
    const auth = jsonOp(a, "auth", id_a, 2, null);
    const t = struct {
        fn op(al: std.mem.Allocator, o: []const u8, n: u64) []u8 {
            return jsonOp(al, o, id_a, 2, n);
        }
    };

    // Authority in; out: mint 1000, auth, and an unfunded transfer 5. The
    // authority does not fund the transfer (BRC-161), so it alone is left
    // out; the mint and the auth stand.
    const m = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = auth }}, &.{ t.op(a, "mint", 1000), auth, t.op(a, "transfer", 5) });
    const jm = try bsv21.judge(a, L, m, all(1));
    try testing.expect(jm.ok and jm.minted);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try token.judge(a, L, m, all(1))).outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, L, m, all(1))).coins_to_retain);
    // Binary value outputs alongside the same authority are mints (BRC-162).
    var b36: [37]u8 = undefined;
    const bin = cat(a, &.{ brc162.pushId(&b36, L.wire()), &.{ 0x55, 0x6d }, &p2pkh_lock });
    const mb = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = auth }}, &.{ bin, t.op(a, "transfer", 5) });
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, L, mb, all(1))).outputs_to_admit);

    // A mint without an authority input is left out; the covered transfer stands.
    const v = t.op(a, "transfer", 100);
    const nm = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{ t.op(a, "mint", 1000), t.op(a, "transfer", 60) });
    try testing.expectEqualSlices(u32, &.{1}, (try token.judge(a, L, nm, all(1))).outputs_to_admit);
    // An auth output without one too: here nothing is left, but nothing broke the balance.
    const na = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{auth});
    const vna = try token.judge(a, L, na, all(1));
    try testing.expect(vna.rejected == null and vna.outputs_to_admit.len == 0);

    // Burns: balance-checked with transfers (I >= O_t + O_b), admitted.
    const burn = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{ t.op(a, "transfer", 60), t.op(a, "burn", 40) });
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try token.judge(a, L, burn, all(1))).outputs_to_admit);
    const over = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{ t.op(a, "transfer", 60), t.op(a, "burn", 41) });
    try testing.expectEqual(token.Verdict.Reason.inflation, (try token.judge(a, L, over, all(1))).rejected.?);
    // A burn input carries nothing and is not one of the token's inputs.
    const spend_burn = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.op(a, "burn", 40) }, .{ .txid = .{3} ** 32, .script = v } }, &.{t.op(a, "transfer", 140)});
    try testing.expect((try token.judge(a, L, spend_burn, all(2))).rejected != null);
    const ok_burn = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.op(a, "burn", 40) }, .{ .txid = .{3} ** 32, .script = v } }, &.{t.op(a, "transfer", 100)});
    const vb = try token.judge(a, L, ok_burn, all(2));
    try testing.expectEqualSlices(u32, &.{0}, vb.outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{1}, vb.coins_to_retain);
}

// --- the pool, on gen/main.go's transactions ---

const Fixtures = struct {
    txs: std.AutoHashMap([32]u8, bsvz.transaction.Transaction),
    raws: std.StringHashMap([]const u8),
    id: [32]u8,

    fn init(a: std.mem.Allocator) !Fixtures {
        var f: Fixtures = .{ .txs = .init(a), .raws = .init(a), .id = undefined };
        inline for (.{
            "fund",         "token_deploy",       "pool_deploy",        "swap_bsv_in",     "swap_tokens_in",  "remove_liquidity",
            "legacy_fund",  "legacy_deploy0",     "legacy_deploy1",     "legacy_transfer", "legacy_migrate0", "legacy_migrate1",
            "legacy_mixed", "legacy_binary_json", "legacy_auth_deploy", "legacy_mint",     "legacy_unfunded",
        }) |name| {
            const raw = unhex(a, @field(vec, name));
            try f.raws.put(name, raw);
            try f.txs.put(w.beef.txidOf(raw), try bsvz.transaction.Transaction.parse(a, raw));
        }
        f.id = w.beef.txidOf(f.raws.get("token_deploy").?);
        return f;
    }

    /// A fixture transaction as the rules see it, sources filled from the others.
    fn tx(self: Fixtures, a: std.mem.Allocator, name: []const u8) !bsv21.Tx {
        const raw = self.raws.get(name).?;
        const t = self.txs.get(w.beef.txidOf(raw)).?;
        const ins = try a.alloc(bsv21.Input, t.inputs.len);
        for (t.inputs, ins) |in, *x| {
            x.* = .{ .txid = in.previous_outpoint.txid.bytes, .vout = in.previous_outpoint.index, .unlocking_script = in.unlocking_script.bytes };
            if (self.txs.get(x.txid)) |src| {
                const o = src.outputs[x.vout];
                x.source = .{ .script = o.locking_script.bytes, .satoshis = @intCast(o.satoshis) };
            }
        }
        const outs = try a.alloc(bsv21.Output, t.outputs.len);
        for (t.outputs, outs) |o, *x| x.* = .{ .script = o.locking_script.bytes, .satoshis = @intCast(o.satoshis) };
        return .{ .txid = w.beef.txidOf(raw), .inputs = ins, .outputs = outs };
    }
};

fn key20(h: []const u8) [20]u8 {
    var k: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&k, h) catch unreachable;
    return k;
}

/// `tx` with output i's script replaced.
fn withOutput(a: std.mem.Allocator, tx: bsv21.Tx, i: usize, script: []const u8) !bsv21.Tx {
    const outs = try a.dupe(bsv21.Output, tx.outputs);
    outs[i].script = script;
    var t = tx;
    t.outputs = outs;
    return t;
}

test "fixtures: a contract's deploy (amm-poc's pool) admitted as token outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const tx = try f.tx(a, "pool_deploy");

    const v = try token.judge(a, .{ .txid = f.id }, tx, &.{0});
    try testing.expect(v.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, v.outputs_to_admit); // pool, the taker's 50,000, the LP's change
    try testing.expectEqualSlices(u32, &.{0}, v.coins_to_retain);
}

test "fixtures: a contract's spends (amm-poc's swaps and a liquidity removal) admitted as token outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);

    // Sats in: pool continuation (0) and the token payout (1) are admitted;
    // the LP and validator fees and the commission (2, 3, 4) and the change
    // (5) are P2PKH; the commission pays the fixture relay.
    const s1 = try f.tx(a, "swap_bsv_in");
    const v1 = try token.judge(a, .{ .txid = f.id }, s1, &.{0});
    try testing.expect(v1.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v1.outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{0}, v1.coins_to_retain);
    for (s1.outputs[2..]) |o| try testing.expect(brc162.decode(o.script) == null);
    try testing.expectEqual(@as(usize, 6), s1.outputs.len);
    try testing.expectEqual(@as(u64, (20_000 * vec.commission_bps + 9999) / 10000), s1.outputs[4].satoshis);
    try testing.expectEqualSlices(u8, &key20(vec.commission_pkh), s1.outputs[4].script[3..23]);
    try testing.expectEqual(@as(u64, vec.swap_bsv_in_tokens_out), brc162.decode(s1.outputs[1].script).?.amount);
    try testing.expectEqual(@as(u64, vec.pool1.tokens), brc162.decode(s1.outputs[0].script).?.amount);

    // Tokens in: the pool (0) and the taker's tokens (1) are spent; the pool,
    // and the LP and validator token fees and the commission (2, 3, 4) are
    // admitted; the sats payout (1) and change (5) are P2PKH.
    const s2 = try f.tx(a, "swap_tokens_in");
    const v2 = try token.judge(a, .{ .txid = f.id }, s2, &.{ 0, 1 });
    try testing.expect(v2.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 4 }, v2.outputs_to_admit);
    const c2 = brc162.decode(s2.outputs[4].script).?;
    try testing.expectEqual(@as(u64, (50_000 * vec.commission_bps + 9999) / 10000), c2.amount);
    try testing.expectEqualSlices(u8, &key20(vec.commission_pkh), c2.lock[3..23]);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v2.coins_to_retain);

    // Without the taker's token input as a previous coin, the tokens in are
    // unaccounted for: rejected.
    try testing.expect((try token.judge(a, .{ .txid = f.id }, s2, &.{0})).rejected != null);

    // RemoveLiquidity keeps the validator key: continuation (0) and the LP's
    // token withdrawal (2).
    const r = try f.tx(a, "remove_liquidity");
    const v3 = try token.judge(a, .{ .txid = f.id }, r, &.{0});
    try testing.expect(v3.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, v3.outputs_to_admit);
}

// --- the program: topic names and the topic contract ---

test "topic and lookup names (BRC-207): tm_color_<assetId>, ls_color_<assetId>; tm_color, ls_color, the old tm_<txid>_<vout> and AMM-prefixed names are not a token's; token id strings" {
    var buf: [names.max_topic_len]u8 = undefined;
    const nm = names.topicName(&buf, .{ .txid = id_a });
    try testing.expectEqualStrings("tm_color_" ++ w.header.toHex(id_a) ++ "_0", nm);
    const n = token.tokenIdOf(nm).?;
    try testing.expectEqualSlices(u8, &id_a, &n.txid);
    try testing.expectEqual(bsv21.Kind.native, n.kind);
    try testing.expectEqual(@as(u32, 0), n.vout);
    const hex = "0102030405060708091011121314151617181920212223242526272829303132";
    const rev = "tm_color_" ++ hex;
    const got = token.tokenIdOf(rev ++ "_0").?.txid;
    try testing.expectEqual(@as(u8, 0x32), got[0]);
    try testing.expectEqual(@as(u8, 0x01), got[31]);
    try testing.expect(token.tokenIdOf("tm_color_" ++ "AB" ** 32 ++ "_0") == null); // uppercase
    try testing.expect(token.tokenIdOf("tm_color_abcd") == null);
    try testing.expect(token.tokenIdOf("tm_demo") == null);
    // The discovery topic carries no asset id; its lookup neither.
    try testing.expect(token.tokenIdOf(names.deploys_topic) == null);
    try testing.expect(token.tokenIdOf("tm_color_") == null);
    try testing.expect(names.tokenIdOfLookup("ls_color_deploys") == null);
    try testing.expect(names.tokenIdOfLookup("ls_color") == null);
    // The old names are no topic: no alias (`tm_<txid>_<vout>` of 0.8.2, the bare `tm_<txid>`).
    try testing.expect(token.tokenIdOf("tm_" ++ hex ++ "_0") == null);
    try testing.expect(token.tokenIdOf("tm_" ++ hex) == null);
    try testing.expect(token.tokenIdOf(rev) == null);

    const l0 = token.tokenIdOf(rev ++ "_0").?;
    try testing.expectEqual(bsv21.Kind.native, l0.kind);
    try testing.expectEqual(@as(u32, 0), l0.vout);
    const l7 = token.tokenIdOf(rev ++ "_4294967295").?;
    try testing.expectEqual(bsv21.Kind.legacy, l7.kind);
    try testing.expectEqual(@as(u32, 4294967295), l7.vout);
    try testing.expectEqualStrings(rev ++ "_12", names.topicName(&buf, .{ .txid = got, .vout = 12, .kind = .legacy }));
    try testing.expectEqualStrings(rev ++ "_0", names.topicName(&buf, .{ .txid = got, .vout = 0, .kind = .legacy }));
    // Not canonical: leading zeros, sign, empty, too large, other separators.
    for ([_][]const u8{ "_00", "_01", "_+1", "_", "_4294967296", ".0", "_1_2", "_-1", "_ 1" }) |bad| {
        var nb: [100]u8 = undefined;
        try testing.expect(token.tokenIdOf(try std.fmt.bufPrint(&nb, "{s}{s}", .{ rev, bad })) == null);
        try testing.expect(names.tokenIdOfLookup(try std.fmt.bufPrint(&nb, "ls_color_{s}{s}", .{ hex, bad })) == null);
    }
    // The old AMM topic name.
    try testing.expect(token.tokenIdOf("tm_amm_" ++ hex ++ "_0") == null);

    // The lookup service: `ls_color_<assetId>`, the same token.
    var lb: [names.max_lookup_len]u8 = undefined;
    try testing.expectEqualStrings("ls_color_" ++ hex ++ "_7", names.lookupName(&lb, .{ .txid = got, .vout = 7, .kind = .legacy }));
    const lk = token.tokenIdOfLookup("ls_color_" ++ hex ++ "_7").?;
    try testing.expectEqualSlices(u8, &got, &lk.txid);
    try testing.expectEqual(@as(u32, 7), lk.vout);
    try testing.expect(token.tokenIdOfLookup("tm_color_" ++ hex ++ "_7") == null);
    try testing.expect(token.tokenIdOf("ls_color_" ++ hex ++ "_7") == null);

    // Token id strings, taken in every form: `<txid>`, `<txid>_<vout>`, `<txid>.<vout>`. `<txid>`,
    // `<txid>_0` and `<txid>.0` are the token at output 0; any other vout a BRC-161 one.
    for ([_][]const u8{ hex, hex ++ "_0", hex ++ ".0" }) |form| {
        const sid = names.tokenIdOfString(form).?;
        try testing.expectEqual(names.Kind.native, sid.kind);
        try testing.expectEqual(@as(u32, 0), sid.vout);
        try testing.expectEqualSlices(u8, &got, &sid.txid);
        try testing.expectEqualStrings(rev ++ "_0", names.topicName(&buf, sid));
    }
    for ([_][]const u8{ hex ++ "_3", hex ++ ".3" }) |form| {
        const sid3 = names.tokenIdOfString(form).?;
        try testing.expectEqual(names.Kind.legacy, sid3.kind);
        try testing.expectEqual(@as(u32, 3), sid3.vout);
        try testing.expectEqualStrings(rev ++ "_3", names.topicName(&buf, sid3));
    }
    for ([_][]const u8{ hex ++ "_03", hex ++ "_", hex ++ "-0", hex ++ "_4294967296", "AB" ** 32 ++ "_0", "AB" ** 32, hex[0..63] }) |bad| {
        try testing.expect(names.tokenIdOfString(bad) == null);
    }

    // Written out `<txid>_<vout>` for every token, `_0` included (BRC-162 "Token identification").
    var tb: [names.max_suffix_len]u8 = undefined;
    const at0: names.TokenId = .{ .txid = got };
    try testing.expectEqualStrings(hex ++ "_0", names.tokenIdText(&tb, at0));
    const at3: names.TokenId = .{ .txid = got, .vout = 3, .kind = .legacy };
    try testing.expectEqualStrings(hex ++ "_3", names.tokenIdText(&tb, at3));
}

fn callArgs(a: std.mem.Allocator, t: []const u8, tx_cid: []const u8, previous: []const u32) !Value {
    const pc = try a.alloc(Value, previous.len);
    for (previous, pc) |p, *v| v.* = .{ .uint = p };
    return .{ .map = try a.dupe(w.cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = t } },
        .{ .key = "tx", .value = .{ .cid = tx_cid } },
        .{ .key = "previousCoins", .value = .{ .array = pc } },
    }) };
}

fn uintsOf(a: std.mem.Allocator, v: Value) ![]u32 {
    const out = try a.alloc(u32, v.array.len);
    for (v.array, out) |x, *o| o.* = @intCast(x.uint);
    return out;
}

test "program: identify through the topic contract, reading records from a store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = names.topicName(&buf, .{ .txid = f.id });

    // The subject and its previous coins' sources, each as a bitcoin-tx block.
    var subject: []const u8 = undefined;
    inline for (.{ "fund", "token_deploy", "pool_deploy", "swap_bsv_in" }) |nm| {
        const cid = try s.putBitcoin(a, .tx, f.raws.get(nm).?);
        if (comptime std.mem.eql(u8, nm, "swap_bsv_in")) subject = cid;
    }
    const rec = try topic.judge(a, s, program.identify, try callArgs(a, tname, subject, &.{0}));
    try testing.expectEqualStrings("admittance", rec.getText("kind").?);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, try uintsOf(a, rec.get("outputsToAdmit").?));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rec.get("coinsToRetain").?));

    // The token deploy itself, with no previous coins.
    const deploy_cid = try s.putBitcoin(a, .tx, f.raws.get("token_deploy").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, tname, deploy_cid, &.{}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rd.get("outputsToAdmit").?));

    // Not a token topic: tm_demo.
    try testing.expectError(error.UnknownTopic, topic.judge(a, s, program.identify, try callArgs(a, "tm_demo", subject, &.{0})));
    // `tm_color_<txid>` without its vout is no topic, nor the old `tm_<txid>_0` (0.8.2: no alias).
    const bare = tname[0 .. tname.len - 2];
    try testing.expectError(error.UnknownTopic, topic.judge(a, s, program.identify, try callArgs(a, bare, deploy_cid, &.{})));
    const old = try std.fmt.allocPrint(a, "tm_{s}", .{tname["tm_color_".len..]});
    try testing.expectError(error.UnknownTopic, topic.judge(a, s, program.identify, try callArgs(a, old, deploy_cid, &.{})));
}

// --- legacy BRC-161 tokens and their migration, on gen/main.go's transactions ---

fn legacyId(f: Fixtures, deploy: []const u8, vout: u32) bsv21.TokenId {
    return .{ .txid = w.beef.txidOf(f.raws.get(deploy).?), .vout = vout, .kind = .legacy };
}

fn expectVerdict(a: std.mem.Allocator, f: Fixtures, id: bsv21.TokenId, name: []const u8, coins: []const u32, admit: []const u32) !void {
    const v = try token.judge(a, id, try f.tx(a, name), coins);
    try testing.expect(v.rejected == null);
    try testing.expectEqualSlices(u32, admit, v.outputs_to_admit);
    try testing.expectEqualSlices(u32, coins, v.coins_to_retain);
}

fn formsOf(a: std.mem.Allocator, f: Fixtures, id: bsv21.TokenId, name: []const u8, coins: []const u32) ![]bsv21.Form {
    const j = try bsv21.judge(a, id, try f.tx(a, name), coins);
    const out = try a.alloc(bsv21.Form, j.outputs.len);
    for (j.outputs, out) |o, *x| x.* = o.token.form;
    return out;
}

test "legacy: JSON deploys at output 0 and at a non-zero output; a JSON transfer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const L0 = legacyId(f, "legacy_deploy0", 0);
    const L1 = legacyId(f, "legacy_deploy1", 1);

    try expectVerdict(a, f, L0, "legacy_deploy0", &.{}, &.{0});
    try expectVerdict(a, f, L1, "legacy_deploy1", &.{}, &.{1});
    // deploy0 at output 0 is the token of `tm_<txid>_0` whatever the kind says (the deploy output
    // decides); deploy1's output 0 is not deploy1's token.
    try expectVerdict(a, f, .{ .txid = L0.txid }, "legacy_deploy0", &.{}, &.{0});
    try expectVerdict(a, f, .{ .txid = L1.txid, .vout = 0, .kind = .legacy }, "legacy_deploy1", &.{}, &.{});

    // deploy0:0 (1,000,000) -> 600,000 (envelope before the lock) + 400,000 (after it).
    try expectVerdict(a, f, L0, "legacy_transfer", &.{0}, &.{ 0, 1 });
    const j = try bsv21.judge(a, L0, try f.tx(a, "legacy_transfer"), &.{0});
    try testing.expectEqual(@as(u64, 600_000), j.outputs[0].token.amount);
    try testing.expectEqual(@as(usize, 0), j.outputs[0].token.json.?.prefix.len);
    try testing.expectEqual(@as(usize, 25), j.outputs[1].token.json.?.prefix.len); // the P2PKH lock first
    try testing.expectEqual(@as(u128, 0), j.burned);
    try testing.expectEqual(bsv21.Role.deploy, j.inputs[0].token.role);
}

test "legacy: migration to binary (32- and 36-byte ids), mixed outputs, and the one-way rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const L0 = legacyId(f, "legacy_deploy0", 0);
    const L1 = legacyId(f, "legacy_deploy1", 1);

    // JSON 600,000 in -> binary 350,000 + 250,000 with the 32-byte id.
    try expectVerdict(a, f, L0, "legacy_migrate0", &.{0}, &.{ 0, 1 });
    try testing.expectEqualSlices(bsv21.Form, &.{ .binary, .binary }, try formsOf(a, f, L0, "legacy_migrate0", &.{0}));
    const m0 = try f.tx(a, "legacy_migrate0");
    try testing.expectEqual(@as(u8, 0x20), m0.outputs[0].script[0]);
    try testing.expectEqualSlices(u8, &L0.txid, m0.outputs[0].script[1..33]);
    // In the native topic of the same txid those binary outputs spend no
    // coin it holds (its genesis would be a binary deploy): unfunded.
    try testing.expect((try token.judge(a, .{ .txid = L0.txid }, m0, &.{})).rejected != null);

    // JSON deploy1:1 -> binary 500,000 with the 36-byte id (txid ‖ LE 1).
    try expectVerdict(a, f, L1, "legacy_migrate1", &.{0}, &.{0});
    const m1 = try f.tx(a, "legacy_migrate1");
    try testing.expectEqual(@as(u8, 0x24), m1.outputs[0].script[0]);
    try testing.expectEqualSlices(u8, &L1.txid, m1.outputs[0].script[1..33]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, m1.outputs[0].script[33..37]);
    try testing.expectEqual(@as(u64, 500_000), (try bsv21.judge(a, L1, m1, &.{0})).outputs[0].token.amount);

    // JSON 400,000 in -> JSON 100,000 + binary 300,000: mixed, value conserved across forms.
    try expectVerdict(a, f, L0, "legacy_mixed", &.{0}, &.{ 0, 1 });
    try testing.expectEqualSlices(bsv21.Form, &.{ .json, .binary }, try formsOf(a, f, L0, "legacy_mixed", &.{0}));
    // Mixed outputs still conserve value: one more unit of JSON and the whole transfer fails.
    const mixed = try f.tx(a, "legacy_mixed");
    const more = try withOutput(a, mixed, 0, jsonOp(a, "transfer", L0.txid, 0, 100_001));
    try testing.expect((try token.judge(a, L0, more, &.{0})).rejected != null);

    // Binary 350,000 in -> binary 200,000 + JSON 150,000: the JSON output is
    // refused (one-way migration) and its 150,000 is implicitly burned.
    const bj = try bsv21.judge(a, L0, try f.tx(a, "legacy_binary_json"), &.{0});
    try testing.expect(bj.ok);
    try testing.expectEqual(@as(usize, 1), bj.outputs.len);
    try testing.expectEqual(@as(u32, 0), bj.outputs[0].index);
    try testing.expectEqualSlices(u32, &.{1}, bj.refused);
    try testing.expectEqual(@as(u128, 150_000), bj.burned);
    try expectVerdict(a, f, L0, "legacy_binary_json", &.{0}, &.{0});
    // Refused even when the JSON output alone would be covered.
    const bj_tx = try f.tx(a, "legacy_binary_json");
    const only_json = try withOutput(a, bj_tx, 0, &p2pkh_lock);
    const oj = try bsv21.judge(a, L0, only_json, &.{0});
    try testing.expect(oj.ok and oj.outputs.len == 0);
    try testing.expectEqual(@as(u128, 350_000), oj.burned);
}

test "legacy: a JSON mint from an authority; an unfunded JSON transfer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const LA = legacyId(f, "legacy_auth_deploy", 0);
    const L0 = legacyId(f, "legacy_deploy0", 0);

    try expectVerdict(a, f, LA, "legacy_auth_deploy", &.{}, &.{0});
    try expectVerdict(a, f, LA, "legacy_mint", &.{0}, &.{ 0, 1 });
    const jm = try bsv21.judge(a, LA, try f.tx(a, "legacy_mint"), &.{0});
    try testing.expect(jm.minted);
    try testing.expect(jm.outputs[0].token.mint);
    try testing.expectEqual(bsv21.Role.authority, jm.outputs[1].token.role);
    // Without the authority as a previous coin, neither output stands.
    try expectVerdict(a, f, LA, "legacy_mint", &.{}, &.{});

    // JSON 100,000 in -> 60,000 + 50,000: invalid, nothing admitted or retained.
    const u = try token.judge(a, L0, try f.tx(a, "legacy_unfunded"), &.{0});
    try testing.expectEqual(token.Verdict.Reason.inflation, u.rejected.?);
    try testing.expectEqual(@as(usize, 0), u.outputs_to_admit.len);
    try testing.expectEqual(@as(usize, 0), u.coins_to_retain.len);
}

test "program: a legacy topic tm_<txid>_<vout> through the topic contract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = names.topicName(&buf, .{ .txid = w.beef.txidOf(f.raws.get("legacy_deploy1").?), .vout = 1, .kind = .legacy });
    try testing.expect(std.mem.endsWith(u8, tname, "_1"));

    const deploy_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_deploy1").?);
    _ = try s.putBitcoin(a, .tx, f.raws.get("legacy_fund").?);
    const migrate_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_migrate1").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, tname, deploy_cid, &.{}));
    try testing.expectEqualSlices(u32, &.{1}, try uintsOf(a, rd.get("outputsToAdmit").?));
    const rm = try topic.judge(a, s, program.identify, try callArgs(a, tname, migrate_cid, &.{0}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rm.get("outputsToAdmit").?));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rm.get("coinsToRetain").?));
}

// --- the lookup service (ls_color): its hooks and its three queries ---

const ls = @import("src/color_lookup.zig");
const lookup = @import("lookup");

/// The lookup service over a store: hooks through the contract's `handle`, queries straight to `answer`.
const Ls = struct {
    a: std.mem.Allocator,
    s: w.store.Store,
    state: ?[]const u8 = null,
    service: []const u8 = ls.service_name,
    /// The events the last hook asked to be emitted (0.17.0).
    events: []const Value = &.{},

    fn uints(a: std.mem.Allocator, xs: []const u32) ![]Value {
        const out = try a.alloc(Value, xs.len);
        for (xs, out) |x, *o| o.* = .{ .uint = x };
        return out;
    }

    fn hook(self: *Ls, func: []const u8, t: []const u8, rest: []const w.cbor.Entry) !void {
        const head = [_]w.cbor.Entry{
            .{ .key = "kind", .value = .{ .text = "lookup-hook" } },
            .{ .key = "app", .value = .{ .text = "1color" } },
            .{ .key = "service", .value = .{ .text = self.service } },
            .{ .key = "program", .value = .{ .text = "color-lookup" } },
            .{ .key = "topic", .value = .{ .text = t } },
        };
        const arg: Value = .{ .map = try std.mem.concat(self.a, w.cbor.Entry, &.{ &head, rest }) };
        const h = try lookup.handle(self.a, ls.spec, self.s, .regtest, self.state, null, func, arg);
        if (h.state) |sc| self.state = sc;
        self.events = if (h.answer.getArray("events")) |es| es else &.{};
    }

    fn admitted(self: *Ls, t: []const u8, raw: []const u8, outs: []const u32) !void {
        const cid = try self.s.putBitcoin(self.a, .tx, raw);
        try self.hook("admitted", t, &.{
            .{ .key = "tx", .value = .{ .cid = cid } },
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(self.a, outs) } },
            .{ .key = "coinsRetained", .value = .{ .array = &.{} } },
        });
    }

    fn spent(self: *Ls, t: []const u8, src: []const u8, vout: u32, by: []const u8) !void {
        const sc = try self.s.putBitcoin(self.a, .tx, src);
        const bc = try self.s.putBitcoin(self.a, .tx, by);
        try self.hook("spent", t, &.{
            .{ .key = "outpoint", .value = .{ .map = try self.a.dupe(w.cbor.Entry, &.{
                .{ .key = "tx", .value = .{ .cid = sc } },
                .{ .key = "vout", .value = .{ .uint = vout } },
            }) } },
            .{ .key = "spendingTx", .value = .{ .cid = bc } },
        });
    }

    fn rejected(self: *Ls, t: []const u8, raw: []const u8) !void {
        const cid = try self.s.putBitcoin(self.a, .tx, raw);
        try self.hook("rejected", t, &.{.{ .key = "tx", .value = .{ .cid = cid } }});
    }

    /// The query's outputs as `<txid hex>:<vout>`.
    fn ask(self: *Ls, q: []const w.cbor.Entry) ![]const []const u8 {
        var svc = try lookup.Service.loadIndex(self.a, self.s, self.service, ls.index_name, ls.spec.maps, self.state);
        var ch = try lookup.Chain.load(self.a, self.s, null, .regtest);
        const ans = try ls.answer(self.a, &svc, &ch, .{ .map = try self.a.dupe(w.cbor.Entry, q) });
        const outs = ans.output_list;
        const out = try self.a.alloc([]const u8, outs.len);
        for (outs, out) |o, *x| x.* = try std.fmt.allocPrint(self.a, "{s}:{d}", .{ &w.header.toHex(o.txid), o.vout });
        return out;
    }
};

fn opName(a: std.mem.Allocator, raw: []const u8, vout: u32) []const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ &w.header.toHex(w.beef.txidOf(raw)), vout }) catch @panic("OOM");
}

fn expectOps(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y);
}

fn text(t: []const u8) Value {
    return .{ .text = t };
}

test "lookup: {tokenId}, {authoritiesTokenId}, {txid, outputIndex} over the hooks; limit and skip; spent and rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = ms.store() };
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = f.id }));
    const deploy = f.raws.get("token_deploy").?;
    const pd = f.raws.get("pool_deploy").?;
    const id = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(f.id)});

    // The deploy (10,000,000 at output 0): it holds the supply, so it is a value output (0.15.1; until
    // 0.15.0 it was filed with the authorities, an error).
    try l.admitted(tname, deploy, &.{0});
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(&.{}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));

    // A contract's deploy spends it: three value outputs, in outpoint order.
    try l.admitted(tname, pd, &.{ 0, 1, 2 });
    try l.spent(tname, deploy, 0, pd);
    try expectOps(&.{}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    const values = [_][]const u8{ opName(a, pd, 0), opName(a, pd, 1), opName(a, pd, 2) };
    try expectOps(&values, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(values[1..], try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .uint = 1 } } }));
    try expectOps(values[1..2], try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 1 } }, .{ .key = "skip", .value = .{ .uint = 1 } } }));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .uint = 3 } } }));

    // One output by outpoint (txid in display order); the spent deploy is not answered.
    const pd_hex = try a.dupe(u8, &w.header.toHex(w.beef.txidOf(pd)));
    const dp_hex = try a.dupe(u8, &w.header.toHex(f.id));
    try expectOps(values[2..3], try l.ask(&.{ .{ .key = "txid", .value = text(pd_hex) }, .{ .key = "outputIndex", .value = .{ .uint = 2 } } }));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "txid", .value = text(dp_hex) }, .{ .key = "outputIndex", .value = .{ .uint = 0 } } }));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "txid", .value = text(pd_hex) }, .{ .key = "outputIndex", .value = .{ .uint = 9 } } }));

    // The first of authoritiesTokenId, tokenId answers.
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "authoritiesTokenId", .value = text(id) } }));

    // The contract's deploy rejected: its outputs gone, the deploy unspent again (a value output).
    try l.rejected(tname, pd);
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(&.{}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));

    // A hook for another topic does nothing.
    try l.admitted("tm_demo", pd, &.{ 0, 1, 2 });
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
}

test "lookup: a BRC-161 token's authority and mint, by its <txid>_<vout> id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = ms.store() };
    const ad = f.raws.get("legacy_auth_deploy").?;
    const mint = f.raws.get("legacy_mint").?;
    const LA = legacyId(f, "legacy_auth_deploy", 0);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = LA.txid, .vout = 0, .kind = .legacy }));
    const id = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(LA.txid)});

    try l.admitted(tname, ad, &.{0});
    try expectOps(&.{opName(a, ad, 0)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    // The mint (0) is a value output; the new authority (1) an authority output.
    try l.admitted(tname, mint, &.{ 0, 1 });
    try l.spent(tname, ad, 0, mint);
    try expectOps(&.{opName(a, mint, 1)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    try expectOps(&.{opName(a, mint, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
}

test "lookup: queries out of shape are refused" {
    const id = "a5" ** 32 ++ "_0";
    const ok = [_]w.cbor.Entry{.{ .key = "tokenId", .value = text(id) }};
    try testing.expect((try ls.parseQuery(.{ .map = &ok })) == .values);
    const p = (try ls.parseQuery(.{ .map = &ok })).values;
    try testing.expectEqual(@as(u64, 100), p.limit);
    try testing.expectEqual(@as(u64, 0), p.skip);
    const legacy = [_]w.cbor.Entry{.{ .key = "authoritiesTokenId", .value = text("a5" ** 32 ++ "_7") }};
    try testing.expectEqual(@as(u32, 7), (try ls.parseQuery(.{ .map = &legacy })).authorities.id.vout);
    const bad = [_][]const w.cbor.Entry{
        &.{.{ .key = "tokenId", .value = text("A5" ** 32 ++ "_0") }}, // uppercase
        &.{.{ .key = "tokenId", .value = text("a5" ** 32 ++ "_") }}, // no vout after the separator
        &.{.{ .key = "tokenId", .value = text("a5" ** 32 ++ "-0") }}, // not a separator
        &.{.{ .key = "tokenId", .value = text("a5" ** 32 ++ "_00") }},
        &.{.{ .key = "tokenId", .value = .{ .uint = 1 } }},
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 0 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 101 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .uint = 100_001 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .nint = 0 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "metadataTokenId", .value = text(id) } }, // not built
        &.{ .{ .key = "txid", .value = text("a5" ** 31) }, .{ .key = "outputIndex", .value = .{ .uint = 0 } } },
        &.{ .{ .key = "txid", .value = text("a5" ** 32) }, .{ .key = "outputIndex", .value = .{ .uint = 1 << 32 } } },
    };
    for (bad) |q| try testing.expectError(error.BadQuery, ls.parseQuery(.{ .map = q }));
    try testing.expectError(error.UnsupportedQuery, ls.parseQuery(.{ .map = &.{.{ .key = "txid", .value = text("a5" ** 32) }} }));
    try testing.expectError(error.UnsupportedQuery, ls.parseQuery(.{ .map = &.{} }));
    try testing.expectError(error.BadQuery, ls.parseQuery(.{ .text = "x" }));
}

test "program: metadata and documentation through the topic contract's describe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = "tm_color_" ++ "a5" ** 32 ++ "_0";
    const arg: Value = .{ .map = &.{ .{ .key = "kind", .value = text("topic-describe") }, .{ .key = "topic", .value = text(t) } } };
    const m = try topic.describe(a, program, "metadata", arg);
    try testing.expectEqualStrings(t, m.getText("name").?);
    try testing.expect(std.mem.indexOf(u8, m.getText("shortDescription").?, "a5a5") != null);
    try testing.expectEqualStrings("0.5.0", m.getText("version").?);
    const d = try topic.describe(a, program, "documentation", arg);
    try testing.expect(std.mem.startsWith(u8, d.getText("documentation").?, "# 1Color token topic"));
    const ld = try lookup.describe(a, ls, "documentation", .{ .map = &.{ .{ .key = "kind", .value = text("lookup-describe") }, .{ .key = "service", .value = text("ls_color") } } });
    try testing.expect(std.mem.startsWith(u8, ld.getText("documentation").?, "# 1Color token lookup service"));
}

test "program: a BRC-161 token deployed at output 0 is tm_<txid>_0, its id <txid>_0 (its origin BSV-21); the bare tm_<txid> is no topic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    const txid = w.beef.txidOf(f.raws.get("legacy_deploy0").?);
    const hex = w.header.toHex(txid);

    // Its id and its topic, from every direction.
    const t = "tm_color_" ++ hex ++ "_0";
    var buf: [names.max_topic_len]u8 = undefined;
    try testing.expectEqualStrings(t, names.topicName(&buf, .{ .txid = txid, .vout = 0, .kind = .legacy }));
    try testing.expectEqualStrings(t, names.topicName(&buf, names.tokenIdOfString(&hex ++ "_0").?));
    try testing.expect(names.tokenIdOf("tm_color_" ++ hex) == null);
    try testing.expect(names.tokenIdOf("tm_" ++ hex ++ "_0") == null);

    // The JSON deploy and a JSON transfer of it, judged under tm_<txid>_0.
    _ = try s.putBitcoin(a, .tx, f.raws.get("legacy_fund").?);
    const deploy_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_deploy0").?);
    const transfer_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_transfer").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, t, deploy_cid, &.{}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rd.get("outputsToAdmit").?));
    const rt = try topic.judge(a, s, program.identify, try callArgs(a, t, transfer_cid, &.{0}));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, try uintsOf(a, rt.get("outputsToAdmit").?));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rt.get("coinsToRetain").?));
}

// --- the discovery topic (tm_color) and its lookup (ls_color; 0.12.0, ls_color_deploys gone) ---

test "deploys: every valid deploy output of any token, nothing else, through the topic contract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    const t = names.deploys_topic;
    try testing.expectEqualStrings("tm_color", t);
    try testing.expect(token.tokenIdOf(t) == null); // no token's topic

    inline for (.{ "fund", "legacy_fund" }) |nm| _ = try s.putBitcoin(a, .tx, f.raws.get(nm).?);
    const Case = struct { name: []const u8, admit: []const u32 };
    for ([_]Case{
        .{ .name = "token_deploy", .admit = &.{0} }, // BRC-162 deploy at output 0
        .{ .name = "legacy_deploy0", .admit = &.{0} }, // BRC-161 deploy+mint at output 0
        .{ .name = "legacy_deploy1", .admit = &.{1} }, // BRC-161 deploy+mint at output 1
        .{ .name = "legacy_auth_deploy", .admit = &.{0} }, // BRC-161 deploy+auth
        .{ .name = "pool_deploy", .admit = &.{} }, // token value outputs, no deploy
        .{ .name = "swap_bsv_in", .admit = &.{} },
        .{ .name = "legacy_transfer", .admit = &.{} },
        .{ .name = "legacy_mint", .admit = &.{} },
        .{ .name = "fund", .admit = &.{} },
    }) |c| {
        const cid = try s.putBitcoin(a, .tx, f.raws.get(c.name).?);
        const r = try topic.judge(a, s, program.identify, try callArgs(a, t, cid, &.{}));
        try testing.expectEqualSlices(u32, c.admit, try uintsOf(a, r.get("outputsToAdmit").?));
    }

    // A binary deploy anywhere but output 0 is no deploy; a binary output with an id is not one either.
    const tx: bsv21.Tx = .{ .txid = id_a, .inputs = &.{}, .outputs = &.{
        .{ .script = &p2pkh_lock, .satoshis = 1 },
        .{ .script = tokenScript(a, null, 100, null), .satoshis = 1 },
        .{ .script = tokenScript(a, id_a, 5, null), .satoshis = 1 },
    } };
    try testing.expectEqual(@as(usize, 0), (try token.judgeDeploys(a, tx, &.{})).outputs_to_admit.len);
    try testing.expect((try token.deployOf(a, id_a, 1, tokenScript(a, null, 100, null))) == null);
    const d0 = (try token.deployOf(a, id_a, 0, tokenScript(a, null, 100, null))).?;
    try testing.expectEqual(@as(u32, 0), d0.vout);
    // A deploy carrying a payload (the metadata it was deployed with) is a deploy like any other.
    const cbor_map = [_]u8{ 0x04, 0xa1, 0x61, 0x78, 0x01 };
    try testing.expect((try token.deployOf(a, id_a, 0, tokenScript(a, null, 0, &cbor_map))) != null);

    // Its metadata and documentation are its own.
    const arg: Value = .{ .map = &.{ .{ .key = "kind", .value = text("topic-describe") }, .{ .key = "topic", .value = text(t) } } };
    try testing.expect(std.mem.startsWith(u8, (try topic.describe(a, program, "documentation", arg)).getText("documentation").?, "# 1Color token deploys"));
}

test "token id text: `<txid>_<vout>` for every deploy, binary or BRC-161 JSON, `_0` included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const Case = struct { name: []const u8, vout: u32 };
    for ([_]Case{
        .{ .name = "token_deploy", .vout = 0 },
        .{ .name = "legacy_deploy0", .vout = 0 },
        .{ .name = "legacy_deploy1", .vout = 1 },
        .{ .name = "legacy_auth_deploy", .vout = 0 },
    }) |c| {
        const tx = try f.tx(a, c.name);
        const id = (try token.deployOf(a, tx.txid, c.vout, tx.outputs[c.vout].script)).?;
        var tb: [names.max_suffix_len]u8 = undefined;
        const want = try std.fmt.allocPrint(a, "{s}_{d}", .{ &w.header.toHex(tx.txid), c.vout });
        const nid: names.TokenId = .{ .txid = id.txid, .vout = id.vout, .kind = if (id.vout == 0) .native else .legacy };
        try testing.expectEqualStrings(want, names.tokenIdText(&tb, nid));
        // And the text names the same token back.
        const back = names.tokenIdOfString(want).?;
        try testing.expectEqualSlices(u8, &tx.txid, &back.txid);
        try testing.expectEqual(c.vout, back.vout);
    }
}

test "ls_color over tm_color (0.12.1): BRC-207's color-admission with topic tm_color answers a token's deploy, spent or not; color-spendability while unspent; other topics' outputs not; dropped on rejection; ls_color_deploys is no service" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = ms.store() };
    try testing.expectEqualStrings("ls_color", l.service);
    const t = names.deploys_topic;
    const deploy = f.raws.get("token_deploy").?;
    const d1 = f.raws.get("legacy_deploy1").?;
    const one: Value = .{ .uint = 1 };
    const hex0 = try a.dupe(u8, &w.header.toHex(w.beef.txidOf(deploy)));
    const hex1 = try a.dupe(u8, &w.header.toHex(w.beef.txidOf(d1)));
    const id0 = try std.fmt.allocPrint(a, "{s}_0", .{hex0});
    const id1 = try std.fmt.allocPrint(a, "{s}_1", .{hex1});
    const op0 = try std.fmt.allocPrint(a, "{s}.0", .{hex0});
    const op1 = try std.fmt.allocPrint(a, "{s}.1", .{hex1});
    // The exact BRC-207 shape (wallet/0207.md), service ls_color, topic tm_color.
    const adm = struct {
        fn q(al: std.mem.Allocator, typ: []const u8, asset: []const u8, ops: []const []const u8) !Value {
            return q207(al, typ, .{ .uint = 1 }, asset, "tm_color", ops);
        }
    }.q;

    try expectOps(&.{}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id0, &.{op0})));
    try l.admitted(t, deploy, &.{0});
    try l.admitted(t, d1, &.{1});
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id0, &.{op0})));
    try expectOps(&.{opName(a, d1, 1)}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id1, &.{ op1, op1 })));
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, "ls_color", null, try adm(a, "color-spendability", id0, &.{op0})));
    // Exactly the asset's deploy: another outpoint is no "yes".
    try expectOps(&.{}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id0, &.{op1})));
    try expectOps(&.{}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id1, &.{try std.fmt.allocPrint(a, "{s}.0", .{hex1})})));
    // Strict: topic tm_color only, assetId canonical, version 1, the two types.
    try testing.expectError(error.BadQuery, ask207(&l, "ls_color", null, try q207(a, "color-admission", one, id0, try std.fmt.allocPrint(a, "tm_color_{s}", .{id0}), &.{op0})));
    try testing.expectError(error.BadQuery, ask207(&l, "ls_color", null, try adm(a, "color-admission", hex0, &.{op0})));
    try testing.expectError(error.BadQuery, ask207(&l, "ls_color", null, try q207(a, "color-admission", .{ .uint = 2 }, id0, "tm_color", &.{op0})));
    try testing.expectError(error.BadQuery, ask207(&l, "ls_color", null, try adm(a, "color-balance", id0, &.{op0})));
    // The three queries read the token topics' maps: the discovery feed puts nothing there.
    try expectOps(&.{}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id0) }}));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "txid", .value = text(hex0) }, .{ .key = "outputIndex", .value = .{ .uint = 0 } } }));

    // A token topic's admission is not the discovery topic's.
    var buf: [names.max_topic_len]u8 = undefined;
    const ld0 = f.raws.get("legacy_deploy0").?;
    const hexl = try a.dupe(u8, &w.header.toHex(w.beef.txidOf(ld0)));
    try l.admitted(names.topicName(&buf, .{ .txid = w.beef.txidOf(ld0) }), ld0, &.{0});
    try expectOps(&.{}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", try std.fmt.allocPrint(a, "{s}_0", .{hexl}), &.{try std.fmt.allocPrint(a, "{s}.0", .{hexl})})));

    // Spent: still admitted (a registry). Rejected: gone.
    try l.spent(t, deploy, 0, f.raws.get("pool_deploy").?);
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id0, &.{op0})));
    try l.rejected(t, deploy);
    try expectOps(&.{}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id0, &.{op0})));
    try expectOps(&.{opName(a, d1, 1)}, try ask207(&l, "ls_color", null, try adm(a, "color-admission", id1, &.{op1})));

    // ls_color_deploys is no name of the program (no alias).
    try testing.expectError(error.UnknownService, ask207(&l, "ls_color_deploys", null, .{ .map = &.{.{ .key = "tokenId", .value = text(id0) }} }));
    const ld = try lookup.describe(a, ls, "documentation", .{ .map = &.{ .{ .key = "kind", .value = text("lookup-describe") }, .{ .key = "service", .value = text(ls.service_name) } } });
    try testing.expect(std.mem.indexOf(u8, ld.getText("documentation").?, "topic: \"tm_color\"") != null);
}

// --- the token list (fn "tokens", a read: shruggr/skein#120, #135) ---

/// A raw transaction: one input spending `seed`'s output 0 (unsigned), the outputs given, 1 sat each.
fn rawTx(a: std.mem.Allocator, seed: u8, outs: []const []const u8) []u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(a, &.{ 1, 0, 0, 0, 1 }) catch @panic("OOM");
    b.appendSlice(a, &([_]u8{seed} ** 32)) catch @panic("OOM");
    b.appendSlice(a, &.{ 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, @intCast(outs.len) }) catch @panic("OOM");
    for (outs) |o| {
        b.appendSlice(a, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }) catch @panic("OOM");
        std.debug.assert(o.len < 0xfd); // the script's length, a one-byte varint
        b.append(a, @intCast(o.len)) catch @panic("OOM");
        b.appendSlice(a, o) catch @panic("OOM");
    }
    b.appendSlice(a, &.{ 0, 0, 0, 0 }) catch @panic("OOM");
    return b.items;
}

test "deploy metadata: a DAG-CBOR map's sym, dec, icon (the embedded [mediaType, bytes], BRC-162 draft BRCs#308); a malformed attribute absent; not one map, none" {
    // {"dec": 8, "sym": "GOLD", "icon": ["image/png", h'89504e47']}
    const full = [_]u8{ 0xa3, 0x63, 'd', 'e', 'c', 0x08, 0x63, 's', 'y', 'm', 0x64, 'G', 'O', 'L', 'D', 0x64, 'i', 'c', 'o', 'n', 0x82, 0x69 } ++ "image/png".* ++ [_]u8{ 0x44, 0x89, 0x50, 0x4e, 0x47 };
    const m = brc162.metadataOf(&full);
    try testing.expectEqualStrings("GOLD", m.sym.?);
    try testing.expectEqual(@as(u8, 8), m.dec.?);
    try testing.expectEqualStrings("image/png", m.icon.?.media_type);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x50, 0x4e, 0x47 }, m.icon.?.bytes);
    // {"icon": ["image/svg+xml", h''], "x": [1, {"y": null}]}: an empty image is an image; an unknown key skipped whatever it holds.
    const empty = [_]u8{ 0xa2, 0x64, 'i', 'c', 'o', 'n', 0x82, 0x6d } ++ "image/svg+xml".* ++ [_]u8{ 0x40, 0x61, 'x', 0x82, 0x01, 0xa1, 0x61, 'y', 0xf6 };
    const me = brc162.metadataOf(&empty);
    try testing.expectEqualStrings("image/svg+xml", me.icon.?.media_type);
    try testing.expectEqual(@as(usize, 0), me.icon.?.bytes.len);
    try testing.expect(me.sym == null and me.dec == null);
    // The pointer forms are gone: a 36-byte outpoint, a 4-byte output index — absent, the map still read.
    const icon36 = [_]u8{ 0xa2, 0x63, 'd', 'e', 'c', 0x08, 0x64, 'i', 'c', 'o', 'n', 0x58, 36 } ++ [_]u8{0xab} ** 32 ++ [_]u8{ 7, 0, 0, 0 };
    const m36 = brc162.metadataOf(&icon36);
    try testing.expect(m36.icon == null);
    try testing.expectEqual(@as(u8, 8), m36.dec.?);
    const idx = [_]u8{ 0xa2, 0x64, 'i', 'c', 'o', 'n', 0x44, 2, 0, 0, 0, 0x61, 'x', 0x01 };
    try testing.expect(brc162.metadataOf(&idx).icon == null);
    // Any other shape is absent, the others unaffected: the items swapped; three items; one; a map;
    // bytes for the media type; text for the image; a tag on an item (a CID link, 42: skipped as a
    // value); invalid UTF-8 for the media type.
    const sym_ok = [_]u8{ 0x63, 's', 'y', 'm', 0x61, 'Z' };
    for ([_][]const u8{
        &[_]u8{ 0x82, 0x41, 0x01, 0x61, 'a' }, // [h'01', "a"]
        &[_]u8{ 0x83, 0x61, 'a', 0x41, 0x01, 0x00 }, // ["a", h'01', 0]
        &[_]u8{ 0x81, 0x61, 'a' }, // ["a"]
        &[_]u8{ 0xa1, 0x61, 'a', 0x41, 0x01 }, // {"a": h'01'}
        &[_]u8{ 0x82, 0x41, 'a', 0x41, 0x01 }, // [h'61', h'01']
        &[_]u8{ 0x82, 0x61, 'a', 0x61, 'b' }, // ["a", "b"]
        &[_]u8{ 0x82, 0x61, 'a', 0xd8, 0x2a, 0x45, 0x00, 0x01, 0x71, 0x00, 0x00 }, // ["a", 42(h'0001710000')]
        &[_]u8{ 0x82, 0xd8, 0x2a, 0x45, 0x00, 0x01, 0x71, 0x00, 0x00, 0x41, 0x01 }, // [42(…), h'01']
        &[_]u8{ 0x82, 0x61, 0xff, 0x41, 0x01 }, // [<not UTF-8>, h'01']
    }) |icon| {
        const p = try std.mem.concat(testing.allocator, u8, &.{ &.{ 0xa2, 0x64, 'i', 'c', 'o', 'n' }, icon, &sym_ok });
        defer testing.allocator.free(p);
        const x = brc162.metadataOf(p);
        try testing.expect(x.icon == null);
        try testing.expectEqualStrings("Z", x.sym.?);
    }
    // A tag other than a link is no DAG-CBOR: the payload has none.
    const tagged = [_]u8{ 0xa2, 0x64, 'i', 'c', 'o', 'n', 0x82, 0xc0, 0x61, 'a', 0x41, 0x01 } ++ sym_ok;
    const xt = brc162.metadataOf(&tagged);
    try testing.expect(xt.icon == null and xt.sym == null);
    // {"dec": 19, "sym": 5, "icon": h'0102'}: each malformed, each absent; the map still read.
    const bad = [_]u8{ 0xa3, 0x63, 'd', 'e', 'c', 0x13, 0x63, 's', 'y', 'm', 0x05, 0x64, 'i', 'c', 'o', 'n', 0x42, 1, 2 };
    const mb = brc162.metadataOf(&bad);
    try testing.expect(mb.sym == null and mb.dec == null and mb.icon == null);
    // {"dec": 8} beside a malformed sym: dec stands.
    const half = [_]u8{ 0xa2, 0x63, 'd', 'e', 'c', 0x08, 0x63, 's', 'y', 'm', 0x05 };
    try testing.expectEqual(@as(u8, 8), brc162.metadataOf(&half).dec.?);
    // Not one DAG-CBOR map: none — an array, trailing bytes, a duplicate key, a non-minimal length, an indefinite map, nothing.
    for ([_][]const u8{
        &.{ 0x81, 0x01 },
        &.{ 0xa1, 0x63, 'd', 'e', 'c', 0x08, 0x00 },
        &.{ 0xa2, 0x63, 'd', 'e', 'c', 0x08, 0x63, 'd', 'e', 'c', 0x09 },
        &.{ 0xa1, 0x78, 0x03, 'd', 'e', 'c', 0x08 },
        &.{ 0xbf, 0x63, 'd', 'e', 'c', 0x08, 0xff },
        &.{ 0xa1, 0x63, 'd', 'e' },
        &.{},
    }) |p| {
        const x = brc162.metadataOf(p);
        try testing.expect(x.sym == null and x.dec == null and x.icon == null);
    }

    // The icon a token's `/icon` serves (0.14.0): only an RFC 6838 `type/subtype` media type.
    try testing.expect(ls.isMediaType(m.icon.?.media_type));
    try testing.expect(ls.isMediaType("image/svg+xml"));
    for ([_][]const u8{ "", "image", "image/", "/png", "image/png;x=1", "image/png,x", "text/html\"<", "image /png", "image/p\x00g" }) |mt| {
        try testing.expect(!ls.isMediaType(mt));
    }
}

test "tokens: {limit?, skip?} from the query string or a JSON body, or ids in the query string; anything else refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try ls.parseTokensQuery(a, "", "");
    try testing.expectEqual(@as(u64, 100), d.limit);
    try testing.expectEqual(@as(u64, 0), d.skip);
    const q = try ls.parseTokensQuery(a, "?limit=5&skip=2", "");
    try testing.expectEqual(@as(u64, 5), q.limit);
    try testing.expectEqual(@as(u64, 2), q.skip);
    const j = try ls.parseTokensQuery(a, "", "{\"limit\": 1, \"skip\": 100000}");
    try testing.expectEqual(@as(u64, 1), j.limit);
    try testing.expectEqual(@as(u64, 100000), j.skip);
    try testing.expectEqual(@as(u64, 7), (try ls.parseTokensQuery(a, "limit=3", "{\"limit\":7}")).limit); // the body's win
    for ([_][2][]const u8{
        .{ "limit=0", "" },       .{ "limit=101", "" },    .{ "skip=100001", "" }, .{ "limit=x", "" },
        .{ "offset=1", "" },      .{ "limit", "" },        .{ "", "[1]" },         .{ "", "{\"limit\":\"5\"}" },
        .{ "", "{\"skip\":-1}" }, .{ "", "{\"tokenId\":\"a\"}" }, .{ "", "not json" },
    }) |c| try testing.expectError(error.BadQuery, ls.parseTokensQuery(a, c[0], c[1]));

    // ids (0.14.0): comma-separated `<txid>_<vout>` exactly, in order, `%2C` a comma; not beside limit/skip.
    const t1 = "ab" ** 32 ++ "_0";
    const t2 = "0c" ** 32 ++ "_12";
    const ids = (try ls.parseTokensQuery(a, "?ids=" ++ t1 ++ "," ++ t2 ++ "," ++ t1, "")).ids.?;
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expectEqualStrings(t1, ids[0]);
    try testing.expectEqualStrings(t2, ids[1]);
    try testing.expectEqualStrings(t1, ids[2]);
    try testing.expectEqualStrings(t2, (try ls.parseTokensQuery(a, "ids=" ++ t1 ++ "%2C" ++ t2, "")).ids.?[1]);
    try testing.expect((try ls.parseTokensQuery(a, "limit=3", "")).ids == null);
    for ([_][2][]const u8{
        .{ "ids=", "" },                         .{ "ids=" ++ t1 ++ ",", "" },               .{ "ids=" ++ "ab" ** 32, "" },
        .{ "ids=" ++ "AB" ** 32 ++ "_0", "" },   .{ "ids=" ++ "ab" ** 32 ++ "_01", "" },     .{ "ids=" ++ "ab" ** 32 ++ ".0", "" },
        .{ "ids=" ++ t1 ++ "&limit=5", "" },     .{ "ids=" ++ t1, "{\"skip\":1}" },         .{ "ids=" ++ t1 ++ "&ids=" ++ t2, "" },
        .{ "ids=" ++ t1 ++ "%2", "" },           .{ "", "{\"ids\":[\"" ++ t1 ++ "\"]}" },
    }) |c| try testing.expectError(error.BadQuery, ls.parseTokensQuery(a, c[0], c[1]));
}

test "a token id as the reads take it (0.14.0): `<txid>_<vout>` exactly; the token's paths past the prefix row" {
    const t1 = "ab" ** 32 ++ "_7";
    const k = ls.tokenKeyOf(t1).?;
    try testing.expectEqual(@as(u8, 0xab), k[0]);
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, k[32..36], .big));
    for ([_][]const u8{ "", "ab" ** 32, "ab" ** 32 ++ "_", "ab" ** 32 ++ "_00", "ab" ** 32 ++ "_4294967296", "Ab" ** 32 ++ "_0", "ab" ** 31 ++ "_0", "ab" ** 32 ++ "_0x" }) |x|
        try testing.expect(ls.tokenKeyOf(x) == null);
    try testing.expect(ls.tokenPathOf(t1).?.part == .detail);
    try testing.expect(ls.tokenPathOf(t1 ++ "/icon").?.part == .icon);
    try testing.expect(ls.tokenPathOf(t1 ++ "/deploy").?.part == .deploy);
    for ([_][]const u8{ "", "tokens", "color/tokens", t1 ++ "/", t1 ++ "/icon/", t1 ++ "/beef", "x/" ++ t1, t1 ++ "/icon/x" }) |x|
        try testing.expect(ls.tokenPathOf(x) == null);
    try testing.expect(ls.isHttpUrl("https://example.com/i.png") and ls.isHttpUrl("HTTP://x"));
    try testing.expect(!ls.isHttpUrl("_0") and !ls.isHttpUrl("ipfs://x") and !ls.isHttpUrl("data:image/png;base64,AA=="));
    try testing.expectEqualStrings("public, max-age=31536000, immutable", ls.cacheOf(true));
    try testing.expectEqualStrings("public, max-age=5", ls.cacheOf(false));
}

test "tokens: every deploy tm_color admitted, its id `<txid>_<vout>`, topic, sym, dec, icon, outpoint; newest first; skip and limit; a rejected deploy gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = s };
    const t = names.deploys_topic;

    try testing.expectEqual(@as(usize, 0), (try ls.tokens(a, s, null, null, null, .{})).len); // no index yet

    // A 1Color deploy with a payload {"dec": 2, "sym": "AB", "icon": ["image/png", h'010203']} (embedded).
    const payload = [_]u8{ 0xa3, 0x63, 'd', 'e', 'c', 0x02, 0x63, 's', 'y', 'm', 0x62, 'A', 'B', 0x64, 'i', 'c', 'o', 'n', 0x82, 0x69 } ++ "image/png".* ++ [_]u8{ 0x43, 1, 2, 3 };
    const mine = rawTx(a, 0x11, &.{ tokenScript(a, null, 1000, pushOf(a, &payload)), &p2pkh_lock });
    const mine_txid = w.beef.txidOf(mine);
    try l.admitted(t, mine, &.{0});
    const ld1 = f.raws.get("legacy_deploy1").?; // a BRC-161 deploy+mint at output 1
    try l.admitted(t, ld1, &.{1});
    const td = f.raws.get("token_deploy").?; // a binary deploy without display fields
    try l.admitted(t, td, &.{0});

    const list = try ls.tokens(a, s, l.state, null, null, .{});
    try testing.expectEqual(@as(usize, 3), list.len);
    // Unmined, all three: by deploy outpoint, highest first.
    const want_order = blk: {
        var hs = [_][]const u8{ try a.dupe(u8, &w.header.toHex(mine_txid)), try a.dupe(u8, &w.header.toHex(w.beef.txidOf(ld1))), try a.dupe(u8, &w.header.toHex(f.id)) };
        std.mem.sort([]const u8, &hs, {}, struct {
            fn gt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .gt;
            }
        }.gt);
        break :blk hs;
    };
    for (want_order, list) |h, x| try testing.expectEqualStrings(h, x.txid);

    for (list) |x| {
        const hex = &w.header.toHex(mine_txid);
        if (std.mem.eql(u8, x.txid, hex)) {
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}_0", .{hex}), x.tokenId); // `<txid>_0`, a 1Color token too
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "tm_color_{s}_0", .{hex}), x.topic);
            try testing.expectEqualStrings("AB", x.sym);
            try testing.expectEqual(@as(u8, 2), x.dec);
            // A binary deploy's icon: `<tokenId>/icon`, relative to the list (0.14.0).
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}_0/icon", .{hex}), x.iconUrl.?);
            try testing.expectEqual(@as(u32, 0), x.vout);
        } else if (std.mem.eql(u8, x.txid, &w.header.toHex(w.beef.txidOf(ld1)))) {
            const h1 = &w.header.toHex(w.beef.txidOf(ld1));
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}_1", .{h1}), x.tokenId);
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "tm_color_{s}_1", .{h1}), x.topic);
            try testing.expectEqual(@as(u32, 1), x.vout);
            const want = (try brc161.decode(a, (try f.tx(a, "legacy_deploy1")).outputs[1].script)).?;
            try testing.expectEqualStrings(want.sym orelse "", x.sym);
            try testing.expectEqual(want.dec orelse 0, x.dec);
            // A BRC-161 JSON deploy's icon: its string only when an http(s) URL (this one is not).
            try testing.expect(want.icon == null or !ls.isHttpUrl(want.icon.?));
            try testing.expect(x.iconUrl == null);
        } else {
            try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(f.id)}), x.tokenId);
            try testing.expectEqualStrings("", x.sym);
            try testing.expectEqual(@as(u8, 0), x.dec);
            try testing.expect(x.iconUrl == null);
        }
    }

    // skip, limit.
    const page = try ls.tokens(a, s, l.state, null, null, .{ .skip = 1, .limit = 1 });
    try testing.expectEqual(@as(usize, 1), page.len);
    try testing.expectEqualStrings(list[1].txid, page[0].txid);
    try testing.expectEqual(@as(usize, 0), (try ls.tokens(a, s, l.state, null, null, .{ .skip = 3 })).len);

    // Rejected: gone from the list.
    try l.rejected(t, mine);
    try testing.expectEqual(@as(usize, 2), (try ls.tokens(a, s, l.state, null, null, .{})).len);

    // The route: 200 JSON, no null iconUrl, the `state` cache class; 400 on a bad query.
    const req: Value = .{ .map = &.{ .{ .key = "method", .value = text("GET") }, .{ .key = "query", .value = text("limit=1") } } };
    const r = try ls.tokensRoute(a, s, l.state, null, null, req);
    try testing.expectEqual(@as(u64, 200), r.getUint("status").?);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, r.getBytes("body").?, .{});
    try testing.expectEqual(@as(usize, 1), parsed.array.items.len);
    const o = parsed.array.items[0].object;
    for ([_][]const u8{ "tokenId", "topic", "sym", "dec", "txid", "vout" }) |k| try testing.expect(o.get(k) != null);
    try testing.expect(o.get("icon") == null);
    if (o.get("iconUrl")) |ic| try testing.expect(ic == .string);
    try testing.expectEqualStrings("public, max-age=5", r.get("headers").?.getText("cache-control").?);
    const bad: Value = .{ .map = &.{.{ .key = "body", .value = .{ .bytes = "{\"limit\":0}" } }} };
    try testing.expectEqual(@as(u64, 400), (try ls.tokensRoute(a, s, l.state, null, null, bad)).getUint("status").?);

    // Called as a read route's filter (shruggr/skein#143, the input's `filter: true`): {answer: <the http answer>}.
    try testing.expect(ls.isFilter(.{ .map = &.{.{ .key = "filter", .value = .{ .boolean = true } }} }));
    try testing.expect(!ls.isFilter(.{ .map = &.{.{ .key = "fn", .value = text("tokens") }} }));
    const fa = try ls.asFilterAnswer(a, r);
    try testing.expectEqual(@as(usize, 1), fa.map.len);
    try testing.expectEqual(@as(u64, 200), fa.get("answer").?.getUint("status").?);
}

/// A token read's request as the front door hands it to the prefix row's filter (match: the row as served).
fn tokenReq(a: std.mem.Allocator, rest: []const u8) Value {
    return .{ .map = a.dupe(w.cbor.Entry, &.{
        .{ .key = "method", .value = text("GET") },
        .{ .key = "route", .value = text(std.fmt.allocPrint(a, "/1color/{s}", .{rest}) catch @panic("OOM")) },
        .{ .key = "match", .value = .{ .map = a.dupe(w.cbor.Entry, &.{
            .{ .key = "address", .value = text("/1color/") },
            .{ .key = "prefix", .value = .{ .boolean = true } },
        }) catch @panic("OOM") } },
    }) catch @panic("OOM") };
}

test "token reads (0.14.0): ?ids= one row per id in order; /<token>, /<token>/icon, /<token>/deploy; a BRC-161 icon only when http(s); anything else 404" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    var l: Ls = .{ .a = a, .s = s };
    const t = names.deploys_topic;

    // A 1Color deploy with an embedded icon ["image/png", h'010203'].
    const payload = [_]u8{ 0xa3, 0x63, 'd', 'e', 'c', 0x02, 0x63, 's', 'y', 'm', 0x62, 'A', 'B', 0x64, 'i', 'c', 'o', 'n', 0x82, 0x69 } ++ "image/png".* ++ [_]u8{ 0x43, 1, 2, 3 };
    // With no inputs (rawTx's one input cut out): its BEEF is itself, no ancestry for the chain state to hold.
    const with_input = rawTx(a, 0x21, &.{ tokenScript(a, null, 1000, pushOf(a, &payload)), &p2pkh_lock });
    const mine = cat(a, &.{ with_input[0..4], &.{0}, with_input[5 + 32 + 4 + 1 + 4 ..] });
    try l.admitted(t, mine, &.{0});
    // BRC-161 JSON deploys at output 0: one with an http(s) icon, one with an outpoint icon.
    const web = rawTx(a, 0x22, &.{bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"5\",\"sym\":\"W\",\"icon\":\"https://example.com/w.png\"}")});
    try l.admitted(t, web, &.{0});
    const ord = rawTx(a, 0x23, &.{bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"5\",\"sym\":\"O\",\"icon\":\"_1\"}")});
    try l.admitted(t, ord, &.{0});
    const id_mine = idString(a, w.beef.txidOf(mine), 0);
    const id_web = idString(a, w.beef.txidOf(web), 0);
    const id_ord = idString(a, w.beef.txidOf(ord), 0);
    const id_none = idString(a, [_]u8{0x99} ** 32, 3);

    // The chain state holds the binary deploy, unproven.
    var ch = try lookup.Chain.load(a, s, null, .regtest);
    _ = try ch.putTx(w.beef.txidOf(mine), mine);
    const chain = try ch.save();

    // ?ids=: one row per id, in the query's order, repeats kept; an id not listed {tokenId, listed: false}.
    const q: Value = .{ .map = &.{.{ .key = "query", .value = text(try std.fmt.allocPrint(a, "ids={s},{s},{s},{s}", .{ id_none, id_web, id_mine, id_ord })) }} };
    const r = try ls.tokensRoute(a, s, l.state, chain, null, q);
    try testing.expectEqual(@as(u64, 200), r.getUint("status").?);
    try testing.expectEqualStrings("public, max-age=5", r.get("headers").?.getText("cache-control").?);
    const rows = (try std.json.parseFromSliceLeaky(std.json.Value, a, r.getBytes("body").?, .{})).array.items;
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings(id_none, rows[0].object.get("tokenId").?.string);
    try testing.expectEqual(false, rows[0].object.get("listed").?.bool);
    try testing.expectEqual(@as(usize, 2), rows[0].object.count());
    try testing.expectEqualStrings(id_web, rows[1].object.get("tokenId").?.string);
    try testing.expectEqualStrings("https://example.com/w.png", rows[1].object.get("iconUrl").?.string);
    try testing.expect(rows[1].object.get("listed") == null);
    try testing.expectEqualStrings(id_mine, rows[2].object.get("tokenId").?.string);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/icon", .{id_mine}), rows[2].object.get("iconUrl").?.string);
    try testing.expectEqualStrings("AB", rows[2].object.get("sym").?.string);
    try testing.expectEqualStrings(id_ord, rows[3].object.get("tokenId").?.string);
    try testing.expect(rows[3].object.get("iconUrl") == null);
    const bad: Value = .{ .map = &.{.{ .key = "query", .value = text("ids=x") }} };
    try testing.expectEqual(@as(u64, 400), (try ls.tokensRoute(a, s, l.state, chain, null, bad)).getUint("status").?);

    // /<token>: the detail, JSON, `state`.
    const d = try ls.tokenRoute(a, s, l.state, chain, null, tokenReq(a, id_mine));
    try testing.expectEqual(@as(u64, 200), d.getUint("status").?);
    try testing.expectEqualStrings("application/json", d.getText("type").?);
    try testing.expectEqualStrings("public, max-age=5", d.get("headers").?.getText("cache-control").?);
    const dj = (try std.json.parseFromSliceLeaky(std.json.Value, a, d.getBytes("body").?, .{})).object;
    try testing.expectEqualStrings(id_mine, dj.get("tokenId").?.string);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "tm_color_{s}", .{id_mine}), dj.get("topic").?.string);
    try testing.expectEqual(@as(i64, 2), dj.get("dec").?.integer);
    try testing.expectEqual(@as(i64, 0), dj.get("vout").?.integer);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/icon", .{id_mine}), dj.get("iconUrl").?.string);
    try testing.expect(dj.get("icon") == null);

    // /<token>/icon: the bytes, the deploy's media type; unproven → `state`.
    const ic = try ls.tokenRoute(a, s, l.state, chain, null, tokenReq(a, try std.fmt.allocPrint(a, "{s}/icon", .{id_mine})));
    try testing.expectEqual(@as(u64, 200), ic.getUint("status").?);
    try testing.expectEqualStrings("image/png", ic.getText("type").?);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ic.getBytes("body").?);
    try testing.expectEqualStrings("public, max-age=5", ic.get("headers").?.getText("cache-control").?);

    // /<token>/deploy: the deploy's Atomic BEEF from the chain state, octet-stream; unproven → `state`.
    const dp = try ls.tokenRoute(a, s, l.state, chain, null, tokenReq(a, try std.fmt.allocPrint(a, "{s}/deploy", .{id_mine})));
    try testing.expectEqual(@as(u64, 200), dp.getUint("status").?);
    try testing.expectEqualStrings("application/octet-stream", dp.getText("type").?);
    try testing.expectEqualStrings("public, max-age=5", dp.get("headers").?.getText("cache-control").?);
    try testing.expectEqualSlices(u8, (try ch.beefOf(w.beef.txidOf(mine))).?, dp.getBytes("body").?);

    // A BRC-161 JSON deploy: its detail, no /icon (404); its deploy not held by the chain state: 404.
    const wd = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, chain, null, tokenReq(a, id_web))).getBytes("body").?, .{})).object;
    try testing.expectEqualStrings("https://example.com/w.png", wd.get("iconUrl").?.string);
    for ([_][]const u8{
        try std.fmt.allocPrint(a, "{s}/icon", .{id_web}),   try std.fmt.allocPrint(a, "{s}/icon", .{id_ord}),
        try std.fmt.allocPrint(a, "{s}/deploy", .{id_web}), id_none,
        try std.fmt.allocPrint(a, "{s}/icon", .{id_none}),  try std.fmt.allocPrint(a, "{s}/beef", .{id_mine}),
        try std.fmt.allocPrint(a, "{s}/", .{id_mine}),      "",
        "color/tokens",                                     try std.fmt.allocPrint(a, "{s}.0", .{w.header.toHex(w.beef.txidOf(mine))}),
    }) |rest| {
        const x = try ls.tokenRoute(a, s, l.state, chain, null, tokenReq(a, rest));
        try testing.expectEqual(@as(u64, 404), x.getUint("status").?);
        try testing.expect(x.get("headers") == null);
    }
    // A route not under the row's address: 404.
    const off: Value = .{ .map = &.{ .{ .key = "route", .value = text(try std.fmt.allocPrint(a, "/other/{s}", .{id_mine})) }, .{ .key = "match", .value = tokenReq(a, "").get("match").? } } };
    try testing.expectEqual(@as(u64, 404), (try ls.tokenRoute(a, s, l.state, chain, null, off)).getUint("status").?);
    // 0.15.0 (D5): the rows carry the deploy's supply (`amount`) and its block `height` where the
    // overlay has the deploy placed under tm_color (its state's `placed`), null while unmined.
    const maps = try w.store.Maps.create(a, s);
    var placed = maps.map(null);
    var at7: [44]u8 = .{0} ** 44;
    std.mem.writeInt(u32, at7[0..4], 7, .big);
    try placed.put(try w.store.nameKey(a, names.deploys_topic, &.{&w.beef.txidOf(mine)}), .{ .bytes = &at7 });
    try placed.flush();
    const overlay = try s.putValue(a, .{ .map = try a.dupe(w.cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "overlay-state" } },
        .{ .key = "maps", .value = .{ .map = try a.dupe(w.cbor.Entry, &.{.{ .key = "placed", .value = .{ .cid = placed.root.? } }}) } },
    }) });
    const q2: Value = .{ .map = &.{.{ .key = "query", .value = text(try std.fmt.allocPrint(a, "ids={s},{s}", .{ id_mine, id_web })) }} };
    const rows2 = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokensRoute(a, s, l.state, chain, overlay, q2)).getBytes("body").?, .{})).array.items;
    try testing.expectEqual(@as(i64, 1000), rows2[0].object.get("amount").?.integer);
    try testing.expectEqual(@as(i64, 7), rows2[0].object.get("height").?.integer);
    try testing.expectEqual(@as(i64, 5), rows2[1].object.get("amount").?.integer);
    try testing.expect(rows2[1].object.get("height").? == .null); // present, null: unmined
    const list2 = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokensRoute(a, s, l.state, chain, overlay, .{ .map = &.{} })).getBytes("body").?, .{})).array.items;
    for (list2) |row| try testing.expect(row.object.get("amount") != null and row.object.get("height") != null);
    const d2 = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, chain, overlay, tokenReq(a, id_mine))).getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(i64, 1000), d2.get("amount").?.integer);
    try testing.expectEqual(@as(i64, 7), d2.get("height").?.integer);
    // No overlay state: height null.
    try testing.expect(dj.get("height").? == .null);
    try testing.expectEqual(@as(i64, 1000), dj.get("amount").?.integer);
    // An authority-only deploy (amount 0): amount 0.
    const auth = rawTx(a, 0x24, &.{tokenScript(a, null, 0, null)});
    try l.admitted(t, auth, &.{0});
    const ad = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, chain, overlay, tokenReq(a, idString(a, w.beef.txidOf(auth), 0)))).getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(i64, 0), ad.get("amount").?.integer);

    // Rejected: gone.
    try l.rejected(t, mine);
    try testing.expectEqual(@as(u64, 404), (try ls.tokenRoute(a, s, l.state, chain, null, tokenReq(a, id_mine))).getUint("status").?);
}

// --- the balance table (0.15.0, D4) ---

const Prev = struct { txid: [32]u8, vout: u32 };

/// A transaction spending `ins`, with outputs `outs` (each one sat, scripts under 253 bytes).
fn rawSpend(a: std.mem.Allocator, ins: []const Prev, outs: []const []const u8) []u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(a, &.{ 1, 0, 0, 0, @intCast(ins.len) }) catch @panic("OOM");
    for (ins) |in| {
        b.appendSlice(a, &in.txid) catch @panic("OOM");
        var v: [4]u8 = undefined;
        std.mem.writeInt(u32, &v, in.vout, .little);
        b.appendSlice(a, &v) catch @panic("OOM");
        b.appendSlice(a, &.{ 0, 0xff, 0xff, 0xff, 0xff }) catch @panic("OOM");
    }
    b.append(a, @intCast(outs.len)) catch @panic("OOM");
    for (outs) |o| {
        b.appendSlice(a, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }) catch @panic("OOM");
        b.append(a, @intCast(o.len)) catch @panic("OOM");
        b.appendSlice(a, o) catch @panic("OOM");
    }
    b.appendSlice(a, &.{ 0, 0, 0, 0 }) catch @panic("OOM");
    return b.items;
}

fn lockOf(pkh: u8) [25]u8 {
    return [_]u8{ 0x76, 0xa9, 0x14 } ++ [_]u8{pkh} ** 20 ++ [_]u8{ 0x88, 0xac };
}

/// A value output of token id_a: `amount` under `lock`.
fn valueOut(a: std.mem.Allocator, amount: u64, lock: []const u8) []u8 {
    var buf: [10]u8 = undefined;
    return cat(a, &.{ &.{0x20}, &id_a, brc162.pushAmount(&buf, amount), &.{0x6d}, lock });
}

fn balanceOf(a: std.mem.Allocator, l: *Ls, pkh: u8) !?u64 {
    var svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    const v = (try svc.map("balances").get(cat(a, &.{ &ls_tok_a, &([_]u8{pkh} ** 20) }))) orelse return null;
    return std.mem.readInt(u64, v.bytes[0..8], .big);
}

/// id_a's key in the lookup's maps (txid display order ‖ vout BE).
const ls_tok_a: [36]u8 = .{0xa5} ** 32 ++ .{ 0, 0, 0, 0 };

fn holdersOf(a: std.mem.Allocator, l: *Ls, network: w.chain.Network, limit: u64, skip: u64) !struct { count: u64, rows: []const ls.Holder } {
    var svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    const h = try ls.holdersOf(a, &svc, &ls_tok_a, network, .{ .limit = limit, .skip = skip });
    return .{ .count = h.count, .rows = h.rows };
}

test "balances (0.15.0): P2PKH value outputs credit their address as they enter the unspent values and debit it as they leave (spent, rejected); re-keyed by balance; a zero balance leaves both maps; a pool or other contract output is not counted; JSON transfers count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    var l: Ls = .{ .a = a, .s = ms.store() };
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = id_a }));
    const A: u8 = 0x0a;
    const B: u8 = 0x0b;
    const C: u8 = 0x33; // the JSON transfer's (test.zig's p2pkh_lock)
    const D: u8 = 0x0d;
    // A contract's lock (not P2PKH): a value output under it counts for nobody.
    const pool_lock = [_]u8{ 0x51, 0x76, 0xa9, 0x14 } ++ [_]u8{0x0e} ** 20 ++ [_]u8{ 0x88, 0xac };

    const t1 = rawSpend(a, &.{.{ .txid = .{0x01} ** 32, .vout = 0 }}, &.{
        valueOut(a, 500, &lockOf(A)), valueOut(a, 300, &lockOf(B)), valueOut(a, 200, &lockOf(A)),
        valueOut(a, 1000, &pool_lock), jsonOp(a, "transfer", id_a, 0, 50),
    });
    const t1id = w.beef.txidOf(t1);
    try l.admitted(tname, t1, &.{ 0, 1, 2, 3, 4 });
    try testing.expectEqual(@as(u64, 700), (try balanceOf(a, &l, A)).?);
    try testing.expectEqual(@as(u64, 300), (try balanceOf(a, &l, B)).?);
    try testing.expectEqual(@as(u64, 50), (try balanceOf(a, &l, C)).?);
    try testing.expect((try balanceOf(a, &l, 0x0e)) == null);
    var h = try holdersOf(a, &l, .main, 100, 0);
    try testing.expectEqual(@as(u64, 3), h.count);
    try testing.expectEqual(@as(usize, 3), h.rows.len);
    try testing.expectEqual(@as(u64, 700), h.rows[0].balance);
    try testing.expectEqualStrings(try ls.addressOf(a, .main, .{A} ** 20), h.rows[0].address);
    try testing.expectEqual(@as(u64, 300), h.rows[1].balance);
    try testing.expectEqual(@as(u64, 50), h.rows[2].balance);
    // A dupe admission credits nothing more.
    try l.admitted(tname, t1, &.{ 0, 1, 2, 3, 4 });
    try testing.expectEqual(@as(u64, 700), (try balanceOf(a, &l, A)).?);

    // t2 spends A's 500: 100 to B, 400 to D. A 200, B 400, D 400 (re-keyed: B before A now).
    const t2 = rawSpend(a, &.{.{ .txid = t1id, .vout = 0 }}, &.{ valueOut(a, 100, &lockOf(B)), valueOut(a, 400, &lockOf(D)) });
    try l.admitted(tname, t2, &.{ 0, 1 });
    try l.spent(tname, t1, 0, t2);
    try testing.expectEqual(@as(u64, 200), (try balanceOf(a, &l, A)).?);
    try testing.expectEqual(@as(u64, 400), (try balanceOf(a, &l, B)).?);
    try testing.expectEqual(@as(u64, 400), (try balanceOf(a, &l, D)).?);
    h = try holdersOf(a, &l, .main, 100, 0);
    try testing.expectEqual(@as(u64, 4), h.count);
    try testing.expectEqual(@as(usize, 4), h.rows.len);
    try testing.expectEqual(@as(u64, 400), h.rows[0].balance);
    try testing.expectEqual(@as(u64, 400), h.rows[1].balance);
    try testing.expectEqual(@as(u64, 200), h.rows[2].balance);
    try testing.expectEqualStrings(try ls.addressOf(a, .main, .{A} ** 20), h.rows[2].address);
    try testing.expectEqual(@as(u64, 50), h.rows[3].balance);
    var svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    try testing.expectEqual(@as(usize, 4), try svc.map("byBalance").count()); // one key per address: the old ones gone

    // A's 200 spent into the contract: A's balance is zero, gone from both maps.
    const t3 = rawSpend(a, &.{.{ .txid = t1id, .vout = 2 }}, &.{valueOut(a, 200, &pool_lock)});
    try l.admitted(tname, t3, &.{0});
    try l.spent(tname, t1, 2, t3);
    try testing.expect((try balanceOf(a, &l, A)) == null);
    h = try holdersOf(a, &l, .main, 100, 0);
    try testing.expectEqual(@as(u64, 3), h.count);
    for (h.rows) |r| try testing.expect(!std.mem.eql(u8, r.address, try ls.addressOf(a, .main, .{A} ** 20)));
    svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    try testing.expectEqual(@as(usize, 3), try svc.map("byBalance").count());

    // t2 rejected: its outputs debited (B back to 300, D gone), A's 500 given back.
    try l.rejected(tname, t2);
    try testing.expectEqual(@as(u64, 500), (try balanceOf(a, &l, A)).?);
    try testing.expectEqual(@as(u64, 300), (try balanceOf(a, &l, B)).?);
    try testing.expect((try balanceOf(a, &l, D)) == null);
    h = try holdersOf(a, &l, .main, 100, 0);
    try testing.expectEqual(@as(u64, 3), h.count);
    try testing.expectEqual(@as(u64, 500), h.rows[0].balance);
    // t1 rejected too: nothing left.
    try l.rejected(tname, t3);
    try l.rejected(tname, t1);
    h = try holdersOf(a, &l, .main, 100, 0);
    try testing.expectEqual(@as(u64, 0), h.count);
    try testing.expectEqual(@as(usize, 0), h.rows.len);
}

fn countersAt(a: std.mem.Allocator, l: *Ls) !ls.Counters {
    var svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    return ls.countersOf(&svc, &ls_tok_a);
}

test "counters (0.17.0): supply, unspent authorities, burned at admission; a burn event; a rejection unwinds all; a dupe hook counts nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    var l: Ls = .{ .a = a, .s = ms.store() };
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = id_a }));
    const A: u8 = 0x0a;
    const B: u8 = 0x0b;
    const pool_lock = [_]u8{ 0x51, 0x76, 0xa9, 0x14 } ++ [_]u8{0x0e} ** 20 ++ [_]u8{ 0x88, 0xac };
    ls.now_ms = 1000;

    // t1: 500 to A, 300 to B, 200 in a contract, an authority: supply 1000 (every value output), 1 authority.
    const t1 = rawSpend(a, &.{.{ .txid = .{0x01} ** 32, .vout = 0 }}, &.{
        valueOut(a, 500, &lockOf(A)), valueOut(a, 300, &lockOf(B)), valueOut(a, 200, &pool_lock), valueOut(a, 0, &lockOf(A)),
    });
    const t1id = w.beef.txidOf(t1);
    try l.admitted(tname, t1, &.{ 0, 1, 2, 3 });
    try testing.expectEqual(@as(usize, 0), l.events.len);
    var n = try countersAt(a, &l);
    try testing.expectEqual(@as(u64, 1000), n.supply);
    try testing.expectEqual(@as(u64, 1), n.authorities);
    try testing.expectEqual(@as(u64, 0), n.burned);
    try l.admitted(tname, t1, &.{ 0, 1, 2, 3 }); // a dupe: nothing more
    try testing.expectEqual(@as(u64, 1000), (try countersAt(a, &l)).supply);

    // t2 spends A's 500 and the authority, outputs 350 to B: 150 burned, the authority gone.
    ls.now_ms = 2000;
    const t2 = rawSpend(a, &.{ .{ .txid = t1id, .vout = 0 }, .{ .txid = t1id, .vout = 3 } }, &.{valueOut(a, 350, &lockOf(B))});
    const t2id = w.beef.txidOf(t2);
    try l.admitted(tname, t2, &.{0});
    try testing.expectEqual(@as(usize, 1), l.events.len);
    const ev = l.events[0];
    try testing.expectEqualStrings("burn", ev.getText("event").?);
    const id = idString(a, id_a, 0);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "ls_color_{s}", .{id}), ev.getText("topic").?);
    try testing.expectEqualStrings(id, ev.getText("tokenId").?);
    const row = ev.get("row").?;
    try testing.expectEqualStrings("burn", row.getText("kind").?);
    try testing.expectEqualStrings(&w.header.toHex(t2id), row.getText("txid").?);
    try testing.expectEqual(@as(u64, 150), row.getUint("amount").?);
    try testing.expectEqual(@as(u64, 2000), row.getUint("at").?);
    try l.spent(tname, t1, 0, t2);
    try l.spent(tname, t1, 3, t2);
    n = try countersAt(a, &l);
    try testing.expectEqual(@as(u64, 1000 - 500 + 350), n.supply);
    try testing.expectEqual(@as(u64, 0), n.authorities);
    try testing.expectEqual(@as(u64, 150), n.burned);
    try testing.expectEqual(@as(u64, 1), n.burns);
    // a dupe admission after the spends: no second burn, no event
    try l.admitted(tname, t2, &.{0});
    try testing.expectEqual(@as(usize, 0), l.events.len);
    try testing.expectEqual(@as(u64, 150), (try countersAt(a, &l)).burned);

    // t3: B's 300 → 300 to A (a transfer, no burn).
    const t3 = rawSpend(a, &.{.{ .txid = t1id, .vout = 1 }}, &.{valueOut(a, 300, &lockOf(A))});
    try l.admitted(tname, t3, &.{0});
    try l.spent(tname, t1, 1, t3);
    try testing.expectEqual(@as(usize, 0), l.events.len);
    try testing.expectEqual(@as(u64, 850), (try countersAt(a, &l)).supply);

    // /holders carries the counters.
    const r = try ls.tokenRoute(a, l.s, l.state, null, null, tokenReq(a, try std.fmt.allocPrint(a, "{s}/holders", .{id})));
    const j = (try std.json.parseFromSliceLeaky(std.json.Value, a, r.getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(i64, 850), j.get("supply").?.integer);
    try testing.expectEqual(@as(i64, 0), j.get("authorities").?.integer);
    try testing.expectEqual(@as(i64, 150), j.get("burned").?.integer);
    try testing.expectEqual(@as(i64, 1), j.get("burns").?.integer);
    try testing.expectEqual(@as(i64, 2), j.get("count").?.integer);

    // t2 rejected: the burn unwound (a revert event), the 350 out of supply, A's 500 and the authority back.
    ls.now_ms = 3000;
    try l.rejected(tname, t2);
    try testing.expectEqual(@as(usize, 1), l.events.len);
    try testing.expectEqualStrings("burn", l.events[0].getText("event").?);
    try testing.expectEqualStrings("revert", l.events[0].get("row").?.getText("kind").?);
    try testing.expectEqual(@as(u64, 150), l.events[0].get("row").?.getUint("amount").?);
    try testing.expectEqual(@as(u64, 3000), l.events[0].get("row").?.getUint("at").?);
    n = try countersAt(a, &l);
    try testing.expectEqual(@as(u64, 850 - 350 + 500), n.supply);
    try testing.expectEqual(@as(u64, 1), n.authorities);
    try testing.expectEqual(@as(u64, 0), n.burned);
    try testing.expectEqual(@as(u64, 0), n.burns);
    // Everything rejected: no record left.
    try l.rejected(tname, t3);
    try l.rejected(tname, t1);
    n = try countersAt(a, &l);
    try testing.expectEqual(@as(u64, 0), n.supply);
    try testing.expectEqual(@as(u64, 0), n.authorities);
    var svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    try testing.expectEqual(@as(usize, 0), try svc.map("counters").count());
    try testing.expectEqual(@as(usize, 0), try svc.map("burns").count());
}

test "holders (0.15.0): /<token>/holders largest first, limit and skip, the count; addresses on the chain state's network; a query out of shape 400" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    var l: Ls = .{ .a = a, .s = s };
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = id_a }));
    var outs: [5][]const u8 = undefined;
    for (&outs, 0..) |*o, i| o.* = valueOut(a, 100 * (i + 1), &lockOf(@intCast(0x40 + i)));
    try l.admitted(tname, rawSpend(a, &.{.{ .txid = .{0x02} ** 32, .vout = 0 }}, &outs), &.{ 0, 1, 2, 3, 4 });
    const id = idString(a, id_a, 0);
    const req = struct {
        fn f(al: std.mem.Allocator, rest: []const u8, query: []const u8) Value {
            const base = tokenReq(al, rest);
            return .{ .map = std.mem.concat(al, w.cbor.Entry, &.{ base.map, &.{.{ .key = "query", .value = text(query) }} }) catch @panic("OOM") };
        }
    }.f;
    const hpath = try std.fmt.allocPrint(a, "{s}/holders", .{id});
    // The chain state on testnet: testnet addresses.
    var ch = try lookup.Chain.load(a, s, null, .@"test");
    const chain = try ch.save();

    const r = try ls.tokenRoute(a, s, l.state, chain, null, req(a, hpath, "limit=2&skip=1"));
    try testing.expectEqual(@as(u64, 200), r.getUint("status").?);
    try testing.expectEqualStrings("public, max-age=5", r.get("headers").?.getText("cache-control").?);
    const j = (try std.json.parseFromSliceLeaky(std.json.Value, a, r.getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(i64, 5), j.get("count").?.integer);
    const rows = j.get("rows").?.array.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(i64, 400), rows[0].object.get("balance").?.integer);
    try testing.expectEqual(@as(i64, 300), rows[1].object.get("balance").?.integer);
    try testing.expectEqualStrings(try ls.addressOf(a, .@"test", .{0x43} ** 20), rows[0].object.get("address").?.string);
    try testing.expect(rows[0].object.get("address").?.string[0] == 'm' or rows[0].object.get("address").?.string[0] == 'n');
    // No query: up to 100, largest first; past the end: none.
    const every = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, chain, null, req(a, hpath, ""))).getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(usize, 5), every.get("rows").?.array.items.len);
    try testing.expectEqual(@as(i64, 500), every.get("rows").?.array.items[0].object.get("balance").?.integer);
    const none = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, chain, null, req(a, hpath, "skip=5"))).getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(usize, 0), none.get("rows").?.array.items.len);
    try testing.expectEqual(@as(i64, 5), none.get("count").?.integer);
    // No chain state: main.
    const main_rows = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, null, null, req(a, hpath, "limit=1"))).getBytes("body").?, .{})).object.get("rows").?.array.items;
    try testing.expectEqual(@as(u8, '1'), main_rows[0].object.get("address").?.string[0]);
    // A token with no holders here: count 0 (no deploy needed on the token's own instance).
    const other = (try std.json.parseFromSliceLeaky(std.json.Value, a, (try ls.tokenRoute(a, s, l.state, chain, null, req(a, try std.fmt.allocPrint(a, "{s}/holders", .{idString(a, .{0x77} ** 32, 0)}), ""))).getBytes("body").?, .{})).object;
    try testing.expectEqual(@as(i64, 0), other.get("count").?.integer);
    for ([_][]const u8{ "limit=0", "limit=101", "skip=100001", "x=1", "limit=a" }) |bad|
        try testing.expectEqual(@as(u64, 400), (try ls.tokenRoute(a, s, l.state, chain, null, req(a, hpath, bad))).getUint("status").?);
}

test "the manifest (shruggr/skein#143): routes, filters and roles; no dispatch, reads or senders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = (try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("etc/app.json"), .{})).object;
    try testing.expect(j.get("dispatch") == null and j.get("reads") == null);
    const gated = j.get("roles").?.object.get("root").?.array.items;
    // No `market` / `validator` (skein-overlay 0.12.0: every skein is both, always; no switch).
    try testing.expectEqual(@as(usize, 3), gated.len);
    for ([_][]const u8{ "register", "registerLookup", "deregisterLookup" }, gated) |x, g| try testing.expectEqualStrings(x, g.string);
    try testing.expectEqualStrings("color-lookup.tokens", j.get("filters").?.object.get("tokens").?.string);
    try testing.expectEqualStrings("color-lookup.token", j.get("filters").?.object.get("token").?.string);
    var tokens_read = false;
    var token_reads = false;
    var register = false;
    for (j.get("routes").?.array.items) |r| {
        try testing.expect(r.object.get("sender") == null and r.object.get("program") == null);
        const addr = r.object.get("address").?.string;
        if (std.mem.eql(u8, addr, "/tokens")) {
            tokens_read = r.object.get("handler") == null and r.object.get("prefix") == null and std.mem.eql(u8, r.object.get("filters").?.array.items[0].string, "tokens");
        }
        // 0.14.0: one prefix row `/` (the token's reads), a read route; no other prefix row; `/color/tokens` gone.
        if (r.object.get("prefix")) |px| {
            try testing.expect(px.bool and std.mem.eql(u8, addr, "/") and !token_reads);
            token_reads = r.object.get("handler") == null and std.mem.eql(u8, r.object.get("filters").?.array.items[0].string, "token");
        }
        try testing.expect(!std.mem.eql(u8, addr, "/color/tokens"));
        if (std.mem.eql(u8, addr, "register")) register = std.mem.eql(u8, r.object.get("handler").?.string, "overlay.register");
    }
    try testing.expect(tokens_read and token_reads and register);
}

test "tokens: newest first by the chain — unmined first, then the higher block, then the later position" {
    const k1 = [_]u8{1} ** 36;
    const k2 = [_]u8{2} ** 36;
    const k3 = [_]u8{3} ** 36;
    const k4 = [_]u8{4} ** 36;
    const k5 = [_]u8{5} ** 36;
    var ages = [_]ls.Age{
        .{ .key = &k1, .height = 100, .offset = 5 },
        .{ .key = &k2, .height = null, .offset = 0 },
        .{ .key = &k3, .height = 200, .offset = 0 },
        .{ .key = &k4, .height = 100, .offset = 9 },
        .{ .key = &k5, .height = null, .offset = 0 },
    };
    std.mem.sort(ls.Age, &ages, {}, ls.newerFirst);
    const want = [_]u8{ 5, 2, 3, 4, 1 };
    for (want, ages) |b, x| try testing.expectEqual(b, x.key[0]);
}

// --- BRC-207 (David Case, 2026-10-08): ls_color_<assetId>, one index for every name ---

/// The service called as `service` over the index, against the chain state `chain` (null: empty).
fn ask207(l: *Ls, service: []const u8, chain: ?[]const u8, q: Value) ![]const []const u8 {
    var svc = try lookup.Service.loadIndex(l.a, l.s, service, ls.index_name, ls.spec.maps, l.state);
    var ch = try lookup.Chain.load(l.a, l.s, chain, .regtest);
    const ans = try ls.answer(l.a, &svc, &ch, q);
    const out = try l.a.alloc([]const u8, ans.output_list.len);
    for (ans.output_list, out) |o, *x| x.* = try std.fmt.allocPrint(l.a, "{s}:{d}", .{ &w.header.toHex(o.txid), o.vout });
    return out;
}

fn q207(a: std.mem.Allocator, typ: []const u8, version: Value, asset: []const u8, t: []const u8, ops: []const []const u8) !Value {
    const xs = try a.alloc(Value, ops.len);
    for (ops, xs) |o, *x| x.* = text(o);
    return .{ .map = try a.dupe(w.cbor.Entry, &.{
        .{ .key = "type", .value = text(typ) },
        .{ .key = "version", .value = version },
        .{ .key = "assetId", .value = text(asset) },
        .{ .key = "topic", .value = text(t) },
        .{ .key = "outpoints", .value = .{ .array = xs } },
    }) };
}

fn dot(a: std.mem.Allocator, raw: []const u8, vout: u32) []const u8 {
    return std.fmt.allocPrint(a, "{s}.{d}", .{ &w.header.toHex(w.beef.txidOf(raw)), vout }) catch @panic("OOM");
}

test "BRC-207: color-spendability and color-admission over ls_color_<assetId>: exactly the queried outpoints, each once; spent and unspent; rejected never admitted; one index under every name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var tb: [names.max_topic_len]u8 = undefined;
    var lb: [names.max_lookup_len]u8 = undefined;
    const nid: names.TokenId = .{ .txid = f.id };
    const tname = try a.dupe(u8, names.topicName(&tb, nid));
    const service = try a.dupe(u8, names.lookupName(&lb, nid));
    const asset = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(f.id)});
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "ls_color_{s}", .{asset}), service);
    // The hooks come once, under whichever name listens first: here the token's own.
    var l: Ls = .{ .a = a, .s = ms.store(), .service = service };
    const deploy = f.raws.get("token_deploy").?;
    const pd = f.raws.get("pool_deploy").?;
    const one: Value = .{ .uint = 1 };
    const spend = "color-spendability";
    const admit = "color-admission";

    // Nothing admitted yet: a valid "no".
    try expectOps(&.{}, try ask207(&l, service, null, try q207(a, spend, one, asset, tname, &.{dot(a, deploy, 0)})));
    try expectOps(&.{}, try ask207(&l, service, null, try q207(a, admit, one, asset, tname, &.{})));

    try l.admitted(tname, deploy, &.{0});
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, service, null, try q207(a, spend, one, asset, tname, &.{dot(a, deploy, 0)})));
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, service, null, try q207(a, admit, one, asset, tname, &.{dot(a, deploy, 0)})));

    // The pool's deploy spends it (held by the chain state: its spender), admitting three value outputs.
    try l.admitted(tname, pd, &.{ 0, 1, 2 });
    try l.spent(tname, deploy, 0, pd);
    var ch = try lookup.Chain.load(a, ms.store(), null, .regtest);
    _ = try ch.putTx(w.beef.txidOf(pd), pd);
    const chain = try ch.save();
    // Spendability: only those admitted and unspent, in the query's order, each once; an outpoint never
    // admitted (an output the topic did not take, another transaction's) is not answered.
    const asked = [_][]const u8{ dot(a, pd, 1), dot(a, deploy, 0), dot(a, pd, 0), dot(a, pd, 1), dot(a, pd, 7), dot(a, f.raws.get("fund").?, 0) };
    try expectOps(&.{ opName(a, pd, 1), opName(a, pd, 0) }, try ask207(&l, service, chain, try q207(a, spend, one, asset, tname, &asked)));
    // Admission: spent ones too (the deploy), each once.
    try expectOps(&.{ opName(a, pd, 1), opName(a, deploy, 0), opName(a, pd, 0) }, try ask207(&l, service, chain, try q207(a, admit, one, asset, tname, &asked)));

    // One index under every name: ls_color's own queries see what the hooks under the token's name wrote.
    const id = text(asset);
    try expectOps(&.{ opName(a, pd, 0), opName(a, pd, 1), opName(a, pd, 2) }, try ask207(&l, ls.service_name, null, .{ .map = &.{.{ .key = "tokenId", .value = id }} }));

    // The pool's deploy rejected: its outputs were never validly admitted; the deploy unspent again.
    try l.rejected(tname, pd);
    try expectOps(&.{}, try ask207(&l, service, null, try q207(a, admit, one, asset, tname, &.{ dot(a, pd, 0), dot(a, pd, 1) })));
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, service, null, try q207(a, spend, one, asset, tname, &.{ dot(a, deploy, 0), dot(a, pd, 0) })));

    // Another token's outputs are not this asset's: another token's service answers nothing of them.
    var lb2: [names.max_lookup_len]u8 = undefined;
    var tb2: [names.max_topic_len]u8 = undefined;
    const other: names.TokenId = .{ .txid = id_a };
    const other_asset = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(id_a)});
    try expectOps(&.{}, try ask207(&l, try a.dupe(u8, names.lookupName(&lb2, other)), null, try q207(a, admit, one, other_asset, try a.dupe(u8, names.topicName(&tb2, other)), &.{dot(a, deploy, 0)})));
}

test "BRC-207: queries validated strictly: version 1, the service's own assetId and topic, canonical <txid>.<vout>, exactly five keys; the per-asset service takes no other query; ls_color takes BRC-207 queries only with topic tm_color (0.12.1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const hex = "a5" ** 32;
    const asset = hex ++ "_0";
    const service = "ls_color_" ++ asset;
    const t = "tm_color_" ++ asset;
    const op = hex ++ ".1";
    const one: Value = .{ .uint = 1 };
    const ok = try ls.parse207(a, service, try q207(a, "color-admission", one, asset, t, &.{ op, op, hex ++ ".0" }));
    try testing.expectEqual(ls.Brc207Type.admission, ok.kind);
    try testing.expectEqual(@as(usize, 2), ok.outpoints.len); // each once
    try testing.expectEqual(@as(u32, 1), ok.outpoints[0].vout);
    try testing.expectEqual(ls.Brc207Type.spendability, (try ls.parse207(a, service, try q207(a, "color-spendability", one, asset, t, &.{}))).kind);
    try testing.expectEqual(@as(u32, 4294967295), (try ls.parse207(a, service, try q207(a, "color-spendability", one, asset, t, &.{hex ++ ".4294967295"}))).outpoints[0].vout);
    // A legacy token's asset at a non-zero output.
    const lasset = hex ++ "_3";
    try testing.expectEqual(@as(u32, 3), (try ls.parse207(a, "ls_color_" ++ lasset, try q207(a, "color-admission", one, lasset, "tm_color_" ++ lasset, &.{op}))).id.vout);

    const bad = [_]Value{
        try q207(a, "color-balance", one, asset, t, &.{op}), // another type
        try q207(a, "Color-Spendability", one, asset, t, &.{op}),
        try q207(a, "color-admission", .{ .uint = 2 }, asset, t, &.{op}), // version 1 only
        try q207(a, "color-admission", text("1"), asset, t, &.{op}),
        try q207(a, "color-admission", .{ .uint = 0 }, asset, t, &.{op}),
        try q207(a, "color-admission", one, hex, t, &.{op}), // the bare txid is not the asset id
        try q207(a, "color-admission", one, hex ++ ".0", t, &.{op}),
        try q207(a, "color-admission", one, "b5" ** 32 ++ "_0", t, &.{op}), // another asset
        try q207(a, "color-admission", one, asset, "tm_" ++ asset, &.{op}), // the old topic name
        try q207(a, "color-admission", one, asset, "tm_color", &.{op}),
        try q207(a, "color-admission", one, asset, "tm_color_" ++ "b5" ** 32 ++ "_0", &.{op}),
        try q207(a, "color-admission", one, asset, t, &.{hex ++ "_1"}), // a token id, not an outpoint
        try q207(a, "color-admission", one, asset, t, &.{"A5" ** 32 ++ ".1"}), // uppercase
        try q207(a, "color-admission", one, asset, t, &.{hex ++ ".01"}), // leading zero
        try q207(a, "color-admission", one, asset, t, &.{hex ++ ".4294967296"}),
        try q207(a, "color-admission", one, asset, t, &.{hex ++ "."}),
        try q207(a, "color-admission", one, asset, t, &.{hex[0..62] ++ ".1"}),
        try q207(a, "color-admission", one, asset, t, &.{hex ++ ".1 "}),
    };
    for (bad) |q| try testing.expectError(error.BadQuery, ls.parse207(a, service, q));
    // Shape: not a map; a key missing; a key more; outpoints not a list of strings.
    const full = try q207(a, "color-admission", one, asset, t, &.{op});
    try testing.expectError(error.BadQuery, ls.parse207(a, service, text("x")));
    try testing.expectError(error.BadQuery, ls.parse207(a, service, .{ .map = full.map[0..4] }));
    try testing.expectError(error.BadQuery, ls.parse207(a, service, .{ .map = try std.mem.concat(a, w.cbor.Entry, &.{ full.map, &.{.{ .key = "limit", .value = one }} }) }));
    var swapped = try a.dupe(w.cbor.Entry, full.map);
    swapped[4] = .{ .key = "outpoints", .value = text(op) };
    try testing.expectError(error.BadQuery, ls.parse207(a, service, .{ .map = swapped }));
    swapped[4] = .{ .key = "outpoints", .value = .{ .array = &.{.{ .uint = 1 }} } };
    try testing.expectError(error.BadQuery, ls.parse207(a, service, .{ .map = swapped }));
    var dup = try a.dupe(w.cbor.Entry, full.map);
    dup[3] = .{ .key = "type", .value = text("color-admission") };
    try testing.expectError(error.BadQuery, ls.parse207(a, service, .{ .map = dup }));

    // Through `answer`: the per-asset service takes only these; ls_color refuses a token topic's form
    // (its BRC-207 form names tm_color, 0.12.1); a name the program does not serve is refused.
    var l: Ls = .{ .a = a, .s = ms.store() };
    try testing.expectError(error.BadQuery, ask207(&l, service, null, .{ .map = &.{.{ .key = "tokenId", .value = text(asset) }} }));
    try testing.expectError(error.BadQuery, ask207(&l, ls.service_name, null, full));
    try testing.expectError(error.UnknownService, ask207(&l, "ls_other", null, full));
    try testing.expectError(error.BadQuery, ls.parse207(a, "ls_color", full));
    try testing.expectError(error.UnknownService, ls.parse207(a, "ls_other", full));
    try testing.expectEqual(@as(usize, 0), (try ask207(&l, service, null, full)).len);
}

test "one index for the program's names (skein-overlay 0.11.0): a hook under any name reaches every one; the index is ls_color" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    try testing.expectEqualStrings("ls_color", ls.spec.index.?);
    try testing.expectEqualStrings("1color/ls_color", try lookup.headName(a, "1color", ls.spec.index.?));
    var tb: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&tb, .{ .txid = f.id }));
    const deploy = f.raws.get("token_deploy").?;
    const id = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(f.id)});
    // One hook for the discovery topic under `ls_color`, one for the token's topic under `ls_color_<assetId>`:
    // each goes by its topic, whatever the name, and every name reads the one index the same way.
    var lb: [names.max_lookup_len]u8 = undefined;
    const lname = try a.dupe(u8, names.lookupName(&lb, .{ .txid = f.id }));
    var l: Ls = .{ .a = a, .s = ms.store(), .service = ls.service_name };
    try l.admitted(names.deploys_topic, deploy, &.{0});
    l.service = lname;
    try l.admitted(tname, deploy, &.{0});
    try testing.expectEqualStrings("ls_color", (try ms.store().getValue(a, l.state.?)).getText("service").?);
    l.service = ls.service_name;
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    // BRC-207's admission of the deploy under both names: over tm_color (ls_color) and over its topic.
    const dot0 = try std.fmt.allocPrint(a, "{s}.0", .{id[0..64]});
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, ls.service_name, null, try q207(a, "color-admission", .{ .uint = 1 }, id, "tm_color", &.{dot0})));
    try expectOps(&.{opName(a, deploy, 0)}, try ask207(&l, lname, null, try q207(a, "color-admission", .{ .uint = 1 }, id, tname, &.{dot0})));
    // The token list reads the same index.
    try testing.expectEqual(@as(usize, 1), (try ls.tokens(a, ms.store(), l.state, null, null, .{})).len);
}

test "undecided (0.13.0, skein-overlay 0.19.0): a transfer whose token sources cannot be read fails MissingParents naming every source it lacks; with them read it is decided; a deploy and a funding-only transaction never want" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = names.topicName(&buf, .{ .txid = f.id });

    // The swap alone: its inputs' sources (the pool, the funding) not in the store; no previous coin
    // here — the token outputs are not covered: undecided, not refused.
    const swap = try s.putBitcoin(a, .tx, f.raws.get("swap_bsv_in").?);
    const swap_tx = try bsvz.transaction.Transaction.parse(a, f.raws.get("swap_bsv_in").?);
    try testing.expectError(error.MissingParents, topic.judge(a, s, program.identify, try callArgs(a, tname, swap, &.{})));
    var want: std.ArrayList([32]u8) = .empty;
    outer: for (swap_tx.inputs) |in| {
        for (want.items) |x| if (std.mem.eql(u8, &x, &in.previous_outpoint.txid.bytes)) continue :outer;
        try want.append(a, in.previous_outpoint.txid.bytes);
    }
    try testing.expectEqual(want.items.len, topic.lastNeeds().len);
    for (want.items, topic.lastNeeds()) |x, y| try testing.expectEqualSlices(u8, &x, &y);
    // The engine reads the same list back out of the error line.
    const line = try std.mem.concat(a, u8, &.{ "call color-topic.identify: topic: ", try topic.missingText(a, topic.lastNeeds()) });
    try testing.expectEqual(want.items.len, (try topic.needsOf(a, line)).?.len);

    // The deploy alone (its funding parent not here): decided — needs no parents.
    const deploy = try s.putBitcoin(a, .tx, f.raws.get("token_deploy").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, tname, deploy, &.{}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rd.get("outputsToAdmit").?));

    // A funding-only transaction under the token's topic: no output of the token — decided, takes nothing.
    const fund = try s.putBitcoin(a, .tx, f.raws.get("fund").?);
    const rf = try topic.judge(a, s, program.identify, try callArgs(a, tname, fund, &.{}));
    try testing.expectEqual(@as(usize, 0), (try uintsOf(a, rf.get("outputsToAdmit").?)).len);

    // Its sources read (held), the coin live: decided and admitted, as before.
    _ = try s.putBitcoin(a, .tx, f.raws.get("pool_deploy").?);
    const ok = try topic.judge(a, s, program.identify, try callArgs(a, tname, swap, &.{0}));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, try uintsOf(a, ok.get("outputsToAdmit").?));
    // Its sources read but the token input no coin of the topic: decided — the rules refuse it (nothing admitted), no MissingParents.
    const no = try topic.judge(a, s, program.identify, try callArgs(a, tname, swap, &.{}));
    try testing.expectEqual(@as(usize, 0), (try uintsOf(a, no.get("outputsToAdmit").?)).len);
}

// --- a deploy is filed by what it holds (0.15.1) ---

fn deployOut(a: std.mem.Allocator, amount: u64, lock: []const u8) []u8 {
    var buf: [10]u8 = undefined;
    return cat(a, &.{ &.{0x00}, brc162.pushAmount(&buf, amount), &.{0x6d}, lock });
}

fn valueOutOf(a: std.mem.Allocator, id: [32]u8, amount: u64, lock: []const u8) []u8 {
    var buf: [10]u8 = undefined;
    return cat(a, &.{ &.{0x20}, &id, brc162.pushAmount(&buf, amount), &.{0x6d}, lock });
}

/// The lookup maps' key of the token deployed at output 0 of `raw` (txid display order ‖ vout BE).
fn tokOf(raw: []const u8) [36]u8 {
    var t = w.beef.txidOf(raw);
    std.mem.reverse(u8, &t);
    return t ++ [_]u8{ 0, 0, 0, 0 };
}

fn holdersAt(a: std.mem.Allocator, l: *Ls, tok: [36]u8) !struct { count: u64, rows: []const ls.Holder } {
    var svc = try lookup.Service.loadIndex(a, l.s, ls.service_name, ls.index_name, ls.spec.maps, l.state);
    const h = try ls.holdersOf(a, &svc, &tok, .main, .{});
    return .{ .count = h.count, .rows = h.rows };
}

test "deploys by what they hold (0.15.1): a supply deploy is a value output — in {tokenId}, a holder of the full supply, moved by its spend; an authority-only deploy stays an authority and holds nothing; BRC-207's admission and spendability answer both as before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    var l: Ls = .{ .a = a, .s = s };
    const A: u8 = 0x1a;
    const B: u8 = 0x1b;

    // A deploy of 1000 to A's P2PKH, on its token topic and on the discovery topic.
    const dep = rawSpend(a, &.{.{ .txid = .{0x05} ** 32, .vout = 0 }}, &.{deployOut(a, 1000, &lockOf(A))});
    const did = w.beef.txidOf(dep);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = did }));
    var lb: [names.max_lookup_len]u8 = undefined;
    const lname = try a.dupe(u8, names.lookupName(&lb, .{ .txid = did }));
    const id = idString(a, did, 0);
    const dot0 = dot(a, dep, 0);
    try l.admitted(tname, dep, &.{0});
    try l.admitted(names.deploys_topic, dep, &.{0});
    try expectOps(&.{opName(a, dep, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(&.{}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    try expectOps(&.{opName(a, dep, 0)}, try l.ask(&.{ .{ .key = "txid", .value = text(id[0..64]) }, .{ .key = "outputIndex", .value = .{ .uint = 0 } } }));
    var h = try holdersAt(a, &l, tokOf(dep));
    try testing.expectEqual(@as(u64, 1), h.count);
    try testing.expectEqual(@as(u64, 1000), h.rows[0].balance);
    try testing.expectEqualStrings(try ls.addressOf(a, .main, .{A} ** 20), h.rows[0].address);
    // BRC-207, unspent: both queries answer the deploy, over its topic and over tm_color.
    for ([_][]const u8{ "color-admission", "color-spendability" }) |ty| {
        try expectOps(&.{opName(a, dep, 0)}, try ask207(&l, lname, null, try q207(a, ty, .{ .uint = 1 }, id, tname, &.{dot0})));
        try expectOps(&.{opName(a, dep, 0)}, try ask207(&l, ls.service_name, null, try q207(a, ty, .{ .uint = 1 }, id, "tm_color", &.{dot0})));
    }

    // Its first spend: 600 to B, 400 back to A. The deploy leaves `values`, the balances move.
    const t2 = rawSpend(a, &.{.{ .txid = did, .vout = 0 }}, &.{ valueOutOf(a, did, 600, &lockOf(B)), valueOutOf(a, did, 400, &lockOf(A)) });
    try l.admitted(tname, t2, &.{ 0, 1 });
    try l.spent(tname, dep, 0, t2);
    try expectOps(&.{ opName(a, t2, 0), opName(a, t2, 1) }, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    h = try holdersAt(a, &l, tokOf(dep));
    try testing.expectEqual(@as(u64, 2), h.count);
    try testing.expectEqual(@as(u64, 600), h.rows[0].balance);
    try testing.expectEqualStrings(try ls.addressOf(a, .main, .{B} ** 20), h.rows[0].address);
    try testing.expectEqual(@as(u64, 400), h.rows[1].balance);
    // BRC-207, spent (the chain state holds the spender): admission still answers it, spendability not.
    var ch = try lookup.Chain.load(a, s, null, .regtest);
    _ = try ch.putTx(did, dep);
    _ = try ch.putTx(w.beef.txidOf(t2), t2);
    const chain = try ch.save();
    try expectOps(&.{opName(a, dep, 0)}, try ask207(&l, lname, chain, try q207(a, "color-admission", .{ .uint = 1 }, id, tname, &.{dot0})));
    try expectOps(&.{}, try ask207(&l, lname, chain, try q207(a, "color-spendability", .{ .uint = 1 }, id, tname, &.{dot0})));
    try expectOps(&.{opName(a, dep, 0)}, try ask207(&l, ls.service_name, chain, try q207(a, "color-admission", .{ .uint = 1 }, id, "tm_color", &.{dot0})));
    try expectOps(&.{}, try ask207(&l, ls.service_name, chain, try q207(a, "color-spendability", .{ .uint = 1 }, id, "tm_color", &.{dot0})));
    // The spend rejected: the deploy is a value output again, A holds the supply.
    try l.rejected(tname, t2);
    try expectOps(&.{opName(a, dep, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    h = try holdersAt(a, &l, tokOf(dep));
    try testing.expectEqual(@as(u64, 1), h.count);
    try testing.expectEqual(@as(u64, 1000), h.rows[0].balance);

    // An authority-only deploy (amount 0) to a P2PKH: an authority, no holder.
    const aut = rawSpend(a, &.{.{ .txid = .{0x06} ** 32, .vout = 0 }}, &.{deployOut(a, 0, &lockOf(A))});
    const aid = w.beef.txidOf(aut);
    const aname = try a.dupe(u8, names.topicName(&buf, .{ .txid = aid }));
    const alname = try a.dupe(u8, names.lookupName(&lb, .{ .txid = aid }));
    const aidText = idString(a, aid, 0);
    const adot = dot(a, aut, 0);
    try l.admitted(aname, aut, &.{0});
    try l.admitted(names.deploys_topic, aut, &.{0});
    try expectOps(&.{opName(a, aut, 0)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(aidText) }}));
    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(aidText) }}));
    try testing.expectEqual(@as(u64, 0), (try holdersAt(a, &l, tokOf(aut))).count);
    for ([_][]const u8{ "color-admission", "color-spendability" }) |ty| {
        try expectOps(&.{opName(a, aut, 0)}, try ask207(&l, alname, null, try q207(a, ty, .{ .uint = 1 }, aidText, aname, &.{adot})));
        try expectOps(&.{opName(a, aut, 0)}, try ask207(&l, ls.service_name, null, try q207(a, ty, .{ .uint = 1 }, aidText, "tm_color", &.{adot})));
    }
    // Both on discovery's list as before.
    try testing.expectEqual(@as(usize, 2), (try ls.tokens(a, s, l.state, null, null, .{})).len);
}

/// A binary deploy whose payload is `{"sym": sym}` (DAG-CBOR), seeded `seed`.
fn symDeploy(a: std.mem.Allocator, seed: u8, sym: []const u8) []u8 {
    const payload = std.mem.concat(a, u8, &.{ &.{ 0xa1, 0x63, 's', 'y', 'm', @as(u8, 0x60) + @as(u8, @intCast(sym.len)) }, sym }) catch @panic("OOM");
    return rawTx(a, seed, &.{ tokenScript(a, null, 1000, pushOf(a, payload)), &p2pkh_lock });
}

fn idsOf(a: std.mem.Allocator, list: []const ls.Listed) []const []const u8 {
    const out = a.alloc([]const u8, list.len) catch @panic("OOM");
    for (list, out) |x, *o| o.* = x.tokenId;
    return out;
}

fn expectIds(want: []const []const u8, got: []const ls.Listed) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y.tokenId);
}

test "tokens q and after (0.16.0): symbol starts-with (ASCII case-insensitive) or token id starts-with, the same rows in the same order; after = the rows strictly after a token; refusals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = s };
    const t = names.deploys_topic;

    const da = symDeploy(a, 0x11, "AB");
    const db = symDeploy(a, 0x12, "abc");
    const dc = symDeploy(a, 0x13, "Xyz");
    const dd = symDeploy(a, 0x14, "b");
    for ([_][]const u8{ da, db, dc, dd }) |raw| try l.admitted(t, raw, &.{0});
    try l.admitted(t, f.raws.get("token_deploy").?, &.{0}); // no symbol: no row
    try l.admitted(t, f.raws.get("legacy_deploy1").?, &.{1}); // a BRC-161 JSON deploy's sym

    const full = try ls.tokens(a, s, l.state, null, null, .{});
    try testing.expectEqual(@as(usize, 6), full.len);
    const idA = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(w.beef.txidOf(da))});
    const idB = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(w.beef.txidOf(db))});

    // q against the plain list filtered by the rule, in its order.
    const legacy_sym = blk: {
        for (full) |x| if (x.vout == 1) break :blk x.sym;
        unreachable;
    };
    var qs: std.ArrayList([]const u8) = .empty;
    try qs.appendSlice(a, &.{ "a", "A", "ab", "AB", "abc", "abcd", "x", "XY", "b", "zz", "_", " ", legacy_sym, idA[0..1], idA[0..2], idA[0..3], idA[0..63], idA[0..64], idA[0..65], idA, try std.fmt.allocPrint(a, "{s}1", .{idA}), idB[0..5] });
    if (legacy_sym.len > 1) try qs.append(a, try std.ascii.allocUpperString(a, legacy_sym[0..1]));
    for (qs.items) |q| {
        const lower = try std.ascii.allocLowerString(a, q);
        var want: std.ArrayList([]const u8) = .empty;
        for (full) |x| {
            const sl = try std.ascii.allocLowerString(a, x.sym);
            if ((x.sym.len > 0 and std.mem.startsWith(u8, sl, lower)) or std.mem.startsWith(u8, x.tokenId, q)) try want.append(a, x.tokenId);
        }
        try expectIds(want.items, try ls.tokens(a, s, l.state, null, null, .{ .q = q }));
    }
    // "a": AB and abc at least; "" is no filter.
    const qa = idsOf(a, try ls.tokens(a, s, l.state, null, null, .{ .q = "a" }));
    var seen: u8 = 0;
    for (qa) |x| {
        if (std.mem.eql(u8, x, idA)) seen |= 1;
        if (std.mem.eql(u8, x, idB)) seen |= 2;
    }
    try testing.expectEqual(@as(u8, 3), seen);
    try expectIds(idsOf(a, full), try ls.tokens(a, s, l.state, null, null, .{ .q = "" }));
    // Both sides find it (a symbol that is its own id's first hex digit): listed once.
    const twice = blk: {
        var seed: u8 = 0x20;
        while (seed < 0xff) : (seed += 1) for ("0123456789abcdef") |ch| {
            const raw = symDeploy(a, seed, &.{ch});
            if (w.header.toHex(w.beef.txidOf(raw))[0] == ch) break :blk raw;
        };
        unreachable;
    };
    var ms2 = w.store.MemStore.init(testing.allocator);
    defer ms2.deinit();
    var l2: Ls = .{ .a = a, .s = ms2.store() };
    try l2.admitted(t, twice, &.{0});
    const q1 = w.header.toHex(w.beef.txidOf(twice))[0..1];
    try testing.expectEqual(@as(usize, 2), (try ls.searched(a, @constCast(&try lookup.Service.loadIndex(a, ms2.store(), ls.service_name, ls.index_name, ls.spec.maps, l2.state)), q1)).len);
    try testing.expectEqual(@as(usize, 1), (try ls.tokens(a, ms2.store(), l2.state, null, null, .{ .q = q1 })).len);

    // after: strictly after that token in the list's order, with and without q; limit as ever.
    for (full, 0..) |x, i| {
        try expectIds(idsOf(a, full[i + 1 ..]), try ls.tokens(a, s, l.state, null, null, .{ .after = x.tokenId }));
        const page = try ls.tokens(a, s, l.state, null, null, .{ .after = x.tokenId, .limit = 1 });
        try testing.expectEqual(@min(@as(usize, 1), full.len - i - 1), page.len);
        const qa_after = try ls.tokens(a, s, l.state, null, null, .{ .q = "a", .after = x.tokenId });
        const qa_full = try ls.tokens(a, s, l.state, null, null, .{ .q = "a" });
        var want: std.ArrayList([]const u8) = .empty;
        for (qa_full) |y| for (full[i + 1 ..]) |z| if (std.mem.eql(u8, y.tokenId, z.tokenId)) try want.append(a, y.tokenId);
        try expectIds(want.items, qa_after);
    }
    // An after not on the list.
    try testing.expectError(error.UnknownAfter, ls.tokens(a, s, l.state, null, null, .{ .after = "ee" ** 32 ++ "_0" }));
    const unknown: Value = .{ .map = &.{.{ .key = "query", .value = text("after=" ++ "ee" ** 32 ++ "_0") }} };
    try testing.expectEqual(@as(u64, 400), (try ls.tokensRoute(a, s, l.state, null, null, unknown)).getUint("status").?);
    const ok: Value = .{ .map = &.{.{ .key = "query", .value = .{ .text = try std.fmt.allocPrint(a, "q=ab&after={s}&limit=2", .{full[0].tokenId}) } }} };
    try testing.expectEqual(@as(u64, 200), (try ls.tokensRoute(a, s, l.state, null, null, ok)).getUint("status").?);

    // A rejected deploy's symbol row goes with it.
    try l.rejected(t, da);
    for (try ls.tokens(a, s, l.state, null, null, .{ .q = "ab" })) |x| try testing.expect(!std.mem.eql(u8, x.tokenId, idA));
    try testing.expectError(error.UnknownAfter, ls.tokens(a, s, l.state, null, null, .{ .after = idA }));

    // The query string: q percent-decoded, `+` a space; after exactly `<txid>_<vout>`.
    try testing.expectEqualStrings("a b", (try ls.parseTokensQuery(a, "q=a+b", "")).q.?);
    try testing.expectEqualStrings("a,b", (try ls.parseTokensQuery(a, "q=a%2Cb", "")).q.?);
    try testing.expectEqualStrings("", (try ls.parseTokensQuery(a, "q=", "")).q.?);
    const t1 = "ab" ** 32 ++ "_0";
    const both = try ls.parseTokensQuery(a, "q=x&after=" ++ t1 ++ "&limit=5", "");
    try testing.expectEqualStrings(t1, both.after.?);
    try testing.expectEqual(@as(u64, 5), both.limit);
    _ = try ls.parseTokensQuery(a, "q=x&skip=3", ""); // q beside skip is fine
    for ([_][2][]const u8{
        .{ "after=" ++ t1 ++ "&skip=1", "" }, .{ "after=" ++ t1, "{\"skip\":0}" }, .{ "ids=" ++ t1 ++ "&q=a", "" },
        .{ "ids=" ++ t1 ++ "&after=" ++ t1, "" }, .{ "q=a&q=b", "" },        .{ "after=" ++ t1 ++ "&after=" ++ t1, "" },
        .{ "after=" ++ "ab" ** 32, "" },          .{ "after=x", "" },              .{ "q=" ++ "a" ** 101, "" },
        .{ "q=%zz", "" },                         .{ "", "{\"q\":\"a\"}" },
    }) |cse| try testing.expectError(error.BadQuery, ls.parseTokensQuery(a, cse[0], cse[1]));
    _ = try ls.parseTokensQuery(a, "q=" ++ "a" ** 100, "");
}
