// SPDX-License-Identifier: MIT OR Apache-2.0

//! zig-curve: elliptic curve implementations for Zig.
//!
//! This library provides:
//! - Re-exports of stdlib curves (Curve25519, Ed25519, Secp256k1, P256, P384)
//! - Custom implementations for pairing-friendly and SNARK curves
//!   - BN254 (G1, G2) - used in Ethereum zkSNARKs
//! - BLS12-381 (G1, G2) - used in BLS signatures, Ethereum 2.0
//! - Pasta (Pallas, Vesta) - recursive SNARKs (Halo2)

const std = @import("std");

// ============================================================================
// Re-export stdlib curves
// ============================================================================

pub const curve25519 = std.crypto.ecc.Curve25519;
pub const edwards25519 = std.crypto.ecc.Edwards25519;
pub const ristretto255 = std.crypto.ecc.Ristretto255;
pub const secp256k1 = std.crypto.ecc.Secp256k1;
pub const p256 = std.crypto.ecc.P256;
pub const p384 = std.crypto.ecc.P384;

// Re-export Ed25519 signatures
pub const ed25519 = std.crypto.sign.Ed25519;

// ============================================================================
// Custom curve implementations
// ============================================================================

pub const bn254 = @import("bn254.zig");
pub const bls12_381 = @import("bls12_381.zig");
pub const pasta = @import("pasta.zig");

// ============================================================================
// Generic Weierstrass curve (for custom implementations)
// ============================================================================

pub const weierstrass = @import("weierstrass.zig");
pub const msm = @import("msm.zig");

// ============================================================================
// Hash-to-curve (RFC 9380)
// ============================================================================

pub const hash_to_curve = @import("hash_to_curve.zig");

// ============================================================================
// Generic group operations
// ============================================================================

pub const group_ops = @import("group_ops.zig");

// ============================================================================
// Byte-scalar arithmetic
// ============================================================================

pub const byte_scalar = @import("byte_scalar.zig");

// ============================================================================
// Generator derivation
// ============================================================================

pub const hash_to_curve_derive = @import("hash_to_curve_derive.zig");

// ============================================================================
// Group-element polynomial evaluation
// ============================================================================

pub const group_poly = @import("group_poly.zig");

// ============================================================================
// Tests
// ============================================================================

test {
    // Reference every public declaration so the `@import`s below are forced
    // and `test` blocks declared inside imported modules (bn254.zig,
    // bls12_381.zig, pasta.zig, ...) are collected by the test runner.
    std.testing.refAllDecls(@This());
}
