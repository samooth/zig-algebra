//! zig-rng example: demonstrates ChaCha20, Shake256, Fisher-Yates, and field sampling.

const std = @import("std");
const rng = @import("root.zig");

// Minimal F7 field for demonstration
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: u256) Self {
        return .{ .value = @intCast(x % modulus) };
    }
    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn add(a: Self, b: Self) Self {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value + (modulus - b.value % modulus));
    }
    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(modulus - a.value);
    }
    pub fn mul(a: Self, b: Self) Self {
        return fromInt(a.value * b.value);
    }
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }
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
    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }
    pub fn random() Self {
        return fromInt(1);
    }
};

fn printHex(name: []const u8, bytes: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}: ", .{name});
    for (bytes) |b| try stdout.print("{x:0>2}", .{b});
    try stdout.print("\n", .{});
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== zig-rng example ===\n\n", .{});

    // --- ChaCha20 ---
    try stdout.print("--- ChaCha20Rng ---\n", .{});
    const seed = [_]u8{0x42} ** 32;
    var chacha = rng.ChaCha20Rng.initFromSeed(&seed);

    try stdout.print("random u64:  {}\n", .{chacha.randomU64()});
    try stdout.print("random u64:  {}\n", .{chacha.randomU64()});
    try stdout.print("random u32:  {}\n", .{chacha.randomU32()});
    try stdout.print("random bool: {}\n", .{chacha.randomBool()});
    try stdout.print("bounded [0,100): {}\n", .{chacha.randomU64Bounded(100)});

    var buf: [32]u8 = undefined;
    chacha.randomBytes(&buf);
    try printHex("random bytes", &buf);

    // --- Shake256 ---
    try stdout.print("\n--- Shake256Rng ---\n", .{});
    var shake = rng.Shake256Rng.init();
    shake.absorbSeed("my protocol seed");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const s1 = try shake.squeeze(32, allocator);
    defer allocator.free(s1);
    try printHex("squeeze 32", s1);

    const s2 = try shake.squeeze(64, allocator);
    defer allocator.free(s2);
    try printHex("squeeze 64", s2);

    // --- Fisher-Yates ---
    try stdout.print("\n--- Fisher-Yates shuffle ---\n", .{});
    var chacha2 = rng.ChaCha20Rng.initFromSeed(&seed);
    var deck = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    rng.shuffle(u8, rng.ChaCha20Rng, &chacha2, &deck);
    try stdout.print("shuffled deck: ", .{});
    for (deck) |c| try stdout.print("{} ", .{c});
    try stdout.print("\n", .{});

    // --- Random permutation ---
    try stdout.print("\n--- Random permutation ---\n", .{});
    var chacha3 = rng.ChaCha20Rng.initFromSeed(&seed);
    const perm = try rng.randomPermutation(rng.ChaCha20Rng, &chacha3, 8, allocator);
    defer allocator.free(perm);
    try stdout.print("permutation of [0..8): ", .{});
    for (perm) |p| try stdout.print("{} ", .{p});
    try stdout.print("\n", .{});

    // --- Rejection sampling for finite field ---
    try stdout.print("\n--- Rejection sampling (F7) ---\n", .{});
    var chacha4 = rng.ChaCha20Rng.initFromSeed(&seed);
    try stdout.print("random field elements: ", .{});
    for (0..10) |_| {
        const f = rng.randomFieldElement(F7, rng.ChaCha20Rng, &chacha4);
        try stdout.print("{} ", .{f.value});
    }
    try stdout.print("\n", .{});

    try stdout.print("\nAll RNG operations completed successfully!\n", .{});
}
