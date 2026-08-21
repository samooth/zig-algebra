// SPDX-License-Identifier: MIT OR Apache-2.0

//! Group-element polynomial evaluation.
//!
//! Evaluates `sum(C_k * x^k)` where `C_k` are group elements and `x` is a
//! scalar. Essential for VSS verification, KZG proof verification, and any
//! polynomial-commitment scheme that commits to group elements.

const std = @import("std");

/// Evaluate a group-element polynomial at scalar `x` using Horner's method.
///
/// Given commitments `C_0, C_1, ..., C_n` and scalar `x`, computes:
///   result = C_0 + x * (C_1 + x * (C_2 + ... + x * C_n))
///
/// This is the group analogue of scalar polynomial evaluation, where
/// multiplication is scalar-point multiplication and addition is point addition.
///
/// `Point` must support `add`, `scalarMul`. `Scalar` must support `toBytes(.big)`.
pub fn evalGroupPoly(
    comptime Point: type,
    comptime Scalar: type,
    commitments: []const Point,
    x: Scalar,
) Point {
    if (commitments.len == 0) return Point.identity();
    if (commitments.len == 1) return commitments[0];

    // Horner's method: start from highest degree
    var result = commitments[commitments.len - 1];
    var i: usize = commitments.len - 1;
    while (i > 0) {
        i -= 1;
        // result = C_i + x * result
        const x_times_result = result.scalarMul(x.toBytes(.big));
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
    return result.eql(expected);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "evalGroupPoly single element" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const c0 = Secp256k1.basePoint;
    const x = Scalar.fromInt(42);
    const result = evalGroupPoly(Secp256k1, Scalar, &[_]Secp256k1{c0}, x);
    try testing.expect(result.eql(c0));
}

test "evalGroupPoly two elements" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const c0 = Secp256k1.basePoint;
    const c1 = Secp256k1.basePoint;
    const x = Scalar.fromInt(1);

    // C_0 + x * C_1 = G + 1*G = 2G
    const result = evalGroupPoly(Secp256k1, Scalar, &[_]Secp256k1{ c0, c1 }, x);
    const expected = c0.add(c1);
    try testing.expect(result.eql(expected));
}

test "evalGroupPoly empty" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const x = Scalar.fromInt(42);
    const result = evalGroupPoly(Secp256k1, Scalar, &[_]Secp256k1{}, x);
    try testing.expect(result.eql(Secp256k1.identityElement));
}
