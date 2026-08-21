// SPDX-License-Identifier: MIT OR Apache-2.0

//! Pasta cycle fields for recursive SNARKs (Halo2).
//!
//! The Pasta curves form a 2-cycle of elliptic curves:
//! - Pallas: base field `Fp`, scalar field `Fq` = Vesta base
//! - Vesta:  base field `Fq`, scalar field `Fp` = Pallas base
//!
//! This enables infinite recursion without trusted setup.

const zf = @import("../lib.zig");

/// Pallas base field (255 bits).
/// `p = 0x40000000000000000000000000000000224698fc094cf91b992d30ed00000001`
pub const Pallas_Fp = zf.Field(0x40000000000000000000000000000000224698fc094cf91b992d30ed00000001);

/// Vesta base field (255 bits).
/// `q = 0x40000000000000000000000000000000224698fc0994a8dd8c46eb2100000001`
pub const Vesta_Fp = zf.Field(0x40000000000000000000000000000000224698fc0994a8dd8c46eb2100000001);
