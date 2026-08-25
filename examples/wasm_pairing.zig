//! WASM exports: BN254 optimal ate pairing for JS/TS interop.
//!
//! Build: zig build wasm-pairing  (emits zig-out/bin/zig_algebra_pairing.wasm)
//!
//! Wire format (all little-endian, fixed-size, no allocations):
//!   G1 point : 64 B  = x(32) || y(32)
//!   G2 point : 128 B = x.c0 || x.c1 || y.c0 || y.c1   (each 32 B)
//!   Fp12 out : 384 B = c0.s0 || c0.s1 || c0.s2 || c1.s0 || c1.s1 || c1.s2
//!
//! Return codes: 0 = OK, -1 = invalid G1, -2 = invalid G2.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const tp = @import("zig-pairing").bn254_tower_pairing;

const Fp = zf.BN254_Fp;
const Fp2 = zf.BN254_Fp2;
const G1 = zc.bn254.G1;
const G2 = zc.bn254.G2;
const Fp12 = tp.Fp12T;

const FP_BYTES = 32;
const G1_BYTES = 2 * FP_BYTES;
const G2_BYTES = 4 * FP_BYTES;
const FP12_BYTES = 6 * 2 * FP_BYTES;

fn readFp(buf: [*]const u8) !Fp {
    return Fp.fromBytes(buf[0..FP_BYTES]);
}

fn writeFp(out: [*]u8, v: Fp) void {
    const b = v.toBytes();
    @memcpy(out[0..FP_BYTES], &b);
}

fn readG1(buf: [*]const u8) !G1 {
    const x = try readFp(buf);
    const y = try readFp(buf + FP_BYTES);
    const pt = G1.generator(x, y);
    if (!pt.isOnCurve()) return error.InvalidG1;
    if (x.isZero() and y.isZero()) return error.InvalidG1; // reject infinity wire form
    return pt;
}

fn readG2(buf: [*]const u8) !G2 {
    const xc0 = try readFp(buf);
    const xc1 = try readFp(buf + FP_BYTES);
    const yc0 = try readFp(buf + 2 * FP_BYTES);
    const yc1 = try readFp(buf + 3 * FP_BYTES);
    const C2 = @TypeOf(@as(G2, undefined).x);
    const pt = G2.generator(C2.new(xc0, xc1), C2.new(yc0, yc1));
    if (!pt.isOnCurve()) return error.InvalidG2;
    return pt;
}

fn writeFp2(out: [*]u8, v: Fp2) void {
    writeFp(out, v.c0);
    writeFp(out + FP_BYTES, v.c1);
}

fn writeFp12(out: [*]u8, e: Fp12) void {
    // Layout: c0.s0..s2 then c1.s0..s2, each slot an Fp2 (64 B).
    writeFp2(out + 0 * 2 * FP_BYTES, e.c0.c0);
    writeFp2(out + 1 * 2 * FP_BYTES, e.c0.c1);
    writeFp2(out + 2 * 2 * FP_BYTES, e.c0.c2);
    writeFp2(out + 3 * 2 * FP_BYTES, e.c1.c0);
    writeFp2(out + 4 * 2 * FP_BYTES, e.c1.c1);
    writeFp2(out + 5 * 2 * FP_BYTES, e.c1.c2);
}

var scratch: [4096]u8 align(16) = undefined;

/// Returns a pointer to a 4096-byte scratch region for JS-side buffers.
export fn scratch_ptr() [*]u8 {
    return &scratch;
}

/// API version for JS-side compatibility checks.
export fn pairing_api_version() u32 {
    return 1;
}

/// Validate a serialised G1 point. Returns 1 valid, 0 invalid.
export fn g1_validate(buf: [*]const u8) i32 {
    _ = readG1(buf) catch return 0;
    return 1;
}

/// Validate a serialised G2 point. Returns 1 valid, 0 invalid.
export fn g2_validate(buf: [*]const u8) i32 {
    _ = readG2(buf) catch return 0;
    return 1;
}

fn scalarMulG1(pt: G1, k: u64) G1 {
    var r: ?G1 = null;
    var base = pt;
    var e = k;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) r = if (r) |rr| rr.add(base) else base;
        base = base.dbl();
    }
    return r orelse G1.generator(Fp.zero(), Fp.zero());
}

fn scalarMulG2(pt: G2, k: u64) G2 {
    var r: ?G2 = null;
    var base = pt;
    var e = k;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) r = if (r) |rr| rr.add(base) else base;
        base = base.dbl();
    }
    return r orelse G2.generator(Fp2.zero(), Fp2.zero());
}

/// Bilinear self-check INSIDE the module:
/// verifies e(2*X1, 3*Y1) == e(X2, Y2)^6 for the provided points
/// (callers pass generators). Returns 1 if holds.
export fn pairing_bilinear_check(
    x1: [*]const u8,
    y1: [*]const u8,
    x2: [*]const u8,
    y2: [*]const u8,
) i32 {
    const p_x = readG1(x1) catch return -1;
    const p_y = readG2(y1) catch return -2;
    const p_2x = scalarMulG1(p_x, 2);
    const p_3y = scalarMulG2(p_y, 3);
    const lhs = tp.pairing(p_2x, p_3y);
    const q_x = readG1(x2) catch return -1;
    const q_y = readG2(y2) catch return -2;
    const rhs = tp.pairing(q_x, q_y).powFast(6);
    return if (lhs.eql(rhs)) 1 else 0;
}

/// Compute the BN254 optimal ate pairing e(g1, g2).
///
/// Writes 384 bytes of Fp12 to `out`. Returns 0 on success, -1/-2 on
/// invalid inputs.
export fn pairing_compute(out: [*]u8, g1_in: [*]const u8, g2_in: [*]const u8) i32 {
    const p = readG1(g1_in) catch return -1;
    const q = readG2(g2_in) catch return -2;
    const e = tp.pairing(p, q);
    writeFp12(out, e);
    return 0;
}
