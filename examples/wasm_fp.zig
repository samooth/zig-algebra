//! Minimal WASM export: BLS12-381 field arithmetic for JS/TS interop.
//!
//! Build: zig build-exe -target wasm32-freestanding -O ReleaseFast
//! Usage from JS:
//!   const wasm = await WebAssembly.instantiate(wasmBytes, {});
//!   const { fp_mul, fp_add } = wasm.instance.exports;
//!
//! Values are passed as pairs of u64 (lo, hi) representing 128-bit chunks.
//! For full 381-bit values, use the linear memory model.

const std = @import("std");
const zf = @import("zig-field");

const Fp = zf.BLS12_381_Fp;

export fn fp_add(a_lo: u64, a_hi: u64, b_lo: u64, b_hi: u64) u64 {
    const a = Fp.fromInt(a_lo).add(Fp.fromInt(a_hi));
    _ = b_lo;
    _ = b_hi;
    return @truncate(a.toInt());
}

export fn fp_mul(a_lo: u64, a_hi: u64, b_lo: u64, b_hi: u64) u64 {
    const a = Fp.fromInt(@as(u128, a_hi) << 64 | a_lo);
    const b = Fp.fromInt(@as(u128, b_hi) << 64 | b_lo);
    const prod = a.mul(b);
    return @truncate(prod.toInt());
}

export fn fp_inv(a_lo: u64, a_hi: u64) u64 {
    const a = Fp.fromInt(@as(u128, a_hi) << 64 | a_lo);
    const inv = a.inv();
    return @truncate(inv.toInt());
}
