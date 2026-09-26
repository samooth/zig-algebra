// SPDX-License-Identifier: MIT OR Apache-2.0

//! Vector utilities for finite field arithmetic.
//!
//! Generic vector operations over any scalar type that supports
//! `add`, `sub`, `mul`, `zero`, `one`.

const std = @import("std");

/// Compute inner product (dot product) of two vectors.
///
/// # Errors
/// `error.LengthMismatch` when `a.len != b.len`. The old
/// `std.debug.assert` is compiled out in `ReleaseFast`, where the
/// `for (a, b)` loop then reads past the end of the shorter slice.
pub fn inner(comptime T: type, a: []const T, b: []const T) error{LengthMismatch}!T {
    if (a.len != b.len) return error.LengthMismatch;
    var acc = T.zero();
    for (a, b) |x, y| acc = acc.add(x.mul(y));
    return acc;
}

/// Compute powers of a scalar: [1, base, base^2, ..., base^(n-1)].
pub fn powers(comptime T: type, allocator: std.mem.Allocator, base: T, n: usize) ![]T {
    var out = try allocator.alloc(T, n);
    errdefer allocator.free(out);
    if (n == 0) return out;
    out[0] = T.one();
    for (1..n) |i| out[i] = out[i - 1].mul(base);
    return out;
}

/// Element-wise vector addition: a + b.
///
/// # Errors
/// `error.LengthMismatch` when `a.len != b.len`; the previous
/// `std.debug.assert` disappeared in `ReleaseFast` and the element-wise loop
/// then read out of bounds. Also `error.OutOfMemory`.
pub fn vecAdd(comptime T: type, allocator: std.mem.Allocator, a: []const T, b: []const T) error{ LengthMismatch, OutOfMemory }![]T {
    if (a.len != b.len) return error.LengthMismatch;
    const out = try allocator.alloc(T, a.len);
    for (a, b, 0..) |x, y, i| out[i] = x.add(y);
    return out;
}

/// Element-wise vector subtraction: a - b.
///
/// # Errors
/// `error.LengthMismatch` when `a.len != b.len`, plus `error.OutOfMemory`.
pub fn vecSub(comptime T: type, allocator: std.mem.Allocator, a: []const T, b: []const T) error{ LengthMismatch, OutOfMemory }![]T {
    if (a.len != b.len) return error.LengthMismatch;
    const out = try allocator.alloc(T, a.len);
    for (a, b, 0..) |x, y, i| out[i] = x.sub(y);
    return out;
}

/// Scalar-vector multiplication: s * a.
pub fn vecScale(comptime T: type, allocator: std.mem.Allocator, s: T, a: []const T) ![]T {
    const out = try allocator.alloc(T, a.len);
    for (a, 0..) |x, i| out[i] = s.mul(x);
    return out;
}

/// Element-wise vector multiplication (Hadamard product): a o b.
///
/// # Errors
/// `error.LengthMismatch` when `a.len != b.len`, plus `error.OutOfMemory`.
pub fn hadamard(comptime T: type, allocator: std.mem.Allocator, a: []const T, b: []const T) error{ LengthMismatch, OutOfMemory }![]T {
    if (a.len != b.len) return error.LengthMismatch;
    const out = try allocator.alloc(T, a.len);
    for (a, b, 0..) |x, y, i| out[i] = x.mul(y);
    return out;
}

/// Vector sum: sum of all elements.
pub fn vecSum(comptime T: type, a: []const T) T {
    var acc = T.zero();
    for (a) |x| acc = acc.add(x);
    return acc;
}

/// Check if two vectors are equal.
pub fn vecEql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Simple test field (mod 7) for testing.
const F7 = struct {
    value: u64,
    pub const MODULUS: u64 = 7;

    pub fn zero() @This() {
        return .{ .value = 0 };
    }
    pub fn one() @This() {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: u64) @This() {
        return .{ .value = x % MODULUS };
    }
    pub fn add(a: @This(), b: @This()) @This() {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: @This(), b: @This()) @This() {
        return fromInt((a.value + MODULUS - b.value) % MODULUS);
    }
    pub fn mul(a: @This(), b: @This()) @This() {
        return fromInt(a.value * b.value);
    }
    pub fn eql(a: @This(), b: @This()) bool {
        return a.value == b.value;
    }
};

test "inner product" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const b = [_]F7{ F7.fromInt(4), F7.fromInt(5), F7.fromInt(6) };
    // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32 mod 7 = 4
    const result = try inner(F7, &a, &b);
    try testing.expect(result.eql(F7.fromInt(4)));
}

test "inner product rejects a length mismatch" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2) };
    const b = [_]F7{F7.fromInt(4)};
    try testing.expectError(error.LengthMismatch, inner(F7, &a, &b));
}

test "powers" {
    const p = try powers(F7, std.testing.allocator, F7.fromInt(2), 5);
    defer std.testing.allocator.free(p);
    // [1, 2, 4, 1, 2] (mod 7)
    try testing.expect(p[0].eql(F7.fromInt(1)));
    try testing.expect(p[1].eql(F7.fromInt(2)));
    try testing.expect(p[2].eql(F7.fromInt(4)));
    try testing.expect(p[3].eql(F7.fromInt(1))); // 8 mod 7 = 1
    try testing.expect(p[4].eql(F7.fromInt(2))); // 16 mod 7 = 2
}

test "vecAdd" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const b = [_]F7{ F7.fromInt(4), F7.fromInt(5), F7.fromInt(6) };
    const result = try vecAdd(F7, std.testing.allocator, &a, &b);
    defer std.testing.allocator.free(result);
    try testing.expect(result[0].eql(F7.fromInt(5)));
    try testing.expect(result[1].eql(F7.fromInt(0))); // 7 mod 7 = 0
    try testing.expect(result[2].eql(F7.fromInt(2))); // 9 mod 7 = 2
}

test "vecScale" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const result = try vecScale(F7, std.testing.allocator, F7.fromInt(3), &a);
    defer std.testing.allocator.free(result);
    try testing.expect(result[0].eql(F7.fromInt(3)));
    try testing.expect(result[1].eql(F7.fromInt(6)));
    try testing.expect(result[2].eql(F7.fromInt(2))); // 9 mod 7 = 2
}

test "hadamard product" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const b = [_]F7{ F7.fromInt(4), F7.fromInt(5), F7.fromInt(6) };
    const result = try hadamard(F7, std.testing.allocator, &a, &b);
    defer std.testing.allocator.free(result);
    try testing.expect(result[0].eql(F7.fromInt(4)));
    try testing.expect(result[1].eql(F7.fromInt(3))); // 10 mod 7 = 3
    try testing.expect(result[2].eql(F7.fromInt(4))); // 18 mod 7 = 4
}

test "vecSum" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const result = vecSum(F7, &a);
    try testing.expect(result.eql(F7.fromInt(6)));
}

test "vecEql" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const b = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    const c = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(4) };
    try testing.expect(vecEql(F7, &a, &b));
    try testing.expect(!vecEql(F7, &a, &c));
}

test "vecAdd/vecSub/hadamard reject a length mismatch" {
    const a = [_]F7{ F7.fromInt(1), F7.fromInt(2) };
    const b = [_]F7{F7.fromInt(4)};
    try testing.expectError(error.LengthMismatch, vecAdd(F7, testing.allocator, &a, &b));
    try testing.expectError(error.LengthMismatch, vecSub(F7, testing.allocator, &a, &b));
    try testing.expectError(error.LengthMismatch, hadamard(F7, testing.allocator, &a, &b));
}
