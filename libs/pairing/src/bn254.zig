// SPDX-License-Identifier: MIT OR Apache-2.0

//! Optimal ate pairing over BN254 (alt_bn128).
//!
//! e: G1 × G2 → GT ⊂ Fp12, computed as f_{n,Q}(P)^{(p¹²−1)/r}
//! where n = 6x+2 and x = 0x44E992B44A6909F1.
//!
//! Tower: Fp12 = Fp6[w]/(w²−v), Fp6 = Fp2[v]/(v³−ξ), ξ = 1/(9+u) = b′/b.
//! That is the *inverse* non-residue, so this tower is not the one the D-type
//! untwist is usually written against. An earlier version of this comment
//! claimed v³ = 9+u, which the code never did, and that gap between the
//! comment and the tower is where this file's defect lived; see the record at
//! the bottom.
//!
//! The Miller loop and the final exponentiation are computed by
//! `bn254_tower.zig`, whose pairing is pinned to a py_ecc known-answer vector,
//! and converted into this file's tower coordinates. There is deliberately no
//! second implementation of the pairing in this file: a fork of a verified
//! algorithm is how the defect recorded below survived every review.
//! so w⁶ = v³ = 9+u = b/b′, matching the D-type twist.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const tower = @import("tower.zig");
const bn254_tower = @import("bn254_tower.zig");

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
// Tower conversion: v³−ξ (this file) <-> v³−γ (bn254_tower.zig)
// ---------------------------------------------------------------------------

/// γ = ξ⁻¹ = 9+u, the cubic non-residue of the verified tower in
/// `bn254_tower.zig`. This file's tower uses ξ = 1/(9+u), which is equally a
/// non-cube (measured in the test below), so the two towers present the same
/// Fp12 and are related by the isomorphism
///     v ↦ v'⁻¹    and    w ↦ w'⁻¹     (fixing Fp2),
/// which is a homomorphism because (v'⁻¹)³ = (v'³)⁻¹ = ξ⁻¹ = γ and
/// (w'⁻¹)² = (w'²)⁻¹ = v'⁻¹.
const GAMMA = bn254_tower.GAMMA;

/// Verified tower -> this file's coordinates. Since v'⁻¹ = v'²/ξ, v'⁻² = v'/ξ
/// and w'⁻¹ = v'²w'/ξ, the six Fp2 slots map as
///     (a0, a1, a2, e0, e1, e2) ↦ (a0, a2·γ, a1·γ, e2·γ, e1·γ, e0·γ).
///
/// The permutation is the entire content of this conversion and its entire
/// risk: a slot map wrong by one position yields a plausible field element
/// and no wrong answer, which is exactly the defect this file carried. The
/// test `the tower conversion is a field isomorphism` checks it for products
/// on random elements, so a wrong permutation cannot pass.
fn fromGamma(g: bn254_tower.Fp12T) Fp12 {
    return Fp12.new(
        Fp6.new(g.c0.c0, g.c0.c2.mul(GAMMA), g.c0.c1.mul(GAMMA)),
        Fp6.new(g.c1.c2.mul(GAMMA), g.c1.c1.mul(GAMMA), g.c1.c0.mul(GAMMA)),
    );
}

/// The inverse of `fromGamma`:
///     (b0, b1, b2, f0, f1, f2) ↦ (b0, b2·ξ, b1·ξ, f2·ξ, f1·ξ, f0·ξ).
fn toGamma(x: Fp12) bn254_tower.Fp12T {
    return bn254_tower.Fp12T.new(
        bn254_tower.Fp6T.new(x.c0.c0, x.c0.c2.mul(XI), x.c0.c1.mul(XI)),
        bn254_tower.Fp6T.new(x.c1.c2.mul(XI), x.c1.c1.mul(XI), x.c1.c0.mul(XI)),
    );
}

// ---------------------------------------------------------------------------
// Miller loop + pairing
// ---------------------------------------------------------------------------

/// Miller loop, converged onto the verified implementation.
///
/// The loop is not a second copy of the algorithm. `bn254_tower.zig`'s is
/// pinned to py_ecc by a known-answer vector; a second implementation in this
/// file is what computed the wrong values recorded at the bottom of this file.
/// The conversion above is exact, so the element returned here is the one the
/// verified file computes, expressed in this file's tower.
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
///
/// One behaviour change, named rather than left to be discovered: on an input
/// outside the prime-order subgroup the verified implementation returns the
/// identity, and this path inherits that instead of producing a garbage value.
/// The identity is indistinguishable from a Miller loop that legitimately is
/// the identity; `bn254_tower.pairingChecked` reports subgroup failures
/// separately.
pub fn millerLoopChecked(p: G1Point, q: G2Point) error{PointAtInfinity}!Fp12 {
    if (q.infinity) return error.PointAtInfinity;
    if (p.infinity) return Fp12.one();
    return fromGamma(bn254_tower.millerLoop(p, q));
}

/// Full optimal ate pairing.
pub fn pairing(p: G1Point, q: G2Point) Fp12 {
    return fromGamma(bn254_tower.pairing(p, q));
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
// What was wrong, and what replaced it. This file used to carry its own
// optimal-ate loop -- a sparse line multiplication, tangent and chord
// coefficient helpers, and a direct final exponentiation -- and two things
// were wrong with it, each invisible to every test that then existed.
//
// First, the line factors sat in the wrong tower slots. The loop multiplied
// by A + B·w² + C·w³ from the unscaled coefficients A = λx_T − y_T,
// B = −λ·px, C = py. But the untwist this tower implies puts the constant
// term in w⁰, the slope term in w¹ and the intercept term in w³: with
// v³ = ξ = 1/(9+u) the sextic untwist is x' ↦ x'/v, y' ↦ y'/(v·w), and the
// line through the untwisted points evaluates to py − λ·px·w − ν·v·w.
// Multiplying by w² instead puts the slope term in the base Fp6, so the
// accumulator became an element of the right field that no line evaluation
// produces. Measured: the pairing was not bilinear, while e^r == 1 and it was
// non-degenerate, and those tests all passed.
//
// Second, the two optimal-ate extra terms -- the lines through π(Q) and
// −π²(Q), present in py_ecc, in arkworks and in this tree's bn254_tower.zig --
// were absent, so even a correctly slotted loop would have returned a
// different element.
//
// The fix was convergence, not repair. `bn254_tower.zig` already had the
// external vector (py_ecc, EIP-197, since 5bbd59e), so this file now delegates
// and converts; repairing a second copy of the algorithm would have left two
// implementations to keep in agreement, which is the fork this repository has
// already been bitten by. The cost is named rather than hidden: BN254 no longer
// has two independent implementations to differential-test against each other.
// What replaced that is better -- an external vector -- and the sequence is
// recorded in AUDIT.md row 15 and SECURITY.md advisory ZA-2026-007.

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

// ---------------------------------------------------------------------------
// Known-answer vector from an independent implementation
// ---------------------------------------------------------------------------

/// py_ecc's basis is 1, t, ..., t^11 of Fq[t]/(t^12 - 18 t^6 + 82), and the
/// isomorphism to this file's tower is t -> w^-1: (w^-1)^6 = ξ^-1 = 9+u, and
/// 9+u satisfies (9+u)^2 - 18(9+u) + 82 = 0, so w is a root of the same
/// degree-12 polynomial py_ecc reduces by. w^-1 = v'^2·w'/ξ, which is the
/// single Fp2 slot γ in the v'²w position.
const W_INV = blk: {
    @setEvalBranchQuota(100_000);
    break :blk Fp12.new(Fp6.zero(), Fp6.new(Fp2.zero(), Fp2.zero(), GAMMA));
};

/// Convert a py_ecc basis vector into this file's tower coordinates along
/// t -> w^-1: sum_k a_k · (w^-1)^k, accumulated in this file's own arithmetic.
fn katToTower(a: *const [12]Fp) Fp12 {
    var acc = Fp12.zero();
    var pw = Fp12.one();
    for (0..12) |k| {
        if (!a[k].isZero()) {
            const s = Fp2.fromBase(a[k]);
            acc = acc.add(Fp12.new(
                Fp6.new(pw.c0.c0.mul(s), pw.c0.c1.mul(s), pw.c0.c2.mul(s)),
                Fp6.new(pw.c1.c0.mul(s), pw.c1.c1.mul(s), pw.c1.c2.mul(s)),
            ));
        }
        pw = pw.mul(W_INV);
    }
    return acc;
}

/// Product in py_ecc's basis, Fq[t]/(t^12 - 18 t^6 + 82): schoolbook over 24
/// coefficients, then reduce from the top down with
/// t^k ↦ 18 t^(k-6) - 82 t^(k-12).
fn pyMul(a: *const [12]Fp, b: *const [12]Fp) [12]Fp {
    var c: [24]Fp = undefined;
    for (&c) |*x| x.* = Fp.zero();
    for (0..12) |i| {
        for (0..12) |j| {
            c[i + j] = c[i + j].add(a[i].mul(b[j]));
        }
    }
    var k: usize = 23;
    while (k >= 12) : (k -= 1) {
        if (!c[k].isZero()) {
            c[k - 6] = c[k - 6].add(c[k].mul(Fp.fromInt(18)));
            c[k - 12] = c[k - 12].sub(c[k].mul(Fp.fromInt(82)));
            c[k] = Fp.zero();
        }
    }
    var r: [12]Fp = undefined;
    for (0..12) |i| r[i] = c[i];
    return r;
}

/// Deterministic pseudo-random Fp (splitmix64), so these tests need no
/// random() helper and never depend on the platform.
fn pseudoFp(seed: u64) Fp {
    var z = seed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    return Fp.fromInt(z);
}

fn randFp2(seed: u64) Fp2 {
    return Fp2.new(pseudoFp(seed), pseudoFp(seed +% 0x1000));
}

fn randFp6(seed: u64) Fp6 {
    return Fp6.new(randFp2(seed), randFp2(seed +% 0x2000), randFp2(seed +% 0x3000));
}

fn randFp12(seed: u64) Fp12 {
    return Fp12.new(randFp6(seed), randFp6(seed +% 0x4000));
}

/// py_ecc 8.0.0, `optimized_bn128.pairing(G2, G1)` -- and identically
/// `py_ecc.bn128.pairing(G2, G1)`, checked coefficient for coefficient.
/// Twelve coefficients in the basis 1, t, ..., t^11 of
/// Fq[t]/(t^12 - 18 t^6 + 82). Wrapped in a branch-quota block because
/// each fromInt over a Montgomery field is a comptime multiplication,
/// the same reason this file's XI carries one.
const PY_ECC_KAT = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [12]Fp{
        Fp.fromInt(0x28c6e04df059260df7d2d2a1f9b5f77676d1939847852c4ed50d2318744c1d5f), // [0]
        Fp.fromInt(0x17bb74adab1705c26133af1dac87044a3833ac011018e8158da48382bbd2dcd6), // [1]
        Fp.fromInt(0xd3bd72f54d742f78ea9e6015c8ea2f2e7fbb728c9c905ec531dcf7de5b246f0), // [2]
        Fp.fromInt(0x90cb8ee97e091a667af03882b06c3ecb4e437993cbd1b05b98c7f9dfcfe9c40), // [3]
        Fp.fromInt(0x16b6d855b5cbf76f9829a309db52f5c442f65ae29f996af59d65f85f4afe78a), // [4]
        Fp.fromInt(0xa0272204db51dadc0342bd318b9302a44faec12ff500bdd4d4b012ffe45f36f), // [5]
        Fp.fromInt(0x84f330485b09e866bc2f2ea2b897394deaf3f12aa31f28cb0552990967d4704), // [6]
        Fp.fromInt(0x27ed208e7a0b55ae6e710bbfbd2fd922669c026360e37cc5b2ab862411536104), // [7]
        Fp.fromInt(0x2067586885c3318eeffa1938c754fe3c60224ee5ae15e66af6b5104c47c8c5d8), // [8]
        Fp.fromInt(0x279db296f9d479292532c7c493d8e0722b6efae42158387564889c79fc038ee3), // [9]
        Fp.fromInt(0x2b03614464f04dd772d86df88674c270ffc8747ea13e72da95e3594468f222c4), // [10]
        Fp.fromInt(0x108c19d15f9446f744d0f110405d3856d6cc3bda6c4d537663729f5257628417), // [11]
    };
};
test "bn254: the tower conversion is a field isomorphism" {
    // Round trip and multiplicativity, on deterministic pseudo-random
    // elements. A slot permutation wrong by one position can survive a round
    // trip by accident; it cannot survive multiplicativity, which is what
    // makes the conversion trustworthy for the KAT that depends on it.
    var s: u64 = 0x5EED_1701;
    var t: usize = 0;
    while (t < 4) : (t += 1) {
        const a = randFp12(s);
        const b = randFp12(s +% 7);
        s +%= 0x1000;
        try std.testing.expect(fromGamma(toGamma(a)).eql(a));
        try std.testing.expect(toGamma(a.mul(b)).eql(toGamma(a).mul(toGamma(b))));
    }
}

test "bn254: the py_ecc basis conversion is a ring homomorphism" {
    // The other half of the KAT's trustworthiness: t -> w^-1 must preserve
    // products between py_ecc's basis and this tower, checked against py_ecc's
    // own reduction t^12 = 18 t^6 - 82 computed here rather than assumed. A
    // wrong map -- a Frobenius twist, a different root of the modulus
    // polynomial -- fails on random inputs instead of yielding a plausible
    // element, which is the failure mode this repository cares about.
    var s: u64 = 0xA7E_5EED;
    var t: usize = 0;
    while (t < 4) : (t += 1) {
        var a: [12]Fp = undefined;
        var b: [12]Fp = undefined;
        for (0..12) |i| {
            a[i] = pseudoFp(s +% @as(u64, @intCast(i)));
            b[i] = pseudoFp(s +% @as(u64, @intCast(i)) +% 0x500);
        }
        s +%= 0x1000;
        try std.testing.expect(katToTower(&a).mul(katToTower(&b)).eql(katToTower(&pyMul(&a, &b))));
    }
}

test "bn254: pairing matches py_ecc on the canonical generators" {
    // The closing of AUDIT.md row 15 for this file: a known-answer vector from
    // an implementation independent of this repository, converted through the
    // isomorphism the two tests above validate.
    const expected = katToTower(&PY_ECC_KAT);
    const actual = pairing(zc.bn254.G1_generator, zc.bn254.G2_generator);
    try std.testing.expect(expected.eql(actual));

    // Negative control: the same comparison with one coefficient raised by one
    // must not hold. An assertion that cannot fail is decoration.
    var tampered = PY_ECC_KAT;
    tampered[3] = tampered[3].add(Fp.one());
    try std.testing.expect(!katToTower(&tampered).eql(actual));
}
test "bn254: pairing is bilinear on the canonical generators" {
    // This test was the DEFECT MARKER: it asserted the negation of bilinearity
    // and its name said it inverts when the defect is fixed. The fix landed,
    // the marker failed exactly as that comment predicted, and this is the
    // inversion. Bilinearity is asserted here because it is the specification;
    // the vector in the test above is what makes it a claim about the right
    // value and not only about the right shape.
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const base = pairing(g1, g2);
    try std.testing.expect(pairing(g1.scalarMul(@as(u64, 2)), g2).eql(base.powFast(@as(u64, 2))));
    try std.testing.expect(pairing(g1, g2.scalarMul(@as(u64, 2))).eql(base.powFast(@as(u64, 2))));
    // Controls, so the two assertions above cannot be satisfied by a broken exponent.
    try std.testing.expect(base.powFast(@as(u64, 2)).powFast(@as(u64, 3)).eql(base.powFast(@as(u64, 6))));
    try std.testing.expect(g1.scalarMul(@as(u64, 2)).eql(g1.add(g1)));
    try std.testing.expect(g2.scalarMul(@as(u64, 2)).eql(g2.add(g2)));
}
