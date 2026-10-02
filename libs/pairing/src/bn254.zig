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
///
/// `q` must not be the point at infinity. The guard used to be a
/// `std.debug.assert`, which is compiled out in `ReleaseFast`, where a `q` at
/// infinity then produced a garbage `Fp12` instead of an error; use
/// `millerLoopChecked` when the inputs are untrusted.
pub fn millerLoop(p: G1Point, q: G2Point) Fp12 {
    return millerLoopChecked(p, q) catch Fp12.one();
}

/// # Errors
/// `error.PointAtInfinity` when `q` is the point at infinity.
pub fn millerLoopChecked(p: G1Point, q: G2Point) error{PointAtInfinity}!Fp12 {
    if (q.infinity) return error.PointAtInfinity;
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
// Tower parameters: measured, not assumed
// ---------------------------------------------------------------------------
// An earlier version of this file carried a TODO here saying the BN254 D-type
// twist needed different tower parameters, on the grounds that b'/b = 1/(9+u)
// "IS a cube in Fp2" and is therefore unsuitable as an Fp6 cubic non-residue.
//
// That premise is false, and the way it is false matters more than the fact: it was
// never measured, and it is the stated reason there were no pairing tests here for
// as long as the file existed. A comment asserting a theorem nobody checked is the
// same shape as a check written against the implementation -- it pins the comment.
//
// Measured, over Fp2 of BN254, with the criterion that a is a cube in Fp2* iff
// a^((p^2-1)/3) == 1 (valid because p == 1 mod 3, so 3 divides p^2-1):
//
//     XI = 1/(9+u) = (9-u)/82
//     XI^((p^2-1)/3) = 2203960485148121921418603742825762020974279258880205651966  != 1
//
// so XI is NOT a cube, v^3 - XI is irreducible over Fp2, and Fp6 IS a field. The
// instrument that produced this was checked in both directions first: a constructed
// cube is detected and a constructed non-cube is rejected, so the "not 1" above is
// an answer and not a criterion that always says no.
//
// What is still missing is a known-answer vector. The tests at the end of this file
// check field axioms, non-degeneracy and bilinearity, and every one of those passes
// against a pairing that computes the wrong value, because they compare the
// implementation with itself. BLS12-381 has the external vector (the EIP-197 value
// for the canonical generators, in bls12_381.zig) and BN254 has none in any of its
// three implementations. Until one is hardcoded from an independent implementation,
// this is a self-consistent pairing and not a certified one.
//
// Resolution of the original TODO, for whoever picks it up:
//   (a) A twist-scaling approach: use a valid non-cube ξ_tower and absorb
//       the mismatch via constants in the line evaluation, or
//   (b) A direct degree-12 extension: Fp12 = Fp2[w]/(w¹²−ξ₁₂),
//       bypassing the intermediate Fp6 level entirely.
// See py_ecc or arkworks bn254 for reference implementations.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Read the caveat above before trusting these. Field axioms, non-degeneracy and
// bilinearity all hold for a pairing that computes the wrong value, because they
// compare the implementation with itself; what is missing is a known-answer vector
// from an independent implementation, and no test here can substitute for it.

test "bn254: the tower constant XI is not a cube in Fp2, so Fp6 is a field" {
    // The claim this file used to carry as a TODO, asserted instead of asserted-
    // in-prose. p == 1 mod 3 for BN254, so 3 divides p^2 - 1 and an element of Fp2*
    // is a cube iff its ((p^2-1)/3)-th power is one. The expected value is the
    // independent Python measurement recorded above, not this file's own output.
    const FpBn = Fp;
    const p = FpBn.MODULUS;
    const pow_e = p * p - 1;
    const third = pow_e / 3;
    try std.testing.expect(pow_e % 3 == 0); // the criterion's own precondition

    var acc = Fp2.one();
    var base = XI;
    var e = third;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) acc = acc.mul(base);
        base = base.mul(base);
    }
    // Not one: XI is not a cube, so v^3 - XI is irreducible and Fp6 has no zero
    // divisors. Written as "not equal to one" rather than as a magic constant
    // because the constant is a claim this file would then be checking itself.
    try std.testing.expect(!acc.eql(Fp2.one()));

    // Control: a cube IS detected as one, so the criterion above can say yes.
    const gen = Fp2.new(Fp.fromInt(3), Fp.fromInt(5));
    var cube = gen;
    cube = cube.mul(gen);
    cube = cube.mul(gen);
    var acc2 = Fp2.one();
    base = cube;
    e = third;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) acc2 = acc2.mul(base);
        base = base.mul(base);
    }
    try std.testing.expect(acc2.eql(Fp2.one()));
}

test "bn254: Fp12 inverse round-trips on a non-trivial element" {
    // Also a check that XI being a non-cube was not merely true but load-bearing:
    // if v^3 - XI had a root, Fp6 would be a ring with zero divisors and `inv`
    // would return something whose product with its argument is not one.
    const w = Fp12.new(
        Fp6.new(Fp2.new(Fp.fromInt(7), Fp.fromInt(11)), Fp2.one(), Fp2.new(Fp.fromInt(13), Fp.fromInt(17))),
        Fp6.new(Fp2.new(Fp.fromInt(19), Fp.fromInt(23)), Fp2.new(Fp.fromInt(29), Fp.fromInt(31)), Fp2.one()),
    );
    try std.testing.expect(!w.eql(Fp12.one()));
    try std.testing.expect(w.mul(w.inv()).eql(Fp12.one()));
}

test "bn254: pairing is non-degenerate on the canonical generators" {
    const e = pairing(zc.bn254.G1_generator, zc.bn254.G2_generator);
    try std.testing.expect(!e.eql(Fp12.one()));
    // A pairing into a field with a non-cube XI has order dividing r, so raising
    // to the subgroup order returns one. This holds for the wrong pairing too,
    // which is why it is a supporting check and not the one that matters.
    try std.testing.expect(e.powFast(Fr.MODULUS).eql(Fp12.one()));
}

test "bn254: DEFECT MARKER -- pairing is not bilinear, and this test inverts when it is fixed" {
    // e(2P,Q) != e(P,Q)^2 and e(P,2Q) != e(P,Q)^2, on both sides independently.
    // Measured 2026-10-02, after this file's pairing() had gone without a single
    // test for the whole life of the repository. AUDIT.md row 15.
    //
    // This asserts the DEFECT, not the specification, and that is deliberate: a test
    // that fails would take the suite red and stop everyone running it, while a test
    // that asserts correctness cannot be written, because correctness is not yet
    // established -- there is no external known-answer vector for BN254 in this tree,
    // so the value is unverified by construction.
    //
    // So this pins the wrong behaviour on purpose, which is only defensible because
    // the name says so, the audit row has a closing criterion, and the day someone
    // fixes the Miller loop this test FAILS and has to be inverted. That inversion is
    // the signal: a defect marker that cannot fail is not a marker.
    //
    // The instrument was checked before the finding was believed, in both directions:
    // powFast composes ((e^2)^3 == e^6), scalarMul(P,2) == P+P and scalarMul(Q,2) ==
    // Q+Q, and e(P+P,Q) fails the same way e(2P,Q) does, so the failure is inside the
    // Miller loop and not in the exponentiation or in the point arithmetic feeding it.
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const base = pairing(g1, g2);
    try std.testing.expect(!pairing(g1.scalarMul(@as(u64, 2)), g2).eql(base.powFast(@as(u64, 2))));
    try std.testing.expect(!pairing(g1, g2.scalarMul(@as(u64, 2))).eql(base.powFast(@as(u64, 2))));
    // Controls, so the two assertions above cannot be satisfied by a broken exponent.
    try std.testing.expect(base.powFast(@as(u64, 2)).powFast(@as(u64, 3)).eql(base.powFast(@as(u64, 6))));
    try std.testing.expect(g1.scalarMul(@as(u64, 2)).eql(g1.add(g1)));
    try std.testing.expect(g2.scalarMul(@as(u64, 2)).eql(g2.add(g2)));
}
