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
pub const pcs = @import("pcs.zig");
/// A small prime field used only by tests, to exercise the Lagrange and folding
/// arithmetic over a field where `sub` is not `add`. See the file header for
/// why the primality check and the independent oracle are both required.
pub const prime_fixture = @import("prime_fixture.zig");
/// A 128-bit prime field used only by tests, so the **secure** Sumcheck entry
/// point is exercised with the generalized arithmetic. See the file header for
/// the Pocklington certificate that proves its modulus prime.
pub const prime128 = @import("prime128.zig");

// Re-export common types
pub const FieldTrait = traits.FieldTrait;
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
pub const MlePcs = pcs.MlePcs;
pub const CommittedMlePcs = pcs.CommittedMlePcs;
/// Toy/test-only variants; small fields are not sound against grinding provers.
pub const SumcheckUnsafe = sumcheck.SumcheckUnsafe;
pub const MlePcsUnsafe = pcs.MlePcsUnsafe;
pub const CommittedMlePcsUnsafe = pcs.CommittedMlePcsUnsafe;

// Every field this library exposes satisfies the workspace's `FieldTrait`.
//
// This is the test that closes the wall. Until `eql` and `inverse` existed as
// names, `FieldTrait(F).assert()` failed for `BinaryField`, `TowerField` and both
// test fixtures -- which meant no generic helper in `algebra-traits` could be
// called with a binary field at all, and this library kept its own copies of
// operations every other field in the workspace shares. `horner_parity.zig` in
// `zig-poly` measured four such copies converging on three.
//
// `refAllDecls` cannot catch this: it only checks that the tests are collected.
// An assert over a trait is a comptime claim, and a comptime claim needs a call
// -- here, an instantiation. If any of these four stops satisfying the contract,
// this file stops compiling, which is louder than a red test and the right
// failure mode for a contract violation.
test "every binary-field type satisfies the workspace's FieldTrait" {
    inline for (.{
        prime_fixture.Prime31,
        prime128.Prime128,
        field.BinaryField(4, 0x3), // Gf16
        field.BinaryField(8, 0x11b), // AES field
        field.BinaryField(128, 0x87), // GCM field
        tower.Gf2,
        tower.Gf4,
        tower.Gf256,
        tower.Gf2_32,
    }) |F| {
        FieldTrait(F).assert();
    }
}

test {
    std.testing.refAllDecls(@This());
}
