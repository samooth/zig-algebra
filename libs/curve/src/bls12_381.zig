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
/// BLS12-381 G1 curve constant b = 4.
pub const G1_b = Fp.fromInt(4);

/// G1 generator point (canonical generator from the BLS12-381 specification).
pub const G1_generator = weierstrass.AffinePoint(Fp, G1_a, G1_b).generator(
    // x-coordinate
    Fp.fromInt(0x17F1D3A73197D7942695638C4FA9AC0FC3688C4F9774B905A14E3A3F171BAC586C55E83FF97A1AEFB3AF00ADB22C6BB),
    // y-coordinate
    Fp.fromInt(0xB8E402C605224B3B063FBA901FB75A6C76A87DCA86B962D78C38ADCAD28EF4738DCCAC6575E8CC353F80ED4684717AF),
);

/// G1 point type.
pub const G1 = weierstrass.AffinePoint(Fp, G1_a, G1_b);

/// G1 projective point type.
pub const G1Projective = weierstrass.ProjectivePoint(Fp, G1_a, G1_b);

/// G2 curve constant a = 0 over Fp2.
pub const G2_a = Fp2.zero();
/// G2 curve constant b = 4(1+u) over Fp2 (standard BLS12-381 parameter).
pub const G2_b = Fp2.new(Fp.fromInt(4), Fp.fromInt(4));

/// G2 generator point (canonical generator from the BLS12-381 specification).
pub const G2_generator = weierstrass.AffinePoint(Fp2, G2_a, G2_b).generator(
    // x-coordinate
    Fp2.new(
        Fp.fromInt(0x024AA2B2F08F0A91260805272DC51051C6E47AD4FA403B02B4510B647AE3D1770BAC0326A805BBEFD48056C8C121BDB8),
        Fp.fromInt(0x13E02B6052719F607DACD3A088274F65596BD0D09920B61AB5DA61BBDC7F5049334CF11213945D57E5AC7D055D042B7E),
    ),
    // y-coordinate
    Fp2.new(
        Fp.fromInt(0x0CE5D527727D6E118CC9CDC6DA2E351AADFD9BAA8CBDD3A76D429A695160D12C923AC9CC3BACA289E193548608B82801),
        Fp.fromInt(0x0606C4A02EA734CC32ACD2B02BC28B99CB3E287E85A763AF267492AB572E99AB3F370D275CEC1DA1AAA9075FF05F79BE),
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

test "G2 generator on curve" {
    std.debug.assert(G2_generator.isOnCurve());
}

test "G2 scalar mul by 2" {
    const p = G2_generator.scalarMul(@as(u64, 2));
    const p2 = G2_generator.add(G2_generator);
    std.debug.assert(p.eql(p2));
}
