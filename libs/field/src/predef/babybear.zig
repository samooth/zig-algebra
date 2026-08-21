// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");

/// BabyBear = 2^31 - 2^27 + 1, a popular STARK prime.
pub const BabyBear = field.Field(0x78000001);
