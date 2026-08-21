// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");

/// M31 = 2^31 - 1, a Mersenne prime used in STARK circuits.
pub const M31 = field.Field(0x7FFFFFFF);
