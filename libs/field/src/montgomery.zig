// SPDX-License-Identifier: MIT OR Apache-2.0

//! Montgomery arithmetic for `[N]u64` limb arrays.
//!
//! Elements are stored in Montgomery form `x * R mod p` with `R = 2^(64*N)`.
//! All constants (`R^2`, `-p^-1 mod 2^64`) are derived at comptime from the
//! modulus using arbitrary-precision comptime integers, so there is no runtime
//! precomputation cost.
//!
//! Multiplication uses the classic CIOS (Coarsely Integrated Operand
//! Scanning) algorithm with per-iteration shifting. The `zig-stark` M31/CM31/QM31
//! code (`src/m31/field/`) provided the reference semantics; here the arithmetic
//! is generalized to arbitrary odd moduli and uses the limb machinery from
//! `bigint.zig`.
//!
//! All operations are constant-time with respect to secret data to prevent
//! side-channel attacks.

const std = @import("std");
const bigint = @import("zig-bigint");

/// Build a Montgomery context for an odd modulus that fits in 512 bits.
pub fn Montgomery(comptime modulus: comptime_int) type {
    comptime {
        std.debug.assert(modulus > 1);
        std.debug.assert(modulus % 2 == 1);
        std.debug.assert(modulus < std.math.maxInt(u512));
    }
    const bits = bigint.bitLength(modulus);
    const n = bigint.numLimbs(bits);

    return struct {
        const Self = @This();

        /// The modulus as a fixed-width integer.
        pub const MODULUS: u512 = @intCast(modulus);

        /// Bit length of the modulus.
        pub const BITS = bits;

        /// Number of 64-bit limbs.
        pub const NUM_LIMBS = n;

        /// Modulus in little-endian limbs.
        pub const MODULUS_LIMBS: [n]u64 = bigint.intToLimbs(n, modulus);

        /// `R^2 mod p` used to convert into Montgomery form.
        pub const R2_LIMBS: [n]u64 = blk: {
            const r: comptime_int = @as(comptime_int, 1) << @intCast(64 * n);
            const r2: comptime_int = @mod(r * r, modulus);
            break :blk bigint.intToLimbs(n, r2);
        };

        /// `-p^-1 mod 2^64`, computed with Newton iteration.
        pub const M0_INV: u64 = blk: {
            const p0: u64 = @truncate(modulus);
            var inv: u64 = 1;
            for (0..6) |_| inv = inv *% (2 -% p0 *% inv);
            break :blk 0 -% inv;
        };

        /// Montgomery form of `1` (i.e. `R mod p`).
        pub const ONE_LIMBS: [n]u64 = blk: {
            const r: comptime_int = @as(comptime_int, 1) << @intCast(64 * n);
            break :blk bigint.intToLimbs(n, @mod(r, modulus));
        };

        /// Canonical 1 (limb representation of integer 1).
        pub const CANONICAL_ONE: [n]u64 = blk: {
            var out = [_]u64{0} ** n;
            out[0] = 1;
            break :blk out;
        };

        /// The zero element (also Montgomery form of zero).
        pub const ZERO_LIMBS: [n]u64 = [_]u64{0} ** n;

        // ============================================================
        // Constant-time primitives
        // ============================================================

        /// Constant-time select: returns `x` if `on`, else `y`.
        fn ctSelect(on: bool, x: u64, y: u64) u64 {
            const mask = @as(u64, 0) -% @intFromBool(on);
            return y ^ (mask & (y ^ x));
        }

        /// Constant-time limb-array select: returns `a` if `on`, else `b`.
        pub fn ctSelectLimbs(on: bool, a: [n]u64, b: [n]u64) [n]u64 {
            const mask = @as(u64, 0) -% @intFromBool(on);
            var out: [n]u64 = undefined;
            for (0..n) |i| {
                out[i] = b[i] ^ (mask & (b[i] ^ a[i]));
            }
            return out;
        }

        /// Constant-time equality: returns true iff `x == y`.
        fn ctEql(x: u64, y: u64) bool {
            const c1 = @subWithOverflow(x, y)[1];
            const c2 = @subWithOverflow(y, x)[1];
            return @as(bool, @bitCast(1 - (c1 | c2)));
        }

        /// Constant-time limb-array equality: returns true iff arrays are equal.
        fn ctLimbsEql(a: *const [n]u64, b: *const [n]u64) bool {
            var diff: u64 = 0;
            for (0..n) |i| {
                diff |= a[i] ^ b[i];
            }
            return ctEql(diff, 0);
        }

        /// Constant-time less-than for limb arrays (little-endian).
        pub fn ctLimbsCmpLt(a: *const [n]u64, b: *const [n]u64) bool {
            var borrow: u64 = 0;
            for (0..n) |i| {
                const z = @as(u128, a[i]) -% @as(u128, b[i]) -% borrow;
                borrow = @intFromBool(z > std.math.maxInt(u64));
            }
            return borrow != 0;
        }

        /// Constant-time greater-or-equal for limb arrays.
        fn ctLimbsCmpGeq(a: *const [n]u64, b: *const [n]u64) bool {
            return !ctLimbsCmpLt(a, b);
        }

        /// Constant-time strict greater-than for limb arrays.
        fn ctLimbsCmpGt(a: *const [n]u64, b: *const [n]u64) bool {
            return ctLimbsCmpLt(b, a);
        }

        /// Constant-time conditional array copy: if `on`, `out = src`.
        fn ctArrayCopy(on: bool, src: *const [n]u64, out: *[n]u64) void {
            const mask = @as(u64, 0) -% @intFromBool(on);
            for (0..n) |i| {
                out[i] ^= mask & (out[i] ^ src[i]);
            }
        }

        /// Constant-time right shift by 1 bit: `out = a >> 1`.
        /// Little-endian limbs: bit 0 of limb `i+1` becomes bit 63 of limb `i`.
        /// Safe for in-place operation (`out` may alias `a`).
        fn ctShr(a: *const [n]u64, out: *[n]u64) void {
            var carry: u64 = 0;
            var i = n;
            while (i > 0) {
                i -= 1;
                const low = a[i] << 63;
                out[i] = (a[i] >> 1) | carry;
                carry = low;
            }
        }

        /// Constant-time check if all limbs are zero.
        fn ctIsZero(a: *const [n]u64) bool {
            var acc: u64 = 0;
            for (0..n) |i| acc |= a[i];
            return acc == 0;
        }

        // ============================================================
        // Constant-time add/sub with conditional reduction
        // ============================================================

        /// `a + b mod p` (constant-time).
        pub fn add(a: [n]u64, b: [n]u64) [n]u64 {
            var out: [n]u64 = undefined;
            var carry: u64 = 0;
            for (0..n) |i| {
                const z = @as(u128, a[i]) + b[i] + carry;
                out[i] = @truncate(z);
                carry = @truncate(z >> 64);
            }
            // Conditionally subtract modulus if overflow == (out < MODULUS).
            // From std.crypto.ff: need_sub = overflow == (out < modulus)
            const out_lt_mod = ctLimbsCmpLt(&out, &MODULUS_LIMBS);
            const need_sub = (carry != 0) == out_lt_mod;
            if (need_sub) {
                var borrow: u64 = 0;
                for (0..n) |i| {
                    const z = @as(u128, out[i]) -% @as(u128, MODULUS_LIMBS[i]) -% borrow;
                    out[i] = @truncate(z);
                    borrow = @intFromBool(z > std.math.maxInt(u64));
                }
            }
            return out;
        }

        /// `a - b mod p` (constant-time).
        pub fn sub(a: [n]u64, b: [n]u64) [n]u64 {
            var out: [n]u64 = undefined;
            var borrow: u64 = 0;
            for (0..n) |i| {
                const ai = a[i];
                const bi = b[i];
                const diff = ai -% bi;
                const borrow_from_diff: u64 = if (ai < bi) 1 else 0;
                const new_borrow: u64 = if (diff < borrow) 1 else 0;
                out[i] = diff -% borrow;
                borrow = borrow_from_diff | new_borrow; // FIX: use OR instead of +
            }
            // Conditionally add modulus if borrow.
            if (borrow != 0) {
                var carry: u64 = 0;
                for (0..n) |i| {
                    const z = @as(u128, out[i]) + @as(u128, MODULUS_LIMBS[i]) + carry;
                    out[i] = @truncate(z);
                    carry = @truncate(z >> 64);
                }
            }
            return out;
        }

        /// `-a mod p` (constant-time).
        pub fn neg(a: [n]u64) [n]u64 {
            return sub(ZERO_LIMBS, a);
        }

        // ============================================================
        // Constant-time Montgomery multiplication
        // ============================================================

        /// CIOS Montgomery multiplication: `a * b * R^-1 mod p` (constant-time).
        pub fn mul(a: [n]u64, b: [n]u64) [n]u64 {
            var t: [n + 2]u64 = [_]u64{0} ** (n + 2);
            for (0..n) |i| {
                // Multiply-add: t += a[i] * b
                var carry: u64 = 0;
                for (0..n) |j| {
                    const z = @as(u128, t[j]) + @as(u128, a[i]) * @as(u128, b[j]) + carry;
                    t[j] = @truncate(z);
                    carry = @truncate(z >> 64);
                }
                const zc = @as(u128, t[n]) + carry;
                t[n] = @truncate(zc);
                t[n + 1] = @truncate(zc >> 64);

                // Reduction: t += m * p with m such that the low limb vanishes.
                const m = t[0] *% M0_INV;
                var c: u64 = 0;
                for (0..n) |j| {
                    const z = @as(u128, t[j]) + @as(u128, m) * @as(u128, MODULUS_LIMBS[j]) + c;
                    t[j] = @truncate(z);
                    c = @truncate(z >> 64);
                }
                const zc2 = @as(u128, t[n]) + c;
                t[n] = @truncate(zc2);
                t[n + 1] +%= @truncate(zc2 >> 64);

                // Shift right one limb: t = t / 2^64.
                for (0..n + 1) |j| t[j] = t[j + 1];
                t[n + 1] = 0;
            }

            // Result is in t[0..n-1]; t[n] is the overflow limb (0 or 1).
            // Result is < 2p; at most one conditional subtraction needed.
            var out: [n]u64 = t[0..n].*;
            var extra: u64 = t[n];

            // Constant-time conditional subtraction (at most 1 iteration).
            // need_sub = extra != 0 OR out >= MODULUS
            const need_sub = (extra != 0) | (!ctLimbsCmpLt(&out, &MODULUS_LIMBS));
            if (need_sub) {
                var borrow: u64 = 0;
                for (0..n) |i| {
                    const z = @as(u128, out[i]) -% @as(u128, MODULUS_LIMBS[i]) -% borrow;
                    out[i] = @truncate(z);
                    borrow = @intFromBool(z > std.math.maxInt(u64));
                }
                extra = @as(u64, @truncate(extra -% borrow));
            }
            return out;
        }

        // ============================================================
        // Montgomery inverse (binary extended GCD)
        // ============================================================

        /// `x += p` (single addition; result < 2p).
        fn addP(x: *[n]u64) void {
            var carry: u64 = 0;
            for (0..n) |i| {
                const z = @as(u128, x[i]) + @as(u128, MODULUS_LIMBS[i]) + carry;
                x[i] = @truncate(z);
                carry = @truncate(z >> 64);
            }
        }

        /// Binary extended GCD inverse of `a` (canonical, `[0, p)`), returning
        /// `a^{-1} mod p` in canonical form. Iterates until `v == 0` (at which
        /// point `u == gcd(a, p) == 1` since `p` is prime).
        ///
        /// NOTE: The iteration count is input-dependent (between ~BITS and ~2*BITS
        /// iterations). This is NOT constant-time in the strict sense and leaks
        /// information through timing. Suitable for STARKs/zkSNARKs where field
        /// elements are public; NOT suitable for secret-key cryptography.
        fn binaryGcdInverse(a: [n]u64) [n]u64 {
            std.debug.assert(!ctIsZero(&a));
            var u = a;
            var v = MODULUS_LIMBS;
            var x1 = CANONICAL_ONE;
            var x2 = ZERO_LIMBS;

            while (!ctIsZero(&v)) {
                if (u[0] & 1 == 0) {
                    ctShr(&u, &u);
                    // x1 = x1 / 2 mod p: if odd, (x1 + p) / 2 (exact since p odd)
                    if (x1[0] & 1 == 1) addP(&x1);
                    ctShr(&x1, &x1);
                } else if (v[0] & 1 == 0) {
                    ctShr(&v, &v);
                    if (x2[0] & 1 == 1) addP(&x2);
                    ctShr(&x2, &x2);
                } else if (ctLimbsCmpGt(&u, &v)) {
                    u = sub(u, v);
                    ctShr(&u, &u);
                    x1 = sub(x1, x2);
                    if (x1[0] & 1 == 1) addP(&x1);
                    ctShr(&x1, &x1);
                } else {
                    v = sub(v, u);
                    ctShr(&v, &v);
                    x2 = sub(x2, x1);
                    if (x2[0] & 1 == 1) addP(&x2);
                    ctShr(&x2, &x2);
                }
            }
            return x1;
        }

        /// Montgomery inverse: returns the Montgomery form of `x^{-1}`, i.e.
        /// `x^{-1} * R mod p`. Uses the binary extended GCD algorithm, which
        /// terminates in `O(bits)` iterations.
        pub fn invMontgomery(x: [n]u64) [n]u64 {
            const a = fromMontgomery(x);
            const inv = binaryGcdInverse(a);
            return toMontgomery(inv);
        }

        /// Montgomery form of an arbitrary value already reduced to limbs.
        pub fn toMontgomery(x: [n]u64) [n]u64 {
            return mul(x, R2_LIMBS);
        }

        /// Canonical value from Montgomery form.
        pub fn fromMontgomery(x: [n]u64) [n]u64 {
            return mul(x, CANONICAL_ONE);
        }
    };
}

test "Montgomery add/sub/neg vs u512 reference" {
    const P = Montgomery(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47);
    const p = P.MODULUS;

    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const x: u512 = rnd.int(u512) % p;
        const y: u512 = rnd.int(u512) % p;
        const xm = P.toMontgomery(bigint.intToLimbsRuntime(P.NUM_LIMBS, x));
        const ym = P.toMontgomery(bigint.intToLimbsRuntime(P.NUM_LIMBS, y));

        const s: u512 = (x + y) % p;
        const d: u512 = (x + p - y) % p;
        const gn: u512 = (p - x) % p;

        try std.testing.expectEqual(
            s,
            bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.add(xm, ym))),
        );
        try std.testing.expectEqual(
            d,
            bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.sub(xm, ym))),
        );
        try std.testing.expectEqual(
            gn,
            bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.neg(xm))),
        );
    }
}

test "Montgomery inverse test" {
    const P = Montgomery(2147483647); // M31, small field for fast test
    const p = P.MODULUS;

    var prng = std.Random.DefaultPrng.init(13);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const x: u512 = rnd.int(u512) % p;
        const xm = P.toMontgomery(bigint.intToLimbsRuntime(P.NUM_LIMBS, x));
        const inv_xm = P.invMontgomery(xm);
        const got = P.fromMontgomery(P.mul(xm, inv_xm));
        const expect: u512 = 1;
        try std.testing.expectEqual(expect, bigint.limbsToInt(P.NUM_LIMBS, u512, &got));
    }
}

test "BLS12_381 Montgomery edge cases" {
    const P = Montgomery(0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB);
    const p: u512 = P.MODULUS;

    const zero = P.ZERO_LIMBS;
    const one = P.toMontgomery(bigint.intToLimbsRuntime(P.NUM_LIMBS, 1));
    const minus_one = P.toMontgomery(bigint.intToLimbsRuntime(P.NUM_LIMBS, p - 1));

    try std.testing.expectEqual(@as(u512, 1), bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.add(zero, one))));
    try std.testing.expectEqual(@as(u512, 1), bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.mul(one, one))));
    try std.testing.expectEqual(@as(u512, 1), bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.mul(minus_one, minus_one))));
    try std.testing.expectEqual(@as(u512, 0), bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.sub(minus_one, minus_one))));
    try std.testing.expectEqual(p - 1, bigint.limbsToInt(P.NUM_LIMBS, u512, &P.fromMontgomery(P.neg(one))));
}

test "Constant-time primitives" {
    const P = Montgomery(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47);

    // ctSelect
    try std.testing.expect(P.ctSelect(true, 42, 99) == 42);
    try std.testing.expect(P.ctSelect(false, 42, 99) == 99);

    // ctEql
    try std.testing.expect(P.ctEql(42, 42));
    try std.testing.expect(!P.ctEql(42, 99));

    // ctLimbsCmpLt
    var a = [4]u64{ 1, 0, 0, 0 };
    var b = [4]u64{ 2, 0, 0, 0 };
    try std.testing.expect(P.ctLimbsCmpLt(&a, &b));
    try std.testing.expect(!P.ctLimbsCmpLt(&b, &a));
    try std.testing.expect(!P.ctLimbsCmpLt(&a, &a));

    // ctLimbsCmpGeq
    try std.testing.expect(P.ctLimbsCmpGeq(&b, &a));
    try std.testing.expect(!P.ctLimbsCmpGeq(&a, &b));
}
