// SPDX-License-Identifier: MIT OR Apache-2.0

//! Generic elliptic curve group operations.
//!
//! Provides a uniform API over any curve point type that supports
//! addition, negation, equality, an identity element, scalar
//! multiplication and SEC1 (de)serialization. Adapts both our own
//! Weierstrass points (`add`/`eql`/`scalarMul`) and stdlib pcurves
//! (`add`/`equivalent`/`mul([32]u8, endian)`/`identityElement`).

const std = @import("std");

/// Return the identity element of a point type.
pub fn identity(comptime Point: type) Point {
    if (@hasDecl(Point, "identityElement")) return Point.identityElement;
    if (@hasDecl(Point, "identity")) return Point.identity();
    return Point.zero();
}

/// Equality of two points under either naming convention.
pub fn eql(comptime Point: type, a: Point, b: Point) bool {
    if (@hasDecl(Point, "equivalent")) return a.equivalent(b);
    return a.eql(b);
}

/// Multiply `p` by a scalar (bytes or integer, per point type convention).
pub fn scalarMul(p: anytype, scalar: anytype) @TypeOf(p) {
    const P = @TypeOf(p);
    if (@hasDecl(P, "scalarMul")) return p.scalarMul(scalar);
    // stdlib pcurves: mul(self, [32]u8, endian)
    return p.mul(scalar, .big) catch unreachable;
}

/// Identity element of a point type (any naming convention).
fn file_identity(comptime Point: type) Point {
    if (@hasDecl(Point, "identityElement")) return Point.identityElement;
    if (@hasDecl(Point, "identity")) return Point.identity();
    return Point.zero();
}

/// Generic group operations over a curve point type.
///
/// `Point` must support:
///   - `add(a, b) Point`
///   - `neg(p) Point`
///   - equality via `eql` or `equivalent`
///   - identity via `identity()` / `zero()` / `identityElement`
///   - scalar multiplication via `scalarMul` or `mul([32]u8, .big)`
///   - `toCompressedSec1() [33]u8`
///   - `fromSec1(bytes) !Point`
pub fn GroupOps(comptime Point: type) type {
    return struct {
        const Self = @This();

        /// Point at infinity (identity element).
        pub fn identity() Point {
            return file_identity(Point);
        }

        /// Add two points.
        pub fn add(a: Point, b: Point) Point {
            return a.add(b);
        }

        /// Subtract two points: a - b.
        pub fn sub(a: Point, b: Point) Point {
            return a.add(b.neg());
        }

        /// Negate a point.
        pub fn negate(p: Point) Point {
            return p.neg();
        }

        /// Scalar multiplication.
        pub fn mul(p: Point, scalar_bytes: anytype) Point {
            return scalarMul(p, scalar_bytes);
        }

        /// Check if a point is the identity element.
        pub fn isIdentity(p: Point) bool {
            if (@hasField(Point, "infinity")) return p.infinity;
            return eql(Point, p, Self.identity());
        }

        /// Check if two points are equal.
        pub fn eq(a: Point, b: Point) bool {
            return eql(Point, a, b);
        }

        /// Serialize a point to compressed SEC1 format.
        pub fn serialize(p: Point) ![33]u8 {
            return p.toCompressedSec1();
        }

        /// Deserialize a point from SEC1 encoding.
        pub fn deserialize(bytes: []const u8) !Point {
            return Point.fromSec1(bytes);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "GroupOps with Secp256k1" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const G = GroupOps(Secp256k1);

    const gen = Secp256k1.basePoint;
    const id = G.identity();

    // identity + gen = gen
    const sum = G.add(id, gen);
    try testing.expect(G.eq(sum, gen));

    // gen + (-gen) = identity
    const neg_gen = G.negate(gen);
    const diff = G.add(gen, neg_gen);
    try testing.expect(G.isIdentity(diff));

    // Serialization round-trip
    const bytes = try G.serialize(gen);
    const deserialized = try G.deserialize(&bytes);
    try testing.expect(G.eq(gen, deserialized));
}
