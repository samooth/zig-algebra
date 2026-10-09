// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");
const extension = @import("../extension.zig");

/// Base field of the BLS12-381 pairing-friendly curve (381-bit prime).
pub const BLS12_381_Fp = field.Field(0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB);

/// BLS12-381's quadratic extension: F_p[u]/(u^2 + 1), i.e. u^2 = -1.
///
/// This was the missing link in a broken re-export chain: `lib.zig` and
/// `predef.zig` both re-exported `BLS12_381_Fp2`, and this file defined only the
/// base field, so `zig-field.BLS12_381_Fp2` referenced a name that did not
/// exist. Nothing referenced it either, which is why the compiler never looked
/// at the line -- a declaration about which nothing can ask a question is a
/// claim nothing can test. `libs/field/tests/field_test.zig` now does ask.
///
/// The non-residue is -1, matching `libs/curve/src/bls12_381.zig:16` so that the
/// two definitions denote the same field rather than two isomorphic ones.
pub const BLS12_381_Fp2 = extension.QuadraticExtension(
    BLS12_381_Fp,
    BLS12_381_Fp.one().neg(),
);
