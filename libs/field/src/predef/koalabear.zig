// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");

/// KoalaBear = 2^31 - 2^24 + 1, a STARK prime with two-adicity 24.
pub const KoalaBear = field.Field(0x7F000001);
