//! zig-hash example

const std = @import("std");
const hash = @import("root.zig");

// Minimal F7 field for Poseidon/MiMC demo
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: u256) Self { return .{ .value = @intCast(x % modulus) }; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value + b.value); }
    pub fn sub(a: Self, b: Self) Self { return fromInt(a.value + (modulus - b.value % modulus)); }
    pub fn neg(a: Self) Self { return if (a.value == 0) zero() else fromInt(modulus - a.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(a.value * b.value); }
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub fn div(a: Self, b: Self) Self { return mul(a, inv(b)); }
    pub fn pow(base: Self, exp: u64) Self {
        var result = one();
        var b = base;
        var e = exp;
        while (e > 0) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
            e >>= 1;
        }
        return result;
    }
    pub fn isZero(self: Self) bool { return self.value == 0; }
    pub fn random() Self { return fromInt(1); }
};

fn printHex(name: []const u8, bytes: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}: ", .{name});
    for (bytes) |b| {
        try stdout.print("{x:0>2}", .{b});
    }
    try stdout.print("\n", .{});
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== zig-hash example ===\n\n", .{});

    const msg = "hello world";

    // Blake3
    const b3 = hash.hashBlake3(msg);
    try printHex("Blake3(\"hello world\")", &b3);

    // Blake2b
    const b2b = hash.hashBlake2b256(msg);
    try printHex("Blake2b256(\"hello world\")", &b2b);

    // Blake2s
    const b2s = hash.hashBlake2s256(msg);
    try printHex("Blake2s256(\"hello world\")", &b2s);

    // Keccak-256
    const k = hash.hashKeccak256(msg);
    try printHex("Keccak256(\"hello world\")", &k);

    // SHA3-256
    const s3 = hash.hashSha3_256(msg);
    try printHex("SHA3-256(\"hello world\")", &s3);

    // Poseidon over F7
    const PoseidonF7 = hash.Poseidon(F7, 3, 8, 57, 5);
    const p = PoseidonF7.initFromSeed("demo");
    const pf = p.hash2(F7.fromInt(1), F7.fromInt(2));
    try stdout.print("\nPoseidon(F7)(1, 2) = {}\n", .{pf.value});

    // MiMC over F7
    const MiMCF7 = hash.MiMC(F7, 91, 5);
    const m = MiMCF7.initFromSeed("demo");
    const mf = m.hash2(F7.fromInt(1), F7.fromInt(2));
    try stdout.print("MiMC(F7)(1, 2) = {}\n", .{mf.value});

    // Streaming example
    var hasher = hash.Blake3.init();
    hasher.update("The quick brown ");
    hasher.update("fox jumps over ");
    hasher.update("the lazy dog");
    var stream_out: [32]u8 = undefined;
    hasher.finalize(&stream_out);
    try printHex("\nBlake3(streaming)", &stream_out);

    try stdout.print("\nAll hashes computed successfully!\n", .{});
}
