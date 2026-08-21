// SPDX-License-Identifier: MIT OR Apache-2.0

//! Field-generic algorithms shared by every backend: Legendre symbol,
//! square roots (Tonelli–Shanks), exponentiation by limb-array exponents and
//! power-of-two roots of unity.
//!
//! These functions take the concrete field `F` as a `comptime` type argument
//! and only depend on its arithmetic surface (`fromInt`, `add`, `mul`, `pow`,
//! `neg`, `eq`, `one`, `zero`) plus the constants `MODULUS`, `two_adicity` and
//! `odd_part`. Both the small and big backends in `field.zig` implement that
//! surface, and the extension fields reuse `powByLimbs`.

const std = @import("std");
const bigint = @import("bigint.zig");

/// Legendre symbol `(a / p)`: `1` if `a` is a quadratic residue, `-1` if not,
/// `0` if `a == 0`.
///
/// Uses `a^((p-1)/2) == (a / p)` (Euler's criterion).
pub fn legendre(comptime F: type, a: F) i8 {
    const half = (F.odd_part << @intCast(F.two_adicity - 1));
    const r = a.pow(half);
    if (r.eq(F.zero())) return 0;
    if (r.eq(F.one())) return 1;
    return -1;
}

/// True if `a` is a quadratic residue (including 0).
pub fn isQuadraticResidue(comptime F: type, a: F) bool {
    return legendre(F, a) != -1;
}

/// Square root of `a`, if it exists. Uses the `p == 3 mod 4` shortcut when
/// the two-adicity is 1, otherwise the full Tonelli–Shanks algorithm.
///
/// Constant-time: the number of iterations is fixed (`two_adicity`), and all
/// data-dependent choices are made with constant-time selects. The result is
/// `null` iff `a` is not a quadratic residue.
pub fn sqrt(comptime F: type, a: F) ?F {
    const s = F.two_adicity;

    if (s == 1) {
        // p == 3 (mod 4): root = a^((p+1)/4). If a is a non-residue this is
        // sqrt(p - a) instead; detect with a constant-time square check.
        const exp = @as(@TypeOf(F.odd_part), @intCast((F.MODULUS + 1) / 4));
        const r = a.pow(exp);
        const is_square = r.mul(r).eq(a);
        return if (is_square) r else null;
    }

    // Tonelli–Shanks: find a quadratic non-residue by exhaustive search.
    // The search only depends on the field, not on the secret `a`.
    var z = F.fromInt(2);
    while (legendre(F, z) != -1) z = z.add(F.one());

    const q = F.odd_part;
    const q_plus_1_over_2 = (q + 1) / 2;

    var c = z.pow(q);
    var x = a.pow(q_plus_1_over_2);
    var t = a.pow(q);
    var m = s;

    var ok = a.isZero(); // 0 is a square (root = 0).
    var iter: usize = 0;
    while (iter < s) : (iter += 1) {
        // Find the smallest i in [1, m) with t^(2^i) == 1, scanning a fixed
        // `s` steps. `i_found == 0` means no such i was seen yet.
        var i_found: usize = 0;
        var t2 = t;
        var inner: usize = 1;
        while (inner <= s) : (inner += 1) {
            t2 = t2.mul(t2);
            const take = (inner < m) and t2.isOne() and (i_found == 0);
            // i_found = take ? inner : i_found (no secret branch)
            const i_new = @as(usize, @intFromBool(take)) *% inner +
                (@as(usize, @intFromBool(!take)) *% i_found);
            i_found = i_new;
        }

        // b = c^(2^e) with e = m - i_found - 1, computed by a fixed-length
        // squaring chain with constant-time selection (no secret shifts).
        const e = if (i_found != 0) m - i_found - 1 else 0;
        var acc = c; // acc = c^(2^k), k starts at 0
        var b = c; // selected result, starts as c^(2^0)
        var k: usize = 0;
        while (k < s) : (k += 1) {
            acc = acc.mul(acc); // acc = c^(2^(k+1))
            b = F.ctSelect(e == k + 1, acc, b);
        }

        const c_new = b.mul(b);
        const t_new = t.mul(c_new);
        const x_new = x.mul(b);
        const m_new = i_found;

        // Apply updates only while the algorithm is still active (t != 1) and
        // an i was found; freeze state once converged or on failure.
        const active = (!t.isOne()) and (i_found != 0);
        c = F.ctSelect(active, c_new, c);
        t = F.ctSelect(active, t_new, t);
        x = F.ctSelect(active, x_new, x);
        // m = active ? i_found : m (arithmetic select for usize)
        const m_sel = @as(usize, @intFromBool(active)) *% m_new +
            (@as(usize, @intFromBool(!active)) *% m);
        m = m_sel;

        // ok = ok or t == 1
        ok = ok or t.isOne();
    }

    return if (ok) x else null;
}

/// Square-and-multiply with the exponent given as little-endian `u64` limbs.
/// Used by the extension fields, whose group orders exceed 512 bits.
pub fn powByLimbs(comptime F: type, self: F, exp: []const u64) F {
    var result = F.one();
    var base = self;
    var limb_idx = exp.len;
    while (limb_idx > 0) {
        limb_idx -= 1;
        var bit: u6 = 0;
        while (bit < 64) : (bit += 1) {
            if ((exp[limb_idx] >> bit) & 1 == 1) result = result.mul(base);
            if (bit < 63) base = base.mul(base);
        }
        base = base.mul(base);
    }
    return result;
}

/// A primitive `2^log_size`-th root of unity, `0 <= log_size <= two_adicity`.
///
/// Let `z` be a quadratic non-residue. Then `z^((p-1)/2^t)` has exact order
/// `2^t` because raising it to `2^(t-1)` yields `z^((p-1)/2) == -1`.
/// No factorization of `p - 1` is required.
pub fn primitiveRootOfUnity(comptime F: type, log_size: usize) F {
    std.debug.assert(log_size <= F.two_adicity);

    var z = F.fromInt(2);
    while (legendre(F, z) != -1) z = z.add(F.one());

    const shift = F.two_adicity - log_size;
    const exponent = (F.odd_part << @intCast(shift));
    return z.pow(exponent);
}

/// An `order`-th root of unity, where `order` must be a power of two.
pub fn rootOfUnity(comptime F: type, order: usize) F {
    std.debug.assert(order & (order - 1) == 0);
    const log = std.math.log2(order);
    return primitiveRootOfUnity(F, log);
}

test "roots against reference semantics" {
    // M31: p = 2^31 - 1, two-adicity 1. The 2nd root is -1.
    const F = @import("field.zig").Field(2147483647);
    const w = primitiveRootOfUnity(F, 1);
    try std.testing.expect(w.mul(w).eq(F.one()));
    try std.testing.expect(w.eq(F.fromInt(2147483646))); // -1

    // sqrt: squares of random values have sqrt; non-residues don't.
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const a = F.fromInt(rnd.int(u32) % F.MODULUS);
        if (a.isZero()) continue;
        const sq = a.mul(a);
        const root = sqrt(F, sq) orelse return error.TestUnexpectedResult;
        try std.testing.expect(root.mul(root).eq(sq));
        try std.testing.expectEqual(legendre(F, sq), @as(i8, 1));
    }
}
