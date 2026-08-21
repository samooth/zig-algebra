// SPDX-License-Identifier: MIT OR Apache-2.0

//! BLS12-381 elliptic curve.
//!
//! Used in BLS signatures (Ethereum 2.0), zkSNARKs, and other protocols.
//! - G1: y^2 = x^3 + 4 over BLS12_381_Fp
//! - G2: y^2 = x^3 + 4/v over BLS12_381_Fp2, where v is the quadratic non-residue

const std = @import("std");
const zf = @import("zig-field");
const weierstrass = @import("weierstrass.zig");

pub const Fp = zf.BLS12_381_Fp;

/// BLS12-381 Fp2 extension field: F_p[u]/(u^2 + 1).
pub const Fp2 = zf.QuadraticExtension(
    Fp,
    Fp.fromInt(0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAA), // -1
);

/// BLS12-381 G1 curve constant a = 0.
pub const G1_a = Fp.zero();
/// BLS12-381 G1 curve constant b = 3.
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
    Fp.fromInt(0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAA8), // -3 mod p
);

/// G2 generator point.
pub const G2_generator = weierstrass.AffinePoint(Fp2, G2_a, G2_b).generator(
    // x-coordinate: 1 + u
    Fp2.new(Fp.one(), Fp.one()),
    // y-coordinate: (1+u)^{-1} = (1-u)/2
    Fp2.new(
        Fp.fromInt(0xD0088F51CBFF34D258DD3DB21A5D66BB23BA5C279C2895FB39869507B587B120F55FFFF58A9FFFFDCFF7FFFFFFFD556),
        Fp.fromInt(0xD0088F51CBFF34D258DD3DB21A5D66BB23BA5C279C2895FB39869507B587B120F55FFFF58A9FFFFDCFF7FFFFFFFD555),
    ),
);

/// G2 point type.
pub const G2 = weierstrass.AffinePoint(Fp2, G2_a, G2_b);

/// G2 projective point type.
pub const G2Projective = weierstrass.ProjectivePoint(Fp2, G2_a, G2_b);

/// Scalar field of BLS12-381.
pub const Fr = zf.Field(0x73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001);

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
