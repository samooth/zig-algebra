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

    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: u256) Self { return .{ .value = @intCast(x % modulus) }; }
    pub fn toInt(self: Self) u64 { return self.value; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value + b.value); }
    pub fn sub(a: Self, b: Self) Self { return fromInt(a.value + (modulus - b.value % modulus)); }
    pub fn neg(a: Self) Self { return if (a.value == 0) zero() else fromInt(modulus - a.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(a.value * b.value); }
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
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
    pub fn random() Self { return fromInt(1); } // stub
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
    const p = PoseidonF7.initFromSeed("test");

    const a = F7.fromInt(1);
    const b = F7.fromInt(2);
    const h = p.hash2(a, b);

    // Deterministic
    const h2 = p.hash2(a, b);
    try std.testing.expect(h.eql(h2));
}

test "MiMC over F7" {
    const MiMCF7 = mimc.MiMC(F7, 91, 5);
    const m = MiMCF7.initFromSeed("test");

    const a = F7.fromInt(1);
    const b = F7.fromInt(2);
    const h = m.hash2(a, b);

    // Deterministic
    const h2 = m.hash2(a, b);
    try std.testing.expect(h.eql(h2));
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
    const out = blake3.hashBytes(&msg);
    const out2 = blake3.hashBytes(&msg);
    try std.testing.expectEqualSlices(u8, &out, &out2);
}

test "Blake3 empty message" {
    const out = blake3.hashBytes("");
    const out2 = blake3.hashBytes("");
    try std.testing.expectEqualSlices(u8, &out, &out2);
}
