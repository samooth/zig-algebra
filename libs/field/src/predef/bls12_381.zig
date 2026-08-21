// SPDX-License-Identifier: MIT OR Apache-2.0

const field = @import("../field.zig");

/// Base field of the BLS12-381 pairing-friendly curve (381-bit prime).
pub const BLS12_381_Fp = field.Field(0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB);
