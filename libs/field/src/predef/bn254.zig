// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");

/// Base field of the BN254 pairing-friendly curve.
pub const BN254_Fp = field.Field(0x30644E72E131A029B85045B68181585D97816A916871CA8D3C208C16D87CFD47);
