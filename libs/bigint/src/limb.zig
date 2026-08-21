//! Low-level limb operations for multiprecision arithmetic.
//!
//! A **limb** is a single `u64` digit.  All primitives in this module are
//! `inline` and operate on individual limbs, returning carry/borrow or the
//! high half of a product.  They are the atomic building blocks for `BigInt`;
//! end users rarely call them directly.
//!
//! # Design
//! - Every operation is `inline` — the compiler folds them into the caller.
//! - Results use `struct { ... }` returns so the optimizer can keep values in
//!   registers.
//! - `DoubleLimb = u128` is used for full products, then split into hi/lo.
//!
//! # Example
//! ```zig
//! const a: Limb = 0xFFFF_FFFF_FFFF_FFFF;
//! const b: Limb = 1;
//! const r = limb.addWithCarry(a, b, 0);
//! // r.sum  = 0 (wrapped)
//! // r.cout = 1 (carry out)
//! ```

const std = @import("std");

/// A single machine word used as a digit.
pub const Limb = u64;

/// Double-width type for full products.
pub const DoubleLimb = u128;

/// Number of bits per limb.
pub const LimbBits = 64;

/// Add two limbs with carry-in, returning `(sum, carry-out)`.
///
/// # Example
/// ```zig
/// const r = addWithCarry(0xFFFF_FFFF_FFFF_FFFF, 1, 0);
/// try std.testing.expectEqual(@as(Limb, 0), r.sum);
/// try std.testing.expectEqual(@as(u1, 1), r.cout);
/// ```
pub inline fn addWithCarry(a: Limb, b: Limb, cin: u1) struct { sum: Limb, cout: u1 } {
    const s = @as(DoubleLimb, a) + @as(DoubleLimb, b) + @as(DoubleLimb, cin);
    return .{
        .sum = @truncate(s),
        .cout = @intCast(s >> LimbBits),
    };
}

/// Subtract two limbs with borrow-in, returning `(diff, borrow-out)`.
///
/// # Example
/// ```zig
/// const r = subWithBorrow(0, 1, 0);
/// try std.testing.expectEqual(@as(Limb, 0xFFFF_FFFF_FFFF_FFFF), r.diff);
/// try std.testing.expectEqual(@as(u1, 1), r.bout);
/// ```
pub inline fn subWithBorrow(a: Limb, b: Limb, bin: u1) struct { diff: Limb, bout: u1 } {
    const d = @as(DoubleLimb, a) -% @as(DoubleLimb, b) -% @as(DoubleLimb, bin);
    return .{
        .diff = @truncate(d),
        .bout = if (a < b + bin) 1 else 0,
    };
}

/// Multiply two limbs, returning `(low, high)` as a 128-bit product.
///
/// # Example
/// ```zig
/// const r = mulWide(0x1_0000_0000, 0x1_0000_0000);
/// try std.testing.expectEqual(@as(Limb, 0), r.lo);
/// try std.testing.expectEqual(@as(Limb, 1), r.hi); // 2^32 * 2^32 = 2^64
/// ```
pub inline fn mulWide(a: Limb, b: Limb) struct { lo: Limb, hi: Limb } {
    const p = @as(DoubleLimb, a) * @as(DoubleLimb, b);
    return .{
        .lo = @truncate(p),
        .hi = @truncate(p >> LimbBits),
    };
}

/// Multiply-add with carry: `a*b + c + carry_in`, returning `(low, high)`.
///
/// This is the primitive used in long multiplication: each step computes
/// `result[i+j] += a[i]*b[j] + carry`.
///
/// # Example
/// ```zig
/// const r = mulAddCarry(3, 7, 5, 2); // 3*7 + 5 + 2 = 28
/// try std.testing.expectEqual(@as(Limb, 28), r.lo);
/// try std.testing.expectEqual(@as(Limb, 0), r.hi);
/// ```
pub inline fn mulAddCarry(a: Limb, b: Limb, c: Limb, cin: Limb) struct { lo: Limb, hi: Limb } {
    const p = @as(DoubleLimb, a) * @as(DoubleLimb, b) + @as(DoubleLimb, c) + @as(DoubleLimb, cin);
    return .{
        .lo = @truncate(p),
        .hi = @truncate(p >> LimbBits),
    };
}

/// Count leading zeros in a limb.
pub inline fn clz(x: Limb) u7 {
    return @intCast(@clz(x));
}

/// Count trailing zeros in a limb.
pub inline fn ctz(x: Limb) u7 {
    return @intCast(@ctz(x));
}

/// Bit length of a limb (position of the most significant 1-bit, or 0 for 0).
///
/// # Example
/// ```zig
/// try std.testing.expectEqual(@as(u7, 8), bitLen(0xFF));
/// try std.testing.expectEqual(@as(u7, 0), bitLen(0));
/// ```
pub inline fn bitLen(x: Limb) u7 {
    return LimbBits - clz(x);
}

/// Divide a 128-bit dividend by a 64-bit divisor, returning `(quotient, remainder)`.
///
/// # Example
/// ```zig
/// const r = divDoubleLimb(0x1_0000_0000_0000_0000_0000_0000, 2);
/// try std.testing.expectEqual(@as(Limb, 0x8000_0000_0000_0000_0000_0000), r.q);
/// try std.testing.expectEqual(@as(Limb, 0), r.r);
/// ```
pub inline fn divDoubleLimb(dividend: DoubleLimb, divisor: Limb) struct { q: Limb, r: Limb } {
    const q = @as(Limb, @truncate(dividend / divisor));
    const r = @as(Limb, @truncate(dividend % divisor));
    return .{ .q = q, .r = r };
}

/// Compare two same-length little-endian limb slices.
///
/// Returns `-1` if `a < b`, `0` if equal, `1` if `a > b`.
///
/// # Panics
/// Debug-asserts that both slices have the same length.
pub fn cmpLimbs(a: []const Limb, b: []const Limb) i2 {
    const n = a.len;
    std.debug.assert(n == b.len);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}

/// Return the number of significant limbs (strip leading zeros).
///
/// # Example
/// ```zig
/// const limbs = [_]Limb{ 1, 2, 0, 0 };
/// try std.testing.expectEqual(@as(usize, 2), sigLimbs(&limbs));
/// ```
pub fn sigLimbs(limbs: []const Limb) usize {
    var i = limbs.len;
    while (i > 0 and limbs[i - 1] == 0) i -= 1;
    return i;
}

/// Number of bits in the binary representation of a comptime integer.
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
