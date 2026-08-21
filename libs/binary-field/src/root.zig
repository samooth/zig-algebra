//! zig-binary-field: Binary (characteristic-2) Galois fields for Zig.
//!
//! Provides:
//! - BinaryField(bits, reduction_constant) — generic GF(2^n) fields
//! - TowerField(level) — Wiedemann tower of binary fields (Gf2, Gf4, Gf16, Gf256...)
//! - CLMUL — hardware-accelerated carry-less multiplication (PCLMULQDQ + software fallback)
//! - Multilinear polynomials over binary fields
//! - Packed MLE evaluation (Binius packing)
//! - Sum-check protocol
//! - FRI-PCS for binary fields
//!
//! Extracted from zig-stark's binius implementation.

const std = @import("std");
const traits = @import("zig-algebra-traits");

pub const clmul = @import("clmul.zig");
pub const field = @import("field.zig");
pub const tower = @import("tower.zig");
pub const polynomial = @import("polynomial.zig");
pub const pack = @import("pack.zig");
pub const sumcheck = @import("sumcheck.zig");

// Re-export common types
pub const BinaryField = field.BinaryField;
pub const Gf16 = field.Gf16;
pub const Gf128 = field.Gf128;

pub const TowerField = tower.TowerField;
pub const Gf2 = tower.Gf2;
pub const Gf4 = tower.Gf4;
pub const Gf256 = tower.Gf256;
pub const Gf65536 = tower.Gf65536;
pub const Gf2_32 = tower.Gf2_32;
pub const Gf2_64 = tower.Gf2_64;
pub const Gf2_128 = tower.Gf2_128;

pub const Multilinear = polynomial.Multilinear;
pub const fromEvals = polynomial.fromEvals;

pub const PackedMle = pack.PackedMle;
pub const novelNorms = pack.novelNorms;
pub const novelEval = pack.novelEval;

pub const Sumcheck = sumcheck.Sumcheck;

test {
    std.testing.refAllDecls(@This());
}