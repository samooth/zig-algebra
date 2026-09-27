//! zig-hash example

const std = @import("std");
const hash = @import("root.zig");
const zf = @import("zig-field");

/// The real field, imported. This file used to declare its own minimal F7 with
/// 17 methods -- including an `invChecked` that nothing had ever executed --
/// because the library did not depend on `zig-field`. It was a fork of the
/// field interface inside a hash example, unbuilt and untested.
const F7 = zf.Field(7);

fn printHex(name: []const u8, bytes: []const u8) void {
    std.debug.print("{s}: ", .{name});
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
}

pub fn main() !void {
    std.debug.print("=== zig-hash example ===\n\n", .{});

    const msg = "hello world";

    // Blake3
    const b3 = hash.hashBlake3(msg);
    printHex("Blake3(\"hello world\")", &b3);

    // Blake2b
    const b2b = hash.hashBlake2b256(msg);
    printHex("Blake2b256(\"hello world\")", &b2b);

    // Blake2s
    const b2s = hash.hashBlake2s256(msg);
    printHex("Blake2s256(\"hello world\")", &b2s);

    // Keccak-256
    const k = hash.hashKeccak256(msg);
    printHex("Keccak256(\"hello world\")", &k);

    // SHA3-256
    const s3 = hash.hashSha3_256(msg);
    printHex("SHA3-256(\"hello world\")", &s3);

    // Poseidon over F7
    const PoseidonF7 = hash.Poseidon(F7, 3, 8, 57, 5);
    const p = try PoseidonF7.initFromSeed("demo");
    const pf = p.hash2(F7.fromInt(1), F7.fromInt(2));
    std.debug.print("\nPoseidon(F7)(1, 2) = {}\n", .{pf.value});

    // MiMC over F7
    const MiMCF7 = hash.MiMC(F7, 91, 5);
    const m = try MiMCF7.initFromSeed("demo");
    const mf = m.hash2(F7.fromInt(1), F7.fromInt(2));
    std.debug.print("MiMC(F7)(1, 2) = {}\n", .{mf.value});

    // Streaming example
    var hasher = hash.Blake3.init();
    hasher.update("The quick brown ");
    hasher.update("fox jumps over ");
    hasher.update("the lazy dog");
    var stream_out: [32]u8 = undefined;
    hasher.finalize(&stream_out);
    printHex("\nBlake3(streaming)", &stream_out);

    std.debug.print("\nAll hashes computed successfully!\n", .{});
}
