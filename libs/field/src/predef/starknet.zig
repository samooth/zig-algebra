// SPDX-License-Identifier: MIT OR Apache-2.0

//! StarkNet / Cairo base field.
//!
//! `p = 2^251 + 17 * 2^192 + 1`
//! `  = 3618502788666131213697322783095070105623107215331596699973092056135872020481`
//!
//! Used by the StarkNet zk-rollup and Cairo VM.

const zf = @import("../lib.zig");

pub const StarkNet_Fp = zf.Field(3618502788666131213697322783095070105623107215331596699973092056135872020481);
