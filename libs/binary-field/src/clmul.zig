const std = @import("std");
const builtin = @import("builtin");

/// Carry-less (polynomial) multiplication over GF(2), the building block for
/// fast binary-field multiplication.
///
/// `clmul64(a, b)` returns the 128-bit polynomial product of two 64-bit
/// operands; `clmul128(a, b)` the 256-bit product of two 128-bit operands.
/// When the CPU has the PCLMULQDQ instruction (x86_64 with the `pclmul`
/// feature) the product is a single instruction; otherwise a portable
/// bit-sliced software fallback is used.
pub const has_hardware_clmul = builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .pclmul);

fn clmul64Hard(a: u64, b: u64) u128 {
    var out: @Vector(2, u64) = @bitCast(@as(u128, a));
    const src: @Vector(2, u64) = @bitCast(@as(u128, b));
    asm (
        \\ pclmulqdq $0x00, %[b], %[out]
        : [out] "+x" (out),
        : [b] "x" (src),
    );
    return @as(u128, @bitCast(out));
}

/// Software 64x64 -> 128 carry-less multiply (bit-sliced, after the std
/// `ghash_polyval` trick): split the operands into four 1-bit-spaced groups
/// and combine the small integer products so no bit carries across groups.
fn clmul64Soft(a: u64, b: u64) u128 {
    const x: u128 = a;
    const y: u128 = b;
    const x0 = x & 0x1111111111111110;
    const x1 = x & 0x2222222222222220;
    const x2 = x & 0x4444444444444440;
    const x3 = x & 0x8888888888888880;
    const y0 = y & 0x1111111111111111;
    const y1 = y & 0x2222222222222222;
    const y2 = y & 0x4444444444444444;
    const y3 = y & 0x8888888888888888;
    const z0 = (x0 * y0) ^ (x1 * y3) ^ (x2 * y2) ^ (x3 * y1);
    const z1 = (x0 * y1) ^ (x1 * y0) ^ (x2 * y3) ^ (x3 * y2);
    const z2 = (x0 * y2) ^ (x1 * y1) ^ (x2 * y0) ^ (x3 * y3);
    const z3 = (x0 * y3) ^ (x1 * y2) ^ (x2 * y1) ^ (x3 * y0);

    const x0_mask = @as(u64, 0) -% (x & 1);
    const x1_mask = @as(u64, 0) -% ((x >> 1) & 1);
    const x2_mask = @as(u64, 0) -% ((x >> 2) & 1);
    const x3_mask = @as(u64, 0) -% ((x >> 3) & 1);
    const extra = (x0_mask & y) ^ (@as(u128, x1_mask & y) << 1) ^
        (@as(u128, x2_mask & y) << 2) ^ (@as(u128, x3_mask & y) << 3);

    return (z0 & 0x11111111111111111111111111111111) ^
        (z1 & 0x22222222222222222222222222222222) ^
        (z2 & 0x44444444444444444444444444444444) ^
        (z3 & 0x88888888888888888888888888888888) ^ extra;
}

const clmul64Impl = if (has_hardware_clmul) clmul64Hard else clmul64Soft;

pub fn clmul64(a: u64, b: u64) u128 {
    return clmul64Impl(a, b);
}

/// Like `clmul64` but uses the software implementation while evaluating at
/// comptime (the PCLMULQDQ instruction cannot run in the compiler), so the
/// tower's comptime-generated fast-multiply tables can reuse the same path.
pub fn clmul64Auto(a: u64, b: u64) u128 {
    if (@inComptime()) return clmul64Soft(a, b);
    return clmul64Impl(a, b);
}

/// 256-bit polynomial product of two 128-bit operands (degree < 256),
/// assembled from four 64-bit carry-less multiplications.
pub const Product = struct {
    lo: u128,
    hi: u128,
};

pub fn clmul128(a: u128, b: u128) Product {
    const alo: u64 = @truncate(a);
    const ahi: u64 = @truncate(a >> 64);
    const blo: u64 = @truncate(b);
    const bhi: u64 = @truncate(b >> 64);
    const ll = clmul64(alo, blo);
    const lh = clmul64(alo, bhi);
    const hl = clmul64(ahi, blo);
    const hh = clmul64(ahi, bhi);
    // (a0 + a1·x^64)(b0 + b1·x^64) = ll + (lh+hl)·x^64 + hh·x^128
    const mid = lh ^ hl;
    return .{ .lo = ll ^ (mid << 64), .hi = hh ^ (mid >> 64) };
}

/// Comptime-safe variant of `clmul128` (see `clmul64Auto`).
pub fn clmul128Auto(a: u128, b: u128) Product {
    if (@inComptime()) {
        const alo: u64 = @truncate(a);
        const ahi: u64 = @truncate(a >> 64);
        const blo: u64 = @truncate(b);
        const bhi: u64 = @truncate(b >> 64);
        const ll = clmul64Soft(alo, blo);
        const lh = clmul64Soft(alo, bhi);
        const hl = clmul64Soft(ahi, blo);
        const hh = clmul64Soft(ahi, bhi);
        const mid = lh ^ hl;
        return .{ .lo = ll ^ (mid << 64), .hi = hh ^ (mid >> 64) };
    }
    return clmul128(a, b);
}

const testing = std.testing;

test "clmul64 software matches the reference for all byte pairs" {
    const ref = clmul64Soft;
    for (0..256) |i| {
        for (0..256) |j| {
            try testing.expectEqual(ref(i, j), clmul64(i, j));
        }
    }
}

test "clmul64 matches the shift-and-xor reference" {
    const ref = struct {
        fn mul(a: u64, b: u64) u128 {
            var r: u128 = 0;
            const x: u128 = a;
            var i: u8 = 0;
            while (i < 64) : (i += 1) {
                if ((b >> @intCast(i)) & 1 == 1) r ^= x << @intCast(i);
            }
            return r;
        }
    }.mul;
    var s: u64 = 42;
    for (0..200) |_| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        const a: u64 = @truncate(s);
        s = s *% 6364136223846793005 +% 1442695040888963407;
        const b: u64 = @truncate(s);
        try testing.expectEqual(ref(a, b), clmul64(a, b));
    }
}

test "clmul128 matches the shift-and-xor reference" {
    const ref = struct {
        fn mul(a: u128, b: u128) clmul128Product {
            var r: clmul128Product = .{ .lo = 0, .hi = 0 };
            var i: u8 = 0;
            while (i < 128) : (i += 1) {
                if ((b >> @intCast(i)) & 1 == 1) {
                    r.lo ^= a << @intCast(i);
                    if (i > 0) r.hi ^= a >> @intCast(127 - (i - 1));
                }
            }
            return r;
        }
        const clmul128Product = @import("clmul.zig").Product;
    }.mul;
    var s: u64 = 7;
    for (0..200) |_| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        var a: u128 = s;
        s = s *% 6364136223846793005 +% 1442695040888963407;
        a |= @as(u128, s) << 64;
        s = s *% 6364136223846793005 +% 1442695040888963407;
        var b: u128 = s;
        s = s *% 6364136223846793005 +% 1442695040888963407;
        b |= @as(u128, s) << 64;
        const got = clmul128(a, b);
        const want = ref(a, b);
        try testing.expectEqual(want.lo, got.lo);
        try testing.expectEqual(want.hi, got.hi);
    }
}
