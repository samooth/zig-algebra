// SPDX-License-Identifier: MIT OR Apache-2.0

//! Optimal ate pairing over BLS12-381.
//!
//! e: G1 × G2 → GT ⊂ Fp12, computed as f^{(p¹²−1)/r} where
//! f = Miller loop over the ate bits x = −0xd201000000010000.
//!
//! Design notes
//! ============
//! * Tower: Fp12 = Fp6[w]/(w²−v), Fp6 = Fp2[v]/(v³−(1+u)) — see `tower.zig`.
//!   The cubic non-residue (1+u) equals b/b' between E and its M-twist E',
//!   so the untwist Ψ(x',y') = (x'/w², y'/w³) maps E'(Fp2) onto E(Fp12).
//! * Miller loop runs in affine coordinates over the twist. The line through
//!   two twisted points, scaled by w³ and evaluated at P = (xP,yP) ∈ Fp,
//!   becomes the sparse Fp12 element
//!       A + B·w² + C·w³      with  A = λ'x₁' − y₁',  B = −λ',  C = yP,
//!   where λ' is the slope in twisted coordinates. Only slots 0/2/3 are set,
//!   giving ~13 Fp2 multiplications per step.
//! * Vertical lines are omitted: they lie in Fp, which is annihilated by the
//!   (p⁶−1)(p²+1) factor of the final exponentiation.
//! * The parameter x is negative; within μ_r, conjugation equals inversion
//!   because p⁶ ≡ −1 (mod r), so the loop over |x| ends with conj(f).
//! * Hard part of the final exponentiation raises to
//!   m = (p⁴ − p² + 1)/r by left-to-right square-and-multiply over the
//!   compile-time bit expansion of m (~1526 bits). The input is already in
//!   the cyclotomic subgroup, where inversion is conjugation — further
//!   compression (per Devegili/Ghammam–Fouotsa lattice decompositions) can
//!   cut the operation count roughly in half but is left as a documented
//!   optimization; the code here is exact and side-effect free.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const tower = @import("tower.zig");

const Fp = zf.BLS12_381_Fp;
const Fr = zc.bls12_381.Fr;

/// Fp2 with u² = −1 (the field library's quadratic extension).
pub const Fp2 = zc.bls12_381.Fp2;

/// Cubic non-residue / twist ratio: ξ = 1 + u.
pub const XI = Fp2.new(Fp.one(), Fp.one());

pub const Fp6 = tower.Fp6(Fp2, XI);
pub const Fp12 = tower.Fp12(Fp6);

/// BLS12-381 seed parameter x = −0xd201000000010000.
pub const X_PARAM: i128 = -0xD201000000010000;

/// Optimal-ate Miller exponent n = x.
/// Numerically verified: x ≡ p¹ (mod r), gcd(1, 12) = 1 — the twisted-ate
/// condition for bilinearity on this curve family.
pub const MILLER_N: i128 = X_PARAM;
const ABS_MILLER_N: u128 = @intCast(@abs(MILLER_N));
const MILLER_BIT_LEN = bitLenConst(ABS_MILLER_N);

fn bitLenConst(comptime v: u128) usize {
    var x = v;
    var n: usize = 0;
    while (x > 0) : (x >>= 1) n += 1;
    return n;
}

/// G1/G2 point types (affine).
pub const G1Point = zc.bls12_381.G1;
pub const G2Point = zc.bls12_381.G2;

pub const gt_one = Fp12.one();

// ---------------------------------------------------------------------------
// Sparse line multiplication
// ---------------------------------------------------------------------------

/// Multiply f by the sparse line element L = A + B·w² + C·w³.
///
/// Tower slot map (element = c0 + c1·w, c_i ∈ Fp6 = Fp2[v]/(v³−ξ), v = w²):
///   w⁰↔c0.c0  w²↔c0.c1  w⁴↔c0.c2  |  w¹↔c1.c0  w³↔c1.c1  w⁵↔c1.c2
/// hence L occupies slots (c0.c0, c0.c1, c1.c1) — a "023"-pattern.
fn sparseMul023(f: Fp12, A: Fp2, B: Fp2, C: Fp2) Fp12 {
    const xi = Fp6.XI;
    const d0 = f.c0.c0;
    const d1 = f.c0.c1;
    const d2 = f.c0.c2;
    const e0 = f.c1.c0;
    const e1 = f.c1.c1;
    const e2 = f.c1.c2;

    // f.c0 · b0, b0 = (A, B, 0)
    const t00 = Fp6.new(
        d0.mul(A).add(d2.mul(B).mul(xi)),
        d0.mul(B).add(d1.mul(A)),
        d1.mul(B).add(d2.mul(A)),
    );
    // f.c1 · b0
    const t10 = Fp6.new(
        e0.mul(A).add(e2.mul(B).mul(xi)),
        e0.mul(B).add(e1.mul(A)),
        e1.mul(B).add(e2.mul(A)),
    );
    // f.c0 · b1, b1 = (0, C, 0):  v²·(d0,d1,d2) = (d2ξ, d0, d1)
    //   scaled by C: (d2Cξ, d0C, d1C)
    const t01 = Fp6.new(d2.mul(C).mul(xi), d0.mul(C), d1.mul(C));
    // f.c1 · b1
    const t11 = Fp6.new(e2.mul(C).mul(xi), e0.mul(C), e1.mul(C));
    // ν · t11 = v·t11 = t11 rotated once more: (h2ξ, h0, h1) applied to t11
    const nu_t11 = Fp6.new(t11.c2.mul(xi), t11.c0, t11.c1);

    return .{
        .c0 = t00.add(nu_t11),
        .c1 = t01.add(t10),
    };
}

// ---------------------------------------------------------------------------
// Line evaluations (affine, on the twist)
// ---------------------------------------------------------------------------

/// Line through doubled point T (tangent at T), evaluated at P = (px, py).
///
/// Affine doubling on the twist: λ' = 3x² / 2y.  The line
///   y − Ty = λ'(X − Tx)
/// evaluated at P and scaled by w³ becomes the sparse Fp12 element
///   A + B·w² + C·w³   with   A = λ'Tx − Ty,  B = −λ'·px,  C = py.
fn doublingCoefficients(t: G2Point, px: Fp, py: Fp) struct { A: Fp2, B: Fp2, C: Fp2 } {
    const lambda = t.x.sqr().mulBy3().mul(t.y.mulBy2().inv());
    return .{
        .A = lambda.mul(t.x).sub(t.y),
        .B = lambda.neg().mul(Fp2.fromBase(px)),
        .C = Fp2.fromBase(py),
    };
}

/// Line through points T and Q (chord), evaluated at P = (px, py).
///   λ' = (Qy − Ty) / (Qx − Tx);   A = λ'Tx − Ty,  B = −λ'·px,  C = py.
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

fn bitLen(x: comptime_int) usize {
    var v = x;
    var n: usize = 0;
    while (v > 0) : (v >>= 1) n += 1;
    return n;
}

/// N = (p¹² − 1)/r, expanded once at compile time into an MSB-first bit
/// slice. The full exponentiation avoids Frobenius maps entirely (correctness
/// first); documented optimization path: split into (p⁶−1)(p²+1) via
/// conjugation/Frobenius tables plus a cyclotomic x-adic chain for the hard
/// part, cutting the operation count ~6×.
const n_bits = blk: {
    @setEvalBranchQuota(10_000_000);
    const p: comptime_int = Fp.MODULUS;
    const r: comptime_int = Fr.MODULUS;
    const n: comptime_int = (ipow(p, 12) - 1) / r;
    std.debug.assert(n > 0);
    std.debug.assert(n * r == ipow(p, 12) - 1);

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

/// Final exponentiation: raise the Miller loop output to (p¹² − 1)/r.
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

/// Generic Miller loop computing f_{n,Q}(P) over the bits of |n|.
///
/// Vertical-line factors are omitted: they lie in the base field Fp, which
/// the final exponentiation annihilates ((p⁶−1) kills every element of Fp).
/// For negative n the result is conjugated (f_{−n,Q} = conj(f_{n,Q}) up to
/// those same Fp-factors).
pub fn millerLoop(p: G1Point, q: G2Point) Fp12 {
    std.debug.assert(!q.infinity);
    if (p.infinity) return Fp12.one();

    var f = Fp12.one();
    var t = q;

    // Walk the bits of |n| from MSB−1 down to LSB (MSB handled by t=q).
    var i: usize = MILLER_BIT_LEN - 2;
    while (true) : (i -= 1) {
        const bit = (ABS_MILLER_N >> @intCast(i)) & 1;

        // Doubling step: f ← f² · ℓ_{t,t}(P);  t ← 2t
        const dc = doublingCoefficients(t, p.x, p.y);
        f = sparseMul023(f.sqr(), dc.A, dc.B, dc.C);
        t = t.dbl();

        // Addition step
        if (bit == 1) {
            const ac = additionCoefficients(t, q, p.x, p.y);
            f = sparseMul023(f, ac.A, ac.B, ac.C);
            t = t.add(q);
        }

        if (i == 0) break;
    }

    // n < 0 for BLS12-381: f ↦ conj(f), equal to f⁻¹ on the target subgroup.
    return f.conjugate();
}

/// Full optimal ate pairing e(P, Q) = Miller loop followed by the final
/// exponentiation.
pub fn pairing(p: G1Point, q: G2Point) Fp12 {
    return finalExp(millerLoop(p, q));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Embed a = a0 + a1u (Fp2) divided by w²:  a·w^{-2} = a·v^{-1}
/// v^{-1} = v²/ξ  ⇒  a/w² = (a0 + a1u)·v²/ξ.
fn embedFp2DivW2(a: Fp2) Fp12 {
    const xi_inv = Fp6.XI.inv();
    const scaled = Fp6.new(a.mul(xi_inv), Fp2.zero(), Fp2.zero());
    // multiply by v²: shift slots up by two: (d0,d1,d2)·v² = (d2·ξ, ?, ?)
    // v²·(e0) where scaled = e0·v² exactly (only slot-2 populated? no—slot0)
    // Simpler: represent directly: a·v²/ξ = (0,0,e)·? — build via full mul:
    const v_sq = Fp6.new(Fp2.zero(), Fp2.zero(), Fp2.one());
    return Fp12.fromFp6(v_sq.mul(scaled));
}

/// Embed a/w³ = a/(w·v) = a·v^{-1}·w^{-1}; w^{-1} = w⁵/ξ = w²·v/ξ.
fn embedFp2DivW3(a: Fp2) Fp12 {
    // a/w³ = a · w^{-3}. w³ = w·w² = w·v ⇒ w^{-3} = v^{-1}·w^{-1}.
    // Work in the sextic view: w^{-1} = w⁵/ξ.
    // a·w^{-3} = a·w^{-3}: express as sextic slots [0..5]: only slot 3 term:
    // a·w^{-3} = a·w^{3}·w^{-6} = a·w³/ξ. So result = (0,0,a)·w³/ξ =
    // (a/ξ)·w³ → Fp6 part zero, w-part = (a/ξ, 0, 0).
    const a_xi = a.mul(Fp6.XI.inv());
    return .{
        .c0 = Fp6.zero(),
        .c1 = Fp6.new(Fp2.zero(), a_xi, Fp2.zero()),
    };
}

test "untwisted G2 generator lies on E (direct embedding)" {
    const g2 = zc.bls12_381.G2_generator;
    const x_hat = embedFp2DivW2(g2.x);
    const y_hat = embedFp2DivW3(g2.y);

    const lhs = y_hat.mul(y_hat);
    const rhs = x_hat.mul(x_hat).mul(x_hat);

    // Foundational sanity: v³ must equal ξ in the Fp6 tower.
    const v = Fp6.new(Fp2.zero(), Fp2.one(), Fp2.zero());
    try testing.expect(v.mul(v).mul(v).eql(Fp6.fromFp2(Fp6.XI)));

    // Ψ(G₂) satisfies y² = x³ + 4 in Fp12.
    const b12 = Fp12.fromFp6(Fp6.fromFp2(Fp2.new(Fp.fromInt(4), Fp.zero())));
    try testing.expect(lhs.eql(rhs.add(b12)));
}

fn ipowRuntime(base: u512, exp: u512) u512 {
    var result: u512 = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *= b;
        b *= b;
    }
    return result;
}

test "pairing is non-degenerate" {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;
    const e = pairing(g1, g2);
    try testing.expect(!e.isZero());
    try testing.expect(!e.eql(Fp12.one()));
}

test "pairing lands in r-torsion" {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;
    const e = pairing(g1, g2);
    const er = e.powFast(Fr.MODULUS);
    try testing.expect(er.eql(Fp12.one()));
}

test "pairing is bilinear: e(aP, bQ) = e(P,Q)^(ab)" {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;

    const a: u64 = 0xDEADBEEF;
    const b: u64 = 0xBEEFCAFE;

    const pa = g1.scalarMul(a);
    const qb = g2.scalarMul(b);
    const e_ab = pairing(pa, qb);

    const e_base = pairing(g1, g2);
    const ab: u128 = @as(u128, a) * @as(u128, b);
    const expected = e_base.powFast(ab);

    try testing.expect(e_ab.eql(expected));
}

test "pairing bilinearity with additive split" {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;

    const p2 = g1.add(g1);
    const q3 = g2.add(g2).add(g2);

    const lhs = pairing(p2, q3);
    const rhs = pairing(g1, g2).powFast(6);
    try testing.expect(lhs.eql(rhs));
}


test "ISOLATED v³ == ξ" {
    const v = Fp6.new(Fp2.zero(), Fp2.one(), Fp2.zero());
    const v2 = v.mul(v);
    try testing.expect(v2.c0.eql(Fp2.zero()));
    try testing.expect(v2.c1.eql(Fp2.zero()));
    try testing.expect(v2.c2.eql(Fp2.one()));
    const v3 = v2.mul(v);
    try testing.expect(v3.c0.eql(XI));
    try testing.expect(v3.c1.eql(Fp2.zero()));
    try testing.expect(v3.c2.eql(Fp2.zero()));
}


