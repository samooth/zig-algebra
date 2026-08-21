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
/// G2 curve constant b = -3u over Fp2.
pub const G2_b = Fp2.new(
    Fp.zero(),
    Fp.fromInt(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD44), // -3 mod p
);

/// G2 generator point.
pub const G2_generator = weierstrass.AffinePoint(Fp2, G2_a, G2_b).generator(
    // x-coordinate: 1 + u
    Fp2.new(Fp.one(), Fp.one()),
    // y-coordinate: (1+u)^{-1} = (1-u)/2
    Fp2.new(
        Fp.fromInt(0x183227397098D014DC2822DB40C0AC2ECBC0B548B438E5469E10460B6C3E7EA4),
        Fp.fromInt(0x183227397098D014DC2822DB40C0AC2ECBC0B548B438E5469E10460B6C3E7EA3),
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
