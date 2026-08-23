// SPDX-License-Identifier: MIT OR Apache-2.0

//! BN254 elliptic curve (also known as alt_bn128 or bn256).
//!
//! Used in Ethereum precompiles and many zkSNARK systems.
//! - G1: y^2 = x^3 + 3 over BN254_Fp
//! - G2: y^2 = x^3 + 3/v over BN254_Fp2, where v is the quadratic non-residue

const std = @import("std");
const zf = @import("zig-field");
const weierstrass = @import("weierstrass.zig");

pub const Fp = zf.BN254_Fp;
pub const Fp2 = zf.BN254_Fp2;

/// BN254 G1 curve constant a = 0.
pub const G1_a = Fp.zero();
/// BN254 G1 curve constant b = 3.
pub const G1_b = Fp.fromInt(3);

/// G1 generator point.
pub const G1_generator = weierstrass.AffinePoint(Fp, G1_a, G1_b).generator(
    Fp.fromInt(1),
    Fp.fromInt(2),
);

/// G1 point type.
pub const G1 = weierstrass.AffinePoint(Fp, G1_a, G1_b);

/// G1 projective point type.
pub const G1Projective = weierstrass.ProjectivePoint(Fp, G1_a, G1_b);

/// G2 curve constant a = 0 over Fp2.
pub const G2_a = Fp2.zero();
/// G2 curve constant b = 3/(9+u) over Fp2 (standard alt_bn128 parameter),
/// computed at comptime as (27/82) - (3/82)·u.
pub const G2_b = blk: {
    @setEvalBranchQuota(100_000_000);
    const inv82 = Fp.fromInt(82).inv();
    break :blk Fp2.new(
        Fp.fromInt(27).mul(inv82),
        Fp.fromInt(3).neg().mul(inv82),
    );
};

/// G2 generator point (canonical generator from EIP-197 / py_ecc).
pub const G2_generator = weierstrass.AffinePoint(Fp2, G2_a, G2_b).generator(
    // x-coordinate
    Fp2.new(
        Fp.fromInt(10857046999023057135944570762232829481370756359578518086990519993285655852781),
        Fp.fromInt(11559732032986387107991004021392285783925812861821192530917403151452391805634),
    ),
    // y-coordinate
    Fp2.new(
        Fp.fromInt(8495653923123431417604973247489272438418190587263600148770280649306958101930),
        Fp.fromInt(4082367875863433681332203403145435568316851327593401208105741076214120093531),
    ),
);

/// G2 point type.
pub const G2 = weierstrass.AffinePoint(Fp2, G2_a, G2_b);

/// G2 projective point type.
pub const G2Projective = weierstrass.ProjectivePoint(Fp2, G2_a, G2_b);

/// Scalar field of BN254.
pub const Fr = zf.Field(0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001);

test "G1 generator on curve" {
    std.debug.assert(G1_generator.isOnCurve());
}

test "G1 identity" {
    const id = G1.zero();
    std.debug.assert(id.add(G1_generator).eql(G1_generator));
}

test "G1 scalar mul by 2" {
    const p = G1_generator.scalarMul(@as(u64, 2));
    const p2 = G1_generator.add(G1_generator);
    std.debug.assert(p.eql(p2));
}

test "G1 scalar mul by 0" {
    const p = G1_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(G1.zero()));
}

test "G1 neg" {
    const neg = G1_generator.neg();
    const sum = G1_generator.add(neg);
    std.debug.assert(sum.eql(G1.zero()));
}

test "G2 generator on curve" {
    std.debug.assert(G2_generator.isOnCurve());
}

test "G2 scalar mul by 2" {
    const p = G2_generator.scalarMul(@as(u64, 2));
    const p2 = G2_generator.add(G2_generator);
    std.debug.assert(p.eql(p2));
}
