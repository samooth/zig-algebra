// SPDX-License-Identifier: MIT OR Apache-2.0

//! Pasta curves: Pallas and Vesta.
//!
//! These form a 2-cycle of elliptic curves used in recursive SNARKs (Halo2):
//! - Pallas: base field Fp, scalar field Fq = Vesta base
//! - Vesta: base field Fq, scalar field Fp = Pallas base
//!
//! Both curves use the short Weierstrass form: y^2 = x^3 + 5

const std = @import("std");
const zf = @import("zig-field");
const weierstrass = @import("weierstrass.zig");

pub const PallasFp = zf.Pallas_Fp;
pub const VestaFp = zf.Vesta_Fp;

// ============================================================================
// Pallas curve (base field Fp, scalar field Fq)
// ============================================================================

/// Pallas curve constant a = 0.
pub const Pallas_a = PallasFp.zero();
/// Pallas curve constant b = 5.
pub const Pallas_b = PallasFp.fromInt(5);

/// Pallas generator point.
/// x = 1, y = sqrt(6) mod p
pub const Pallas_generator = weierstrass.AffinePoint(PallasFp, Pallas_a, Pallas_b).generator(
    PallasFp.fromInt(1),
    PallasFp.fromInt(0x248B4A5CF5ED6C83AC20560F9C8711AB92E13D27D60FB1AA7F5DB6C93512D546),
);

/// Pallas point type.
pub const Pallas = weierstrass.AffinePoint(PallasFp, Pallas_a, Pallas_b);

/// Pallas projective point type.
pub const PallasProjective = weierstrass.ProjectivePoint(PallasFp, Pallas_a, Pallas_b);

/// Pallas scalar field = Vesta base field.
pub const PallasScalar = VestaFp;

// ============================================================================
// Vesta curve (base field Fq, scalar field Fp)
// ============================================================================

/// Vesta curve constant a = 0.
pub const Vesta_a = VestaFp.zero();
/// Vesta curve constant b = 5.
pub const Vesta_b = VestaFp.fromInt(5);

/// Vesta generator point.
/// x = 1, y = sqrt(6) mod q
pub const Vesta_generator = weierstrass.AffinePoint(VestaFp, Vesta_a, Vesta_b).generator(
    VestaFp.fromInt(1),
    VestaFp.fromInt(0x1943666EA922AE6B13B64E3AAE89754CACCE3A7F298BA20C4E4389B9B0276A62),
);

/// Vesta point type.
pub const Vesta = weierstrass.AffinePoint(VestaFp, Vesta_a, Vesta_b);

/// Vesta projective point type.
pub const VestaProjective = weierstrass.ProjectivePoint(VestaFp, Vesta_a, Vesta_b);

/// Vesta scalar field = Pallas base field.
pub const VestaScalar = PallasFp;

test "Pallas generator on curve" {
    std.debug.assert(Pallas_generator.isOnCurve());
}

test "Pallas identity" {
    const id = Pallas.zero();
    std.debug.assert(id.add(Pallas_generator).eql(Pallas_generator));
}

test "Pallas scalar mul by 2" {
    const p = Pallas_generator.scalarMul(@as(u64, 2));
    const p2 = Pallas_generator.add(Pallas_generator);
    std.debug.assert(p.eql(p2));
}

test "Pallas scalar mul by 0" {
    const p = Pallas_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(Pallas.zero()));
}

test "Pallas neg" {
    const neg = Pallas_generator.neg();
    const sum = Pallas_generator.add(neg);
    std.debug.assert(sum.eql(Pallas.zero()));
}

test "Vesta generator on curve" {
    std.debug.assert(Vesta_generator.isOnCurve());
}

test "Vesta identity" {
    const id = Vesta.zero();
    std.debug.assert(id.add(Vesta_generator).eql(Vesta_generator));
}

test "Vesta scalar mul by 2" {
    const p = Vesta_generator.scalarMul(@as(u64, 2));
    const p2 = Vesta_generator.add(Vesta_generator);
    std.debug.assert(p.eql(p2));
}

test "Vesta scalar mul by 0" {
    const p = Vesta_generator.scalarMul(@as(u64, 0));
    std.debug.assert(p.eql(Vesta.zero()));
}

test "Vesta neg" {
    const neg = Vesta_generator.neg();
    const sum = Vesta_generator.add(neg);
    std.debug.assert(sum.eql(Vesta.zero()));
}

test "2-cycle property: PallasScalar = Vesta base" {
    std.debug.assert(PallasScalar.MODULUS == VestaFp.MODULUS);
}

test "2-cycle property: VestaScalar = Pallas base" {
    std.debug.assert(VestaScalar.MODULUS == PallasFp.MODULUS);
}
