// SPDX-License-Identifier: MIT OR Apache-2.0

//! Optimal ate pairing over BN254 (alt_bn128).
//!
//! e: G1 × G2 → GT ⊂ Fp12, computed as f_{n,Q}(P)^{(p¹²−1)/r}
//! where n = 6x+2 and x = 0x44E992B44A6909F1.
//!
//! Tower: Fp12 = Fp6[w]/(w²−v), Fp6 = Fp2[v]/(v³−(9+u)),
//! so w⁶ = v³ = 9+u = b/b′, matching the D-type twist.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const tower = @import("tower.zig");

const Fp = zf.BN254_Fp;
const Fr = zc.bn254.Fr;
const Fp2 = zc.bn254.Fp2;

/// Tower cubic non-residue / twist ratio: ξ = b'/b = 1/(9+u) = (9−u)/82.
pub const XI = blk: {
    @setEvalBranchQuota(100_000);
    const inv82 = Fp.fromInt(82).inv();
    break :blk Fp2.new(Fp.fromInt(9).mul(inv82), Fp.fromInt(1).neg().mul(inv82));
};

pub const Fp6 = tower.Fp6(Fp2, XI);
pub const Fp12 = tower.Fp12(Fp6);

/// Seed parameter x = 0x44E992B44A6909F1.
pub const X_PARAM: i128 = 0x44E992B44A6909F1;

/// Optimal-ate Miller exponent n = 6x + 2.
pub const MILLER_N: i128 = 6 * X_PARAM + 2;

/// G1/G2 affine points.
pub const G1Point = zc.bn254.G1;
pub const G2Point = zc.bn254.G2;

pub const gt_one = Fp12.one();

// ---------------------------------------------------------------------------
// Sparse line multiplication (same slot-(0,2,3) layout as BLS12-381)
// ---------------------------------------------------------------------------

fn sparseMul023(f: Fp12, A: Fp2, B: Fp2, C: Fp2) Fp12 {
    const xi = Fp6.XI;
    const d0 = f.c0.c0;
    const d1 = f.c0.c1;
    const d2 = f.c0.c2;
    const e0 = f.c1.c0;
    const e1 = f.c1.c1;
    const e2 = f.c1.c2;

    const t00 = Fp6.new(
        d0.mul(A).add(d2.mul(B).mul(xi)),
        d0.mul(B).add(d1.mul(A)),
        d1.mul(B).add(d2.mul(A)),
    );
    const t10 = Fp6.new(
        e0.mul(A).add(e2.mul(B).mul(xi)),
        e0.mul(B).add(e1.mul(A)),
        e1.mul(B).add(e2.mul(A)),
    );
    const t01 = Fp6.new(d2.mul(C).mul(xi), d0.mul(C), d1.mul(C));
    const t11 = Fp6.new(e2.mul(C).mul(xi), e0.mul(C), e1.mul(C));
    const nu_t11 = Fp6.new(t11.c2.mul(xi), t11.c0, t11.c1);

    return .{
        .c0 = t00.add(nu_t11),
        .c1 = t01.add(t10),
    };
}

// ---------------------------------------------------------------------------
// Line evaluations
// ---------------------------------------------------------------------------

fn doublingCoefficients(t: G2Point, px: Fp, py: Fp) struct { A: Fp2, B: Fp2, C: Fp2 } {
    const lambda = t.x.sqr().mulBy3().mul(t.y.mulBy2().inv());
    return .{
        .A = lambda.mul(t.x).sub(t.y),
        .B = lambda.neg().mul(Fp2.fromBase(px)),
        .C = Fp2.fromBase(py),
    };
}

fn additionCoefficients(t: G2Point, q: G2Point, px: Fp, py: Fp) struct { A: Fp2, B: Fp2, C: Fp2 } {
    const lambda = q.y.sub(t.y).mul(q.x.sub(t.x).inv());
    return .{
        .A = lambda.mul(t.x).sub(t.y),
        .B = lambda.neg().mul(Fp2.fromBase(px)),
        .C = Fp2.fromBase(py),
    };
}

// ---------------------------------------------------------------------------
// Final exponentiation
// ---------------------------------------------------------------------------

fn bitLen(x: comptime_int) usize {
    var v = x;
    var n: usize = 0;
    while (v > 0) : (v >>= 1) n += 1;
    return n;
}

fn ipow(base: comptime_int, exp: usize) comptime_int {
    var result: comptime_int = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *= b;
        b *= b;
    }
    return result;
}

/// N = (p¹² − 1)/r as MSB-first bits for SA&M.
const n_bits = blk: {
    @setEvalBranchQuota(10_000_000);
    const p: comptime_int = Fp.MODULUS;
    const r_: comptime_int = Fr.MODULUS;
    const n: comptime_int = (ipow(p, 12) - 1) / r_;
    std.debug.assert(n > 0);
    std.debug.assert(n * r_ == ipow(p, 12) - 1);

    const nbits = bitLen(n);
    var bits: [nbits]bool = undefined;
    var rem: comptime_int = n;
    var i: usize = nbits;
    while (i > 0) : (i -= 1) {
        bits[i - 1] = (rem & 1) == 1;
        rem >>= 1;
    }
    break :blk bits;
};

fn finalExp(f: Fp12) Fp12 {
    var acc = Fp12.one();
    for (n_bits) |bit| {
        acc = acc.sqr();
        if (bit) acc = acc.mul(f);
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Miller loop + pairing
// ---------------------------------------------------------------------------

/// Miller loop over bits of n = 6x+2 (positive for BN254, no conjugation).
pub fn millerLoop(p: G1Point, q: G2Point) Fp12 {
    std.debug.assert(!q.infinity);
    if (p.infinity) return Fp12.one();

    var f = Fp12.one();
    var t = q;

    const abs_n: u128 = @intCast(@abs(MILLER_N));

    // Find MSB position
    var msb: u7 = 0;
    if (abs_n >= (1 << 64)) msb = 63;
    if (abs_n < (1 << 63)) msb = 62;
    if (abs_n >= (1 << 63)) msb = 63;
    while (msb > 0 and (abs_n >> @intCast(msb)) & 1 == 0) : (msb -= 1) {}

    var i: u7 = msb - 1;
    while (true) : (i -= 1) {
        // Doubling step
        const dc = doublingCoefficients(t, p.x, p.y);
        f = sparseMul023(f.sqr(), dc.A, dc.B, dc.C);
        t = t.dbl();

        // Addition step
        if ((abs_n >> @intCast(i)) & 1 == 1) {
            const ac = additionCoefficients(t, q, p.x, p.y);
            f = sparseMul023(f, ac.A, ac.B, ac.C);
            t = t.add(q);
        }

        if (i == 0) break;
    }

    // n = 6x+2 > 0 for BN254: no conjugation needed.
    return f;
}

/// Full optimal ate pairing.
pub fn pairing(p: G1Point, q: G2Point) Fp12 {
    return finalExp(millerLoop(p, q));
}

// ---------------------------------------------------------------------------
// TODO: Pairing tests
// ---------------------------------------------------------------------------
// The BN254 D-type twist requires different tower parameters than BLS12-381.
//
// For BLS12-381 (M-twist): b' = b·ξ, so setting tower ξ = b'/b works directly.
// For BN254 (D-twist): b' = 3/(9+u), so b'/b = 1/(9+u) which IS a cube in Fp2,
// making it unsuitable as an Fp6 cubic non-residue.
//
// Resolution requires either:
//   (a) A twist-scaling approach: use a valid non-cube ξ_tower and absorb
//       the mismatch via constants in the line evaluation, or
//   (b) A direct degree-12 extension: Fp12 = Fp2[w]/(w¹²−ξ₁₂),
//       bypassing the intermediate Fp6 level entirely.
//
// See py_ecc or arkworks bn254 for reference implementations.
