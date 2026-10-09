//! zig-hash example

const std = @import("std");
const testing = std.testing;
const hash = @import("root.zig");
const kat = hash.kat;
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

    // Every digest below is checked against `kat`, which holds values from
    // implementations independent of this tree. A hash is never checked against
    // itself: that is how `blake3.zig` was not BLAKE3 for the whole life of this
    // repository while a "known-answer vectors" test passed. Printing a digest
    // verifies nothing.
    const b3 = hash.hashBlake3(msg);
    try testing.expectEqualSlices(u8, &kat.blake3_hello_world, &b3);
    printHex("Blake3(\"hello world\")", &b3);

    // Blake2b
    const b2b = hash.hashBlake2b256("abc");
    try testing.expectEqualSlices(u8, &kat.blake2b256_abc, &b2b);
    printHex("Blake2b256(\"abc\")", &b2b);

    // Blake2s
    const b2s = hash.hashBlake2s256("abc");
    try testing.expectEqualSlices(u8, &kat.blake2s256_abc, &b2s);
    printHex("Blake2s256(\"abc\")", &b2s);

    // Keccak-256
    const k = hash.hashKeccak256("abc");
    try testing.expectEqualSlices(u8, &kat.keccak256_abc, &k);
    printHex("Keccak256(\"abc\")", &k);

    // SHA3-256
    const s3 = hash.hashSha3_256("abc");
    try testing.expectEqualSlices(u8, &kat.sha3_256_abc, &s3);
    printHex("SHA3-256(\"abc\")", &s3);

    // Poseidon over F7
    const PoseidonF7 = hash.Poseidon(F7, 3, 8, 57, 5);
    const p = try PoseidonF7.initFromSeed("demo");
    const pf = p.hash2(F7.fromInt(1), F7.fromInt(2));
    try testing.expectEqual(kat.poseidon_f7_1_2, pf.value);
    std.debug.print("\nPoseidon(F7)(1, 2) = {}\n", .{pf.value});

    // MiMC over F7
    const MiMCF7 = hash.MiMC(F7, 91, 5);
    const m = try MiMCF7.initFromSeed("demo");
    const mf = m.hash2(F7.fromInt(1), F7.fromInt(2));
    try testing.expectEqual(kat.mimc_f7_1_2, mf.value);
    std.debug.print("MiMC(F7)(1, 2) = {}\n", .{mf.value});

    // Streaming example. The two interfaces must agree, and they must agree on a
    // message long enough to cross a block boundary -- with one update they are
    // the same code path, so a short split cannot measure anything.
    var hasher = hash.Blake3.init();
    hasher.update("The quick brown ");
    hasher.update("fox jumps over ");
    hasher.update("the lazy dog");
    var stream_out: [32]u8 = undefined;
    hasher.finalize(&stream_out);
    try testing.expectEqualSlices(u8, &hash.hashBlake3("The quick brown fox jumps over the lazy dog"), &stream_out);
    printHex("\nBlake3(streaming)", &stream_out);

    std.debug.print("\nAll digests verified against independent vectors.\n", .{});
}
