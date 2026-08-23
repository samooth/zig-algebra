// SPDX-License-Identifier: MIT OR Apache-2.0

//! Group-element polynomial evaluation.
//!
//! Evaluates `sum(C_k * x^k)` where `C_k` are group elements and `x` is a
//! scalar. Essential for VSS verification, KZG proof verification, and any
//! polynomial-commitment scheme that commits to group elements.

const std = @import("std");

/// Equality under either `eql` (our points) or `equivalent` (stdlib pcurves).
fn ptEql(comptime Point: type, a: Point, b: Point) bool {
    if (@hasDecl(Point, "equivalent")) return a.equivalent(b);
    return a.eql(b);
}

/// Identity under any naming convention.
fn ptIdentity(comptime Point: type) Point {
    if (@hasDecl(Point, "identityElement")) return Point.identityElement;
    if (@hasDecl(Point, "identity")) return Point.identity();
    return Point.zero();
}

/// Scalar multiplication under either convention.
fn ptScalarMul(p: anytype, bytes: [32]u8) @TypeOf(p) {
    const P = @TypeOf(p);
    if (@hasDecl(P, "scalarMul")) return p.scalarMul(bytes);
    // stdlib pcurves: mul(self, [32]u8, endian)
    return p.mul(bytes, .big) catch unreachable;
}

/// Evaluate a group-element polynomial at scalar `x` using Horner's method.
///
/// Given commitments `C_0, C_1, ..., C_n` and scalar `x`, computes:
///   result = C_0 + x * (C_1 + x * (C_2 + ... + x * C_n))
///
/// This is the group analogue of scalar polynomial evaluation, where
/// multiplication is scalar-point multiplication and addition is point addition.
///
/// `Point` must support `add` and scalar multiplication; `Scalar` is a
/// stdlib-style scalar whose `toBytes(.big)` yields the 32-byte multiplier.
pub fn evalGroupPoly(
    comptime Point: type,
    comptime Scalar: type,
    commitments: []const Point,
    x: Scalar,
) Point {
    if (commitments.len == 0) return ptIdentity(Point);
    if (commitments.len == 1) return commitments[0];

    // Horner's method: start from highest degree
    var result = commitments[commitments.len - 1];
    var i: usize = commitments.len - 1;
    while (i > 0) {
        i -= 1;
        // result = C_i + x * result
        const x_times_result = ptScalarMul(result, x.toBytes(.big));
        result = commitments[i].add(x_times_result);
    }
    return result;
}

/// Evaluate a group-element polynomial and verify against an expected value.
pub fn evalGroupPolyVerify(
    comptime Point: type,
    comptime Scalar: type,
    commitments: []const Point,
    x: Scalar,
    expected: Point,
) bool {
    const result = evalGroupPoly(Point, Scalar, commitments, x);
    return ptEql(Point, result, expected);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Build a secp256k1 scalar from a u64 (big-endian encoding).
fn scalarFromU64(v: u64) std.crypto.ecc.Secp256k1.scalar.Scalar {
    const S = std.crypto.ecc.Secp256k1.scalar.Scalar;
    var bytes: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, bytes[24..32], v, .big);
    return S.fromBytes(bytes, .big) catch unreachable;
}

test "evalGroupPoly single element" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const c0 = Secp256k1.basePoint;
    const x = scalarFromU64(42);
    const result = evalGroupPoly(Secp256k1, Scalar, &[_]Secp256k1{c0}, x);
    try testing.expect(ptEql(Secp256k1, result, c0));
}

test "evalGroupPoly two elements" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const c0 = Secp256k1.basePoint;
    const c1 = Secp256k1.basePoint;
    const x = scalarFromU64(1);

    // C_0 + x * C_1 = G + 1*G = 2G
    const result = evalGroupPoly(Secp256k1, Scalar, &[_]Secp256k1{ c0, c1 }, x);
    const expected = Secp256k1.basePoint.dbl();
    try testing.expect(ptEql(Secp256k1, result, expected));
}

test "evalGroupPoly empty" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const x = scalarFromU64(42);
    const result = evalGroupPoly(Secp256k1, Scalar, &[_]Secp256k1{}, x);
    try testing.expect(ptEql(Secp256k1, result, Secp256k1.identityElement));
}
