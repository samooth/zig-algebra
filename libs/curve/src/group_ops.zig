// SPDX-License-Identifier: MIT OR Apache-2.0

//! Generic elliptic curve group operations.
//!
//! Provides a uniform API over any curve point type that supports
//! `add`, `neg`, `eql`, `identity`, `scalarMul`, `toCompressedSec1`, `fromSec1`.

const std = @import("std");

/// Generic group operations over a curve point type.
///
/// `Point` must support:
///   - `add(a, b) Point`
///   - `neg(p) Point`
///   - `eql(a, b) bool`
///   - `identity() Point` (or `zero()`)
///   - `scalarMul(p, scalar_bytes) !Point`
///   - `toCompressedSec1() [33]u8`
///   - `fromSec1(bytes) !Point`
pub fn GroupOps(comptime Point: type) type {
    return struct {
        const Self = @This();

        /// Point at infinity (identity element).
        pub fn identity() Point {
            if (@hasDecl(Point, "identity")) return Point.identity();
            return Point.zero();
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
        pub fn scalarMul(p: Point, scalar_bytes: anytype) !Point {
            return p.scalarMul(scalar_bytes);
        }

        /// Scalar multiplication by the generator.
        pub fn scalarBaseMul(scalar_bytes: anytype, generator: Point) !Point {
            return generator.scalarMul(scalar_bytes);
        }

        /// Check if a point is the identity element.
        pub fn isIdentity(p: Point) bool {
            if (@hasDecl(Point, "infinity")) return p.infinity;
            if (@hasDecl(Point, "eql")) return p.eql(Self.identity());
            return false;
        }

        /// Check if two points are equal.
        pub fn eql(a: Point, b: Point) bool {
            return a.eql(b);
        }

        /// Serialize a point to compressed SEC1 format.
        pub fn serialize(p: Point) ![33]u8 {
            return p.toCompressedSec1();
        }

        /// Deserialize a point from compressed SEC1 format.
        pub fn deserialize(bytes: [33]u8) !Point {
            return Point.fromSec1(&bytes);
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
    try testing.expect(G.eql(sum, gen));

    // gen + (-gen) = identity
    const neg_gen = G.negate(gen);
    const diff = G.add(gen, neg_gen);
    try testing.expect(G.isIdentity(diff));

    // Serialization round-trip
    const bytes = G.serialize(gen) catch return error.TestFailed;
    const deserialized = G.deserialize(bytes) catch return error.TestFailed;
    try testing.expect(G.eql(gen, deserialized));
}
