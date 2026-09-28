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
pub const Gcd = gcd.ExtendedGcd;
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
    const x = try Big.fromU128(0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF);
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
    const x = try Big.fromU128(0xFFFFFFFFFFFFFFFF);
    const y = try Big.fromU128(0xFFFFFFFFFFFFFFFF);
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
    const res = try G.egcd(a, b);
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

test "BigInt multi-limb division" {
    const Big = BigInt(2);
    const a = try Big.fromU128((@as(u128, 1) << 127) + 123);
    const b = try Big.fromU128((@as(u128, 1) << 64) + 5);
    const qr = try a.divRem(b);
    try std.testing.expect(qr.q.eql(try Big.fromU128(0x7FFFFFFFFFFFFFFD)));
    try std.testing.expect(qr.r.eql(try Big.fromU128(0x800000000000008A)));
}

test "BigInt constructors handle signed minimum and one-limb limits" {
    const Big = BigInt(8);
    const min = Big.fromI64(std.math.minInt(i64));
    try std.testing.expect(min.isNegative());
    try std.testing.expect(min.abs().eql(Big.fromU64(1 << 63)));

    const One = BigInt(1);
    _ = try One.fromU128(std.math.maxInt(u64));
    try std.testing.expectError(error.Overflow, One.fromU128(@as(u128, 1) << 64));
}

test "modInverse accessible via Gcd re-export" {
    const G = Gcd(8);
    const Big = BigInt(8);
    const inv = try G.modInv(Big.fromU64(3), Big.fromU64(11));
    try std.testing.expect(inv.eql(Big.fromU64(4))); // 3*4 = 12 ≡ 1 mod 11
}

test "modInv rejects a negative modulus and a zero modulus" {
    // Guards `modInv`'s modulus check. A negative modulus is the interesting
    // one: `mod` and the final `mod(m)` on a negative modulus are not the
    // modular inverse anybody means, and the guard is the only thing stopping
    // them. Written mutation-first: with the `isNegative` arm removed, the
    // negative case below returns instead of erroring.
    const Big = BigInt(8);
    const G = ExtendedGcd(8);

    try std.testing.expectError(error.InvalidModulus, G.modInv(Big.fromU64(3), Big.zero()));
    try std.testing.expectError(
        error.InvalidModulus,
        G.modInv(Big.fromU64(3), Big.fromU64(11).neg()),
    );

    // And the positive path still works, so the guard is not simply rejecting
    // everything.
    try std.testing.expect((try G.modInv(Big.fromU64(3), Big.fromU64(11))).eql(Big.fromU64(4)));
}

test "modInv with a full-width modulus returns an error instead of trapping" {
    // The witness. This used to be undefined behaviour: `egcd`'s `q * r` needs
    // twice the width of the container, `BigInt.mul` returns `error.Overflow`
    // for it, and `catch unreachable` turned that into a trap in Debug and UB
    // in ReleaseFast. Any `a` reaches it on the first iteration.
    const L: usize = 2;
    const G = ExtendedGcd(L);
    const Big = bigint.BigInt(L);

    // bitLength(m) == 64 * max_limbs: the container exactly full, top bit set.
    const m = Big{ .limbs = .{ 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF }, .len = L, .negative = false };
    try std.testing.expectEqual(error.Overflow, G.modInv(Big.fromU64(2), m));
    try std.testing.expectEqual(error.Overflow, G.modInv(Big.fromU64(3), m));

    // `egcd` itself is the thing that could not report, and now does.
    try std.testing.expectEqual(error.Overflow, G.egcd(Big.fromU64(2), m));

    // **There is no `bitLength(m) <= X` rule that makes this unreachable, and
    // the doc must not pretend otherwise.** Measured on a 256-bit container:
    // the widest modulus that survives is 193 bits for `a` in 2..13, and **218
    // bits** for `a = 2^31 - 1`, so the boundary moves with the *trajectory*,
    // not with the modulus. A width bound of "container minus one" or "minus
    // two" is therefore unsafe: both admit inputs that overflow. The honest
    // rule is the one in the doc -- size the `BigInt` with headroom for the
    // modulus you intend, and treat `error.Overflow` as a real answer.
    const L4: usize = 4;
    const G4 = ExtendedGcd(L4);
    const B4 = bigint.BigInt(L4);
    const ofWidth = struct {
        fn f(w: usize) B4 {
            var limbs = [_]u64{0xFFFF_FFFF_FFFF_FFFF} ** L4;
            var i = w;
            while (i < 256) : (i += 1) limbs[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
            return B4{ .limbs = limbs, .len = (w + 63) / 64, .negative = false };
        }
    }.f;
    // 218 works for this `a`, and 255 -- "container minus one" -- does not, which
    // is the measurement that rules the bound out rather than asserting it.
    try std.testing.expect(G4.modInv(B4.fromU64(2_147_483_647), ofWidth(218)) != error.Overflow);
    try std.testing.expectEqual(error.Overflow, G4.modInv(B4.fromU64(2_147_483_647), ofWidth(255)));
}

test "modExp: the width threshold is 32*max_limbs, and the base does not move it" {
    // Measured across three precisions, and with **two** bases on purpose. A
    // test with only a wide base would pass for the wrong reason: the
    // mechanism says `b` is squared every iteration and so reaches full width
    // regardless of where it started, so the narrow base has to give the same
    // number. If it ever does not, the threshold is not the thing we measured.
    inline for (.{ 2, 4, 8 }) |L| {
        const M = modexp.ModExp(L);
        const B = bigint.BigInt(L);
        const ofWidth = struct {
            fn f(comptime B2: type, w: usize) B2 {
                var limbs = [_]u64{0xFFFF_FFFF_FFFF_FFFF} ** L;
                var i = w;
                while (i < 64 * L) : (i += 1) limbs[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
                return B2{ .limbs = limbs, .len = (w + 63) / 64, .negative = false };
            }
        }.f;

        var wide_threshold: usize = 0;
        var narrow_threshold: usize = 0;
        var w: usize = 1;
        while (w <= 64 * L) : (w += 1) {
            const m = ofWidth(B, w);
            const wide = m.sub(B.one()) catch m;
            if (M.modExp(wide, B.fromU64(65537), m) != error.InvalidModulusWidth) wide_threshold = w;
            if (M.modExp(B.fromU64(3), B.fromU64(65537), m) != error.InvalidModulusWidth) narrow_threshold = w;
        }

        // The threshold is exactly half the container, in bits.
        try std.testing.expectEqual(@as(usize, 32 * L), wide_threshold);
        // And the base is irrelevant, which is the mechanism, not a coincidence.
        try std.testing.expectEqual(wide_threshold, narrow_threshold);
        // One bit past it is the declared error, and it is the *renamed* one.
        const at = ofWidth(B, wide_threshold);
        try std.testing.expectEqual(
            error.InvalidModulusWidth,
            M.modExp(B.fromU64(3), B.fromU64(65537), ofWidth(B, wide_threshold + 1)),
        );
        // The boundary itself still works.
        try std.testing.expect(M.modExp(B.fromU64(3), B.fromU64(65537), at) != error.InvalidModulusWidth);
    }
}

test "modExp: a plain multiplication still says Overflow, not InvalidModulusWidth" {
    // The rename is local to the modular exponentiation. `mul` is the door for
    // all of `bigint` and cannot know a modulus is involved, so raising the
    // error there would make this lie about a modulus that does not exist.
    const L: usize = 2;
    const B = bigint.BigInt(L);
    const big = B{ .limbs = [_]u64{0xFFFF_FFFF_FFFF_FFFF} ** L, .len = L, .negative = false };
    try std.testing.expectEqual(error.Overflow, big.mul(big));
}
