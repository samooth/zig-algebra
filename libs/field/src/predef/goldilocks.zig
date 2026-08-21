// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");

/// Goldilocks = 2^64 - 2^32 + 1, the classic SNARK/STARK prime.
pub const Goldilocks = field.Field(0xFFFFFFFF00000001);
