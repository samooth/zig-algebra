//! zig-hash: Cryptographic hash functions for Zig.
//!
//! Includes:
//! - Blake3 (fast, parallelizable, XOF)
//! - Blake2b / Blake2s (RFC 7693)
//! - Keccak-256 / SHA3-256
//! - Poseidon (ZK-friendly, algebraic)
//! - MiMC (minimal constraints for SNARKs)
//! - Pedersen hash (elliptic-curve based, trait-based)

const std = @import("std");

pub const blake3 = @import("blake3.zig");
pub const blake2 = @import("blake2.zig");
pub const keccak = @import("keccak.zig");
pub const poseidon = @import("poseidon.zig");
pub const mimc = @import("mimc.zig");

// Re-exports for convenience
pub const Blake3 = blake3.Blake3;
pub const Blake2b256 = blake2.Blake2b256;
pub const Blake2s256 = blake2.Blake2s256;
pub const Keccak256 = keccak.Keccak256;
pub const Sha3_256 = keccak.Sha3_256;
pub const Poseidon = poseidon.Poseidon;
pub const MiMC = mimc.MiMC;

// One-shot functions
pub const hashBlake3 = blake3.hash;
pub const hashBlake2b256 = blake2.blake2b256;
pub const hashBlake2s256 = blake2.blake2s256;
pub const hashKeccak256 = keccak.keccak256;
pub const hashSha3_256 = keccak.sha3_256;

// Common hash interface (matches zig-stark's core/hash/hash.zig)
pub const Hash = struct {
    pub const Digest = [32]u8;

    pub fn hashBytes(msg: []const u8) Digest {
        return blake3.hash(msg);
    }

    pub fn hash2(a: Digest, b: Digest) Digest {
        var h = blake3.Blake3.init(.{});
        h.update("zig-stark:pair");
        h.update(&a);
        h.update(&b);
        var out: Digest = undefined;
        h.final(&out);
        return out;
    }
};

// ============================================================================
// Tests
// ============================================================================

// Minimal F7 field for algebraic hash tests
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
    } // stub
};

test "Blake3 basic hash" {
    const msg = "hello world";
    const out = blake3.hash(msg);
    // Known test vector for "hello world" (first 32 bytes)
    // Just verify it doesn't crash and produces consistent output
    const out2 = blake3.hash(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);

    // Different message -> different hash
    const out3 = blake3.hash("hello world!");
    try std.testing.expect(!std.mem.eql(u8, &out, &out3));
}

test "cryptographic hash known-answer vectors" {
    const blake3_expected = [_]u8{
        0xbd, 0x21, 0x4b, 0x44, 0x72, 0xd4, 0x17, 0xe0,
        0xfb, 0x4a, 0x4a, 0x26, 0x86, 0x91, 0x7b, 0xef,
        0x98, 0x50, 0x9c, 0x51, 0xac, 0xb5, 0xa0, 0x43,
        0x85, 0x54, 0xb8, 0xd3, 0xd5, 0xcd, 0x69, 0x18,
    };
    try std.testing.expectEqualSlices(u8, &blake3_expected, &blake3.hash("hello world"));

    const blake2b_expected = [_]u8{
        0xbd, 0xdd, 0x81, 0x3c, 0x63, 0x42, 0x39, 0x72,
        0x31, 0x71, 0xef, 0x3f, 0xee, 0x98, 0x57, 0x9b,
        0x94, 0x96, 0x4e, 0x3b, 0xb1, 0xcb, 0x3e, 0x42,
        0x72, 0x62, 0xc8, 0xc0, 0x68, 0xd5, 0x23, 0x19,
    };
    try std.testing.expectEqualSlices(u8, &blake2b_expected, &blake2.blake2b256("abc"));

    const blake2s_expected = [_]u8{
        0x50, 0x8c, 0x5e, 0x8c, 0x32, 0x7c, 0x14, 0xe2,
        0xe1, 0xa7, 0x2b, 0xa3, 0x4e, 0xeb, 0x45, 0x2f,
        0x37, 0x45, 0x8b, 0x20, 0x9e, 0xd6, 0x3a, 0x29,
        0x4d, 0x99, 0x9b, 0x4c, 0x86, 0x67, 0x59, 0x82,
    };
    try std.testing.expectEqualSlices(u8, &blake2s_expected, &blake2.blake2s256("abc"));

    const keccak_expected = [_]u8{
        0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f,
        0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67,
        0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36,
        0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45,
    };
    try std.testing.expectEqualSlices(u8, &keccak_expected, &keccak.keccak256("abc"));

    const sha3_expected = [_]u8{
        0x3a, 0x98, 0x5d, 0xa7, 0x4f, 0xe2, 0x25, 0xb2,
        0x04, 0x5c, 0x17, 0x2d, 0x6b, 0xd3, 0x90, 0xbd,
        0x85, 0x5f, 0x08, 0x6e, 0x3e, 0x9d, 0x52, 0x5b,
        0x46, 0xbf, 0xe2, 0x45, 0x11, 0x43, 0x15, 0x32,
    };
    try std.testing.expectEqualSlices(u8, &sha3_expected, &keccak.sha3_256("abc"));

    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const poseidon_hash = try PoseidonF7.initFromSeed("demo");
    try std.testing.expectEqual(@as(u64, 3), poseidon_hash.hash2(F7.fromInt(1), F7.fromInt(2)).value);

    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const mimc_hash = try MiMCF7.initFromSeed("demo");
    try std.testing.expectEqual(@as(u64, 5), mimc_hash.hash2(F7.fromInt(1), F7.fromInt(2)).value);
}

test "Blake3 keyed hash" {
    const key = [_]u8{0x01} ** 32;
    const out = blake3.keyedHash(&key, "test");
    const out2 = blake3.keyedHash(&key, "test");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake3 derive key" {
    const out = blake3.deriveKey("context", "material");
    const out2 = blake3.deriveKey("context", "material");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake2b256 basic" {
    const msg = "abc";
    const out = blake2.blake2b256(msg);
    const out2 = blake2.blake2b256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake2s256 basic" {
    const msg = "abc";
    const out = blake2.blake2s256(msg);
    const out2 = blake2.blake2s256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Keccak256 basic" {
    const msg = "abc";
    const out = keccak.keccak256(msg);
    const out2 = keccak.keccak256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "SHA3-256 basic" {
    const msg = "abc";
    const out = keccak.sha3_256(msg);
    const out2 = keccak.sha3_256(msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Keccak vs SHA3 different" {
    const msg = "abc";
    const k = keccak.keccak256(msg);
    const s = keccak.sha3_256(msg);
    try std.testing.expect(!std.mem.eql(u8, &k, &s));
}

test "Poseidon over F7" {
    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const p = try PoseidonF7.initFromSeed("test");

    const a = F7.fromInt(1);
    const b = F7.fromInt(2);
    const h = p.hash2(a, b);

    // Deterministic
    const h2 = p.hash2(a, b);
    try std.testing.expect(h.eql(h2));
}

test "MiMC over F7" {
    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const m = try MiMCF7.initFromSeed("test");

    const a = F7.fromInt(1);
    const b = F7.fromInt(2);
    const h = m.hash2(a, b);

    // Deterministic
    const h2 = m.hash2(a, b);
    try std.testing.expect(h.eql(h2));
}

test "Poseidon and MiMC reject oversized seeds" {
    const PoseidonF7 = poseidon.Poseidon(F7, 3, 8, 57, 5);
    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const seed = try std.testing.allocator.alloc(u8, poseidon.MAX_SEED_LEN + 1);
    defer std.testing.allocator.free(seed);
    try std.testing.expectError(error.SeedTooLong, PoseidonF7.initFromSeed(seed));
    try std.testing.expectError(error.SeedTooLong, MiMCF7.initFromSeed(seed));
}

test "streaming Blake3" {
    var hasher = Blake3.init();
    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");
    var out: [32]u8 = undefined;
    hasher.finalize(&out);

    const expected = blake3.hash("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "streaming Keccak256" {
    var hasher = Keccak256.init();
    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");
    var out: [32]u8 = undefined;
    hasher.finalize(&out);

    const expected = keccak.keccak256("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "streaming SHA3-256" {
    var hasher = Sha3_256.init();
    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");
    var out: [32]u8 = undefined;
    hasher.finalize(&out);

    const expected = keccak.sha3_256("hello world");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "Blake3 long message" {
    const msg = "a" ** 10000;
    const out = blake3.hash(msg[0..]);
    const out2 = blake3.hash(msg[0..]);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake3 empty message" {
    const out = blake3.hash("");
    const out2 = blake3.hash("");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}
