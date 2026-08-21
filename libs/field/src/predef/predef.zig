// SPDX-License-Identifier: MIT OR Apache-2.0

//! Aggregates all predefined prime fields.

pub const m31 = @import("m31.zig");
pub const babybear = @import("babybear.zig");
pub const koalabear = @import("koalabear.zig");
pub const goldilocks = @import("goldilocks.zig");
pub const m61 = @import("m61.zig");
pub const starknet = @import("starknet.zig");
pub const pasta = @import("pasta.zig");
pub const bn254 = @import("bn254.zig");
pub const bls12_381 = @import("bls12_381.zig");

pub const M31 = m31.M31;
pub const BabyBear = babybear.BabyBear;
pub const KoalaBear = koalabear.KoalaBear;
pub const Goldilocks = goldilocks.Goldilocks;
pub const M61 = m61.M61;
pub const StarkNet_Fp = starknet.StarkNet_Fp;
pub const Pallas_Fp = pasta.Pallas_Fp;
pub const Vesta_Fp = pasta.Vesta_Fp;
pub const BN254_Fp = bn254.BN254_Fp;
pub const BLS12_381_Fp = bls12_381.BLS12_381_Fp;
pub const BLS12_381_Fp2 = bls12_381.BLS12_381_Fp2;
