// skein-1color (shruggr/skein#120): the 1Color (BRC-162; BRC-207) overlay
// components for a skein, as programs another app's tree carries, and the
// token library they are built on. Zig 0.16.0, wasm32-wasi, over
// skein-overlay's topic and lookup contracts (a URL+hash dependency; the
// SDK comes through it).
//
// Module (an app depends on skein-1color by URL+hash and
// `b.dependency("skein_1color", .{ .target = t, .optimize = o }).module("1color")`):
//
//   1color    the BRC-162 / BRC-161 output parsers, the BSV-21 rules, topic   src/lib.zig
//             names, the topic's verdict (std only)
//
//   zig build         → zig-out/bin/color-topic.wasm (tm_color_<assetId>, tm_color), color-lookup.wasm (ls_color, ls_color_deploys, ls_color_<assetId>)
//   zig build bin     the same, written to bin/*.wasm (committed)
//   zig build test    the parsers, the rules, the topic, the lookup, natively
const std = @import("std");

const Mods = struct { color: *std.Build.Module, imports: [7]std.Build.Module.Import };

/// The modules a program or the tests import, for one target.
fn mods(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Mods {
    const ov = b.dependency("skein_overlay", .{ .target = target, .optimize = optimize });
    const sdk = ov.builder.dependency("skein_sdk", .{ .target = target, .optimize = optimize });
    const color = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    return .{ .color = color, .imports = .{
        .{ .name = "1color", .module = color },
        .{ .name = "chain", .module = sdk.module("chain") },
        .{ .name = "topic", .module = ov.module("topic") },
        .{ .name = "lookup", .module = ov.module("lookup") },
        .{ .name = "overlay_sk", .module = ov.module("sk") },
        .{ .name = "sk", .module = sdk.module("sk") },
        .{ .name = "cbor", .module = sdk.module("cbor") },
    } };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The exported module (what a dependent app imports), for the target it asks for.
    _ = b.addModule("1color", .{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });

    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wm = mods(b, wasi, .ReleaseSafe);
    const bin = b.addUpdateSourceFiles();
    for ([_][2][]const u8{ .{ "color-topic", "src/color_topic.zig" }, .{ "color-lookup", "src/color_lookup.zig" } }) |p| {
        const exe = b.addExecutable(.{
            .name = p[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(p[1]),
                .target = wasi,
                .optimize = .ReleaseSafe,
                .strip = true,
                .imports = &wm.imports,
            }),
        });
        b.installArtifact(exe);
        bin.addCopyFileToSource(exe.getEmittedBin(), b.fmt("bin/{s}.wasm", .{p[0]}));
    }
    b.step("bin", "write the modules into the tree: bin/{color-topic,color-lookup}.wasm").dependOn(&bin.step);

    const nm = mods(b, target, .Debug);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &nm.imports,
    }) });
    const test_step = b.step("test", "The parsers, the rules, the topic, the lookup, natively");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
