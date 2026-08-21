// SPDX-License-Identifier: MIT OR Apache-2.0

//! Fixed-width big-integer helpers operating on `[N]u64` limb arrays.
//!
//! No heap allocation, no dynamic length. All functions are `comptime N`
//! parameterized so the compiler can fully unroll the limb loops.
//!
//! Limbs are stored little-endian: `limbs[0]` is the least significant word.
//! This mirrors `zig-stark`'s Montgomery code and the convention used by
//! `std.crypto.ff`.

const std = @import("std");

/// Number of bits in the binary representation of `value`.
/// Equivalent to `floor(log2(value)) + 1`; returns 0 for `value == 0`.
pub fn bitLength(comptime value: comptime_int) usize {
    var v = value;
    var n: usize = 0;
    while (v != 0) : (v >>= 1) n += 1;
    return n;
}

/// Number of 64-bit limbs needed to represent `bits` bits.
pub fn numLimbs(comptime bits: usize) usize {
    return (bits + 63) / 64;
}

/// Serialize a comptime integer into `n` little-endian limbs.
/// Higher limbs beyond `n * 64` bits are silently truncated.
pub fn intToLimbs(comptime n: usize, comptime value: comptime_int) [n]u64 {
    var out = [_]u64{0} ** n;
    var i: usize = 0;
    var v: u512 = @intCast(value);
    while (i < n) : (i += 1) {
        out[i] = @truncate(v);
        v >>= 64;
    }
    return out;
}

/// Serialize a runtime `u512` into `n` little-endian limbs.
pub fn intToLimbsRuntime(comptime n: usize, x: u512) [n]u64 {
    var out = [_]u64{0} ** n;
    var v = x;
    for (0..n) |i| {
        out[i] = @truncate(v);
        v >>= 64;
    }
    return out;
}

/// Combine `n` little-endian limbs into an integer of type `T`.
/// `T` must be wide enough for the full limb array.
pub fn limbsToInt(comptime n: usize, comptime T: type, limbs: *const [n]u64) T {
    comptime std.debug.assert(@bitSizeOf(T) >= 64 * n);
    var out: T = 0;
    for (limbs, 0..) |limb, i| {
        out |= @as(T, limb) << @intCast(64 * i);
    }
    return out;
}

/// Compare two limb arrays as little-endian big integers.
pub fn cmp(comptime n: usize, a: *const [n]u64, b: *const [n]u64) std.math.Order {
    var i = n;
    while (i > 0) {
        i -= 1;
        if (a[i] > b[i]) return .gt;
        if (a[i] < b[i]) return .lt;
    }
    return .eq;
}

/// `out = a + b`, returning the final carry (0 or 1).
pub fn add(comptime n: usize, a: *const [n]u64, b: *const [n]u64, out: *[n]u64) u64 {
    var carry: u64 = 0;
    for (0..n) |i| {
        const z = @as(u128, a[i]) + @as(u128, b[i]) + carry;
        out[i] = @truncate(z);
        carry = @truncate(z >> 64);
    }
    return carry;
}

/// `out = a - b`, returning the final borrow (0 or 1).
pub fn sub(comptime n: usize, a: *const [n]u64, b: *const [n]u64, out: *[n]u64) u64 {
    var borrow: u64 = 0;
    for (0..n) |i| {
        const diff = a[i] -% b[i];
        out[i] = diff - borrow;
        const b1: u64 = if (a[i] < b[i]) 1 else 0;
        const b2: u64 = if (diff < borrow) 1 else 0;
        borrow = b1 + b2;
    }
    return borrow;
}

/// `out = a << bit_shift` (bit shift, not limb shift).
pub fn shl(comptime n: usize, a: *const [n]u64, bit_shift: usize, out: *[n]u64) void {
    const limb_shift = bit_shift / 64;
    const bit = bit_shift % 64;
    if (bit == 0) {
        for (0..n) |i| {
            const src = i + limb_shift;
            out[i] = if (src < n) a[src] else 0;
        }
        return;
    }
    // Left shift: out[i] = (a[i - limb_shift] << bit) | (a[i - limb_shift - 1] >> (64 - bit))
    for (0..n) |i| {
        var lo: u64 = 0;
        if (i >= limb_shift and i - limb_shift < n) {
            lo = a[i - limb_shift] << @intCast(bit);
        }
        var hi: u64 = 0;
        if (i > limb_shift and i - limb_shift - 1 < n) {
            hi = a[i - limb_shift - 1] >> @intCast(64 - bit);
        }
        out[i] = lo | hi;
    }
}

/// `out = a >> bit_shift` (bit shift, not limb shift).
pub fn shr(comptime n: usize, a: *const [n]u64, bit_shift: usize, out: *[n]u64) void {
    const limb_shift = bit_shift / 64;
    const bit = bit_shift % 64;
    if (bit == 0) {
        for (0..n) |i| {
            out[i] = if (i + limb_shift < n) a[i + limb_shift] else 0;
        }
        return;
    }
    for (0..n) |i| {
        const src = i + limb_shift;
        var v: u64 = 0;
        if (src < n) v = a[src] >> @intCast(bit);
        if (bit != 0 and src + 1 < n) v |= a[src + 1] << @intCast(64 - bit);
        out[i] = v;
    }
}

/// Schoolbook multiplication of two `n`-limb numbers into a `2n`-limb product.
/// Each accumulator stays below `2^128` because the carry after a full 64-bit
/// multiply-add is bounded by `2^64 - 1`.
pub fn mul(comptime n: usize, a: *const [n]u64, b: *const [n]u64) [2 * n]u64 {
    var out = [_]u64{0} ** (2 * n);
    for (0..n) |i| {
        var carry: u64 = 0;
        for (0..n) |j| {
            const z = @as(u128, out[i + j]) + @as(u128, a[i]) * @as(u128, b[j]) + carry;
            out[i + j] = @truncate(z);
            carry = @truncate(z >> 64);
        }
        out[i + n] = carry;
    }
    return out;
}

test "bigint cmp / add / sub" {
    const n = 4;
    const a = [n]u64{ 0xffffffffffffffff, 1, 0, 0 };
    const b = [n]u64{ 0, 0, 0, 0 };
    try std.testing.expectEqual(std.math.Order.gt, cmp(n, &a, &b));
    try std.testing.expectEqual(std.math.Order.lt, cmp(n, &b, &a));

    var sum: [n]u64 = undefined;
    const carry = add(n, &a, &b, &sum);
    try std.testing.expectEqual(@as(u64, 0), carry);
    try std.testing.expectEqual(a, sum);

    var diff: [n]u64 = undefined;
    const borrow = sub(n, &a, &b, &diff);
    try std.testing.expectEqual(@as(u64, 0), borrow);
    try std.testing.expectEqual(a, diff);
}

test "bigint shl / shr round-trip" {
    const n = 5;
    const a = [n]u64{ 1, 0, 0, 0, 0 };
    var left: [n]u64 = undefined;
    var right: [n]u64 = undefined;
    shl(n, &a, 130, &left);
    shr(n, &left, 130, &right);
    try std.testing.expectEqual(a, right);
}

test "bigint mul vs u256 reference" {
    const n = 4;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const x: u256 = rnd.int(u256);
        const y: u256 = rnd.int(u256);
        var a: [n]u64 = undefined;
        var b: [n]u64 = undefined;
        std.mem.writeInt(u256, @ptrCast(&a), x, .little);
        std.mem.writeInt(u256, @ptrCast(&b), y, .little);
        const p = mul(n, &a, &b);
        const expect = @as(u512, x) * @as(u512, y);
        var got: u512 = 0;
        for (p, 0..) |limb, j| {
            got |= @as(u512, limb) << @intCast(64 * j);
        }
        try std.testing.expectEqual(expect, got);
    }
}
