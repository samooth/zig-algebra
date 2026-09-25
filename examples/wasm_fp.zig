//! Minimal WASM export: BLS12-381 field arithmetic for JS/TS interop.
//!
//! Each operation writes the complete canonical `Fp.NUM_BYTES` result to a
//! caller-provided pointer. `fp_inv` returns 1 on success and 0 for zero input.

const std = @import("std");
const zf = @import("zig-field");

const Fp = zf.BLS12_381_Fp;

fn readFp(lo: u64, hi: u64) Fp {
    return Fp.fromInt(@as(u128, hi) << 64 | lo);
}

fn writeFp(out: [*]u8, value: Fp) void {
    const bytes = value.toBytes();
    @memcpy(out[0..Fp.NUM_BYTES], &bytes);
}

export fn fp_add(a_lo: u64, a_hi: u64, b_lo: u64, b_hi: u64, out: [*]u8) void {
    writeFp(out, readFp(a_lo, a_hi).add(readFp(b_lo, b_hi)));
}

export fn fp_mul(a_lo: u64, a_hi: u64, b_lo: u64, b_hi: u64, out: [*]u8) void {
    writeFp(out, readFp(a_lo, a_hi).mul(readFp(b_lo, b_hi)));
}

export fn fp_inv(a_lo: u64, a_hi: u64, out: [*]u8) i32 {
    const value = readFp(a_lo, a_hi);
    if (value.isZero()) return 0;
    writeFp(out, value.inv());
    return 1;
}
