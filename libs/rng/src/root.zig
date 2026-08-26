//! zig-rng: Cryptographically secure and deterministic random number generators.
//!
//! Provides:
//! - **ChaCha20Rng**: Stream-cipher-based CSPRNG (RFC 8439).
//! - **Shake256Rng**: XOF-based CSPRNG (SHAKE256 extendable-output function).
//! - **Rejection sampling**: Unbiased random field elements and bounded integers.
//! - **Fisher-Yates**: Uniform random shuffles and permutations.
//!
//! All generators are deterministic given a seed, making them ideal for
//! reproducible tests, zero-knowledge proofs, and cryptographic protocols.

const std = @import("std");

pub const chacha20 = @import("chacha20.zig");
pub const shake256 = @import("shake256.zig");
pub const rng = @import("rng.zig");
pub const csprng = @import("csprng.zig");

// Re-exports
pub const ChaCha20Rng = chacha20.ChaCha20Rng;
pub const Shake256Rng = shake256.Shake256Rng;
pub const RngTrait = rng.RngTrait;
pub const randomFieldElement = rng.randomFieldElement;
pub const randomU64Bounded = rng.randomU64Bounded;
pub const shuffle = rng.shuffle;
pub const randomPermutation = rng.randomPermutation;
pub const randomBool = rng.randomBool;
pub const randomU64 = rng.randomU64;
pub const randomU32 = rng.randomU32;
pub const randomU8 = rng.randomU8;

// ============================================================================
// Tests
// ============================================================================

// Minimal F7 field for rejection-sampling tests
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
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
    pub fn toInt(self: Self) u64 {
        return self.value;
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
    pub const inverse = inv;
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

test "ChaCha20Rng deterministic" {
    const seed = [_]u8{0x42} ** 32;
    var rng1 = ChaCha20Rng.initFromSeed(&seed);
    var rng2 = ChaCha20Rng.initFromSeed(&seed);

    for (0..100) |_| {
        try std.testing.expectEqual(rng1.randomU64(), rng2.randomU64());
    }
}

test "ChaCha20Rng different seeds produce different output" {
    var rng1 = ChaCha20Rng.initFromSeed(&[_]u8{0x01} ** 32);
    var rng2 = ChaCha20Rng.initFromSeed(&[_]u8{0x02} ** 32);
    try std.testing.expect(rng1.randomU64() != rng2.randomU64());
}

test "ChaCha20Rng randomU64Bounded" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0xAB} ** 32);
    for (0..100) |_| {
        const v = chacha.randomU64Bounded(100);
        try std.testing.expect(v < 100);
    }
}

test "ChaCha20Rng randomBytes" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0xCD} ** 32);
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    chacha.randomBytes(&buf1);
    chacha.randomBytes(&buf2);
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "Shake256Rng deterministic" {
    var rng1 = Shake256Rng.init();
    rng1.absorbSeed("test seed");
    var rng2 = Shake256Rng.init();
    rng2.absorbSeed("test seed");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const b1 = try rng1.squeeze(64, allocator);
    defer allocator.free(b1);
    const b2 = try rng2.squeeze(64, allocator);
    defer allocator.free(b2);

    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "Shake256Rng different seeds" {
    var rng1 = Shake256Rng.init();
    rng1.absorbSeed("seed A");
    var rng2 = Shake256Rng.init();
    rng2.absorbSeed("seed B");

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const b1 = try rng1.squeeze(32, allocator);
    defer allocator.free(b1);
    const b2 = try rng2.squeeze(32, allocator);
    defer allocator.free(b2);

    try std.testing.expect(!std.mem.eql(u8, b1, b2));
}

test "Shake256Rng squeezeInto allocation-free" {
    var shake1 = Shake256Rng.init();
    shake1.absorbSeed("fixed");
    var out: [48]u8 = undefined;
    shake1.squeezeInto(&out);

    var shake2 = Shake256Rng.init();
    shake2.absorbSeed("fixed");
    var out2: [48]u8 = undefined;
    shake2.squeezeInto(&out2);

    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Fisher-Yates shuffle" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x99} ** 32);
    var items = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    shuffle(u32, ChaCha20Rng, &chacha, &items);

    // Verify all elements are still present (no duplicates or losses)
    var seen = std.StaticBitSet(10).initEmpty();
    for (items) |x| {
        try std.testing.expect(x < 10);
        try std.testing.expect(!seen.isSet(x));
        seen.set(x);
    }
}

test "randomPermutation" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x77} ** 32);
    const perm = try randomPermutation(ChaCha20Rng, &chacha, 8, std.testing.allocator);
    defer std.testing.allocator.free(perm);

    var seen = std.StaticBitSet(8).initEmpty();
    for (perm) |x| {
        try std.testing.expect(x < 8);
        try std.testing.expect(!seen.isSet(x));
        seen.set(x);
    }
}

test "randomFieldElement F7" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x11} ** 32);
    for (0..50) |_| {
        const f = randomFieldElement(F7, ChaCha20Rng, &chacha);
        try std.testing.expect(f.value < 7);
    }
}

test "randomBool" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x22} ** 32);
    var true_count: usize = 0;
    for (0..1000) |_| {
        if (randomBool(ChaCha20Rng, &chacha)) true_count += 1;
    }
    // Should be roughly 500, definitely not 0 or 1000
    try std.testing.expect(true_count > 300);
    try std.testing.expect(true_count < 700);
}

test "randomU64Bounded edge cases" {
    var chacha = ChaCha20Rng.initFromSeed(&[_]u8{0x33} ** 32);
    try std.testing.expectEqual(@as(u64, 0), randomU64Bounded(ChaCha20Rng, &chacha, 1));
    try std.testing.expectEqual(@as(u64, 0), randomU64Bounded(ChaCha20Rng, &chacha, 2));
}
