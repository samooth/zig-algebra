//! zig-bigint: Arbitrary-precision integer arithmetic for Zig.
//!
//! Allocation-free, comptime-configurable precision.
//! Backed by fixed-size `[N]u64` limb arrays.

const std = @import("std");

pub const limb = @import("limb.zig");
pub const bigint = @import("bigint.zig");
pub const gcd = @import("gcd.zig");
pub const modexp = @import("modexp.zig");
pub const prime = @import("prime.zig");

pub const Limb = limb.Limb;
pub const DoubleLimb = limb.DoubleLimb;
pub const BigInt = bigint.BigInt;
pub const ExtendedGcd = gcd.ExtendedGcd;
pub const ModExp = modexp.ModExp;
pub const PrimalityTest = prime.PrimalityTest;

// Re-export limb array helpers for use by zig-field (Montgomery arithmetic)
pub const bitLength = limb.bitLength;
pub const numLimbs = limb.numLimbs;
pub const intToLimbs = limb.intToLimbs;
pub const intToLimbsRuntime = limb.intToLimbsRuntime;
pub const limbsToInt = limb.limbsToInt;
pub const cmp = limb.cmp;
pub const add = limb.add;
pub const sub = limb.sub;
pub const shl = limb.shl;
pub const shr = limb.shr;
pub const mul = limb.mul;

// ============================================================================
// Tests
// ============================================================================

test "BigInt construction and comparison" {
    const Big = BigInt(8);

    const a = Big.fromU64(42);
    const b = Big.fromU64(42);
    const c = Big.fromU64(43);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(a.lt(c));
    try std.testing.expect(c.gt(a));
    try std.testing.expect(a.isZero() == false);
    try std.testing.expect(Big.zero().isZero() == true);
}

test "BigInt addition" {
    const Big = BigInt(8);

    const a = Big.fromU64(123);
    const b = Big.fromU64(456);
    const sum = try a.add(b);
    try std.testing.expect(sum.eql(Big.fromU64(579)));

    // Large number addition
    const x = Big.fromU128(0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF);
    const y = Big.fromU64(1);
    const z = try x.add(y);
    try std.testing.expect(z.limbs[0] == 0);
    try std.testing.expect(z.limbs[1] == 0);
    try std.testing.expect(z.limbs[2] == 1);
}

test "BigInt subtraction" {
    const Big = BigInt(8);

    const a = Big.fromU64(100);
    const b = Big.fromU64(30);
    const diff = try a.sub(b);
    try std.testing.expect(diff.eql(Big.fromU64(70)));

    // Subtraction resulting in negative
    const neg = try b.sub(a);
    try std.testing.expect(neg.isNegative());
    try std.testing.expect(neg.abs().eql(Big.fromU64(70)));
}

test "BigInt multiplication" {
    const Big = BigInt(8);

    const a = Big.fromU64(12345);
    const b = Big.fromU64(6789);
    const prod = try a.mul(b);
    try std.testing.expect(prod.eql(Big.fromU64(12345 * 6789)));

    // Large multiplication
    const x = Big.fromU128(0xFFFFFFFFFFFFFFFF);
    const y = Big.fromU128(0xFFFFFFFFFFFFFFFF);
    const z = try x.mul(y);
    try std.testing.expect(z.limbs[0] == 1); // (2^64-1)^2 = 2^128 - 2^65 + 1
    try std.testing.expect(z.limbs[1] == 0xFFFFFFFFFFFFFFFE);
}

test "BigInt division by single limb" {
    const Big = BigInt(8);

    const a = Big.fromU64(100);
    const dr = try a.divRemU64(7);
    try std.testing.expect(dr.q.eql(Big.fromU64(14)));
    try std.testing.expect(dr.r == 2);
}

test "BigInt division" {
    const Big = BigInt(8);

    const a = Big.fromU64(1000);
    const b = Big.fromU64(7);
    const qr = try a.divRem(b);
    try std.testing.expect(qr.q.eql(Big.fromU64(142)));
    try std.testing.expect(qr.r.eql(Big.fromU64(6)));
}

test "BigInt modular arithmetic" {
    const Big = BigInt(8);

    const a = Big.fromU64(17);
    const m = Big.fromU64(5);
    const r = try a.mod(m);
    try std.testing.expect(r.eql(Big.fromU64(2)));
}

test "BigInt shift" {
    const Big = BigInt(8);

    const a = Big.fromU64(1);
    const b = try a.shl(64);
    try std.testing.expect(b.limbs[1] == 1);
    try std.testing.expect(b.limbs[0] == 0);

    const c = b.shr(64);
    try std.testing.expect(c.eql(Big.fromU64(1)));
}

test "BigInt string conversion" {
    const Big = BigInt(8);

    const a = Big.fromU64(123456789);
    const s = try a.toString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("123456789", s);

    const b = try Big.fromString("9876543210");
    try std.testing.expect(b.eql(Big.fromU64(9876543210)));
}

test "Extended GCD" {
    const Big = BigInt(8);
    const G = ExtendedGcd(8);

    const a = Big.fromU64(240);
    const b = Big.fromU64(46);
    const res = G.egcd(a, b);
    try std.testing.expect(res.g.eql(Big.fromU64(2)));

    // Verify: a*x + b*y = g
    const ax = try a.mul(res.x);
    const by = try b.mul(res.y);
    const sum = try ax.add(by);
    try std.testing.expect(sum.eql(res.g));
}

test "Modular inverse" {
    const Big = BigInt(8);
    const G = ExtendedGcd(8);

    const a = Big.fromU64(3);
    const m = Big.fromU64(11);
    const inv = try G.modInv(a, m);
    // 3 * 4 = 12 = 1 mod 11
    try std.testing.expect(inv.eql(Big.fromU64(4)));
}

test "Modular exponentiation" {
    const Big = BigInt(8);
    const ME = ModExp(8);

    const base = Big.fromU64(2);
    const exp = Big.fromU64(10);
    const mod_val = Big.fromU64(1000);
    const result = try ME.modExp(base, exp, mod_val);
    try std.testing.expect(result.eql(Big.fromU64(24))); // 2^10 = 1024, 1024 mod 1000 = 24

    // Test with u64 exponent
    const result2 = try ME.modExpU64(base, 10, mod_val);
    try std.testing.expect(result2.eql(Big.fromU64(24)));
}

test "Miller-Rabin primality" {
    const Big = BigInt(8);
    const P = PrimalityTest(8);

    // Small primes
    try std.testing.expect(try P.millerRabin(Big.fromU64(2), 7));
    try std.testing.expect(try P.millerRabin(Big.fromU64(3), 7));
    try std.testing.expect(try P.millerRabin(Big.fromU64(97), 7));
    try std.testing.expect(try P.millerRabin(Big.fromU64(104729), 7)); // 10000th prime

    // Composites
    try std.testing.expect(!try P.millerRabin(Big.fromU64(100), 7));
    try std.testing.expect(!try P.millerRabin(Big.fromU64(91), 7)); // 7*13
    try std.testing.expect(!try P.millerRabin(Big.fromU64(1), 7));
}

test "BigInt negative numbers" {
    const Big = BigInt(8);

    const a = Big.fromI64(-42);
    try std.testing.expect(a.isNegative());
    try std.testing.expect(a.abs().eql(Big.fromU64(42)));

    const b = Big.fromI64(30);
    const sum = try a.add(b);
    try std.testing.expect(sum.eql(Big.fromI64(-12)));

    const prod = try a.mul(b);
    try std.testing.expect(prod.isNegative());
    try std.testing.expect(prod.abs().eql(Big.fromU64(1260)));
}

test "BigInt bit operations" {
    const Big = BigInt(8);

    const a = Big.fromU64(0b1010);
    const b = Big.fromU64(0b1100);

    const band = a.bitAnd(b);
    try std.testing.expect(band.eql(Big.fromU64(0b1000)));

    const bor = a.bitOr(b);
    try std.testing.expect(bor.eql(Big.fromU64(0b1110)));

    const bxor = a.bitXor(b);
    try std.testing.expect(bxor.eql(Big.fromU64(0b0110)));
}
