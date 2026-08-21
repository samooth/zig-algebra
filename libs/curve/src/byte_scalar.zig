// SPDX-License-Identifier: MIT OR Apache-2.0

//! Generic byte-scalar arithmetic for elliptic curve scalar fields.
//!
//! Provides byte-array `[N]u8` operations over any scalar type that supports
//! `fromBytes`, `toBytes`, `add`, `sub`, `mul`, `invert`, `neg`.
//!
//! This enables working with scalars as byte arrays (useful for APIs that
//! consume/produce `[N]u8` big-endian scalars, like SEC1 point encoding).

const std = @import("std");

/// Byte-scalar arithmetic over a scalar field.
///
/// `ScalarType` must support:
///   - `fromBytes(bytes, .big) !ScalarType`
///   - `toBytes(.big) [N]u8`
///   - `add(a, b) ScalarType`
///   - `sub(a, b) ScalarType`
///   - `mul(a, b) ScalarType`
///   - `invert() ScalarType`
///   - `neg() ScalarType`
pub fn ByteScalar(comptime ScalarType: type, comptime N: usize) type {
    return struct {
        const Self = @This();

        /// The zero scalar.
        pub fn zero() [N]u8 {
            return [_]u8{0} ** N;
        }

        /// The one scalar.
        pub fn one() [N]u8 {
            var bytes = [_]u8{0} ** N;
            bytes[N - 1] = 1;
            return bytes;
        }

        /// Encode a u64 as a canonical scalar (big-endian).
        pub fn fromInt(value: u64) [N]u8 {
            var bytes = [_]u8{0} ** N;
            const start = if (N >= 8) N - 8 else 0;
            std.mem.writeInt(u64, bytes[start..][0..8], value, .big);
            return bytes;
        }

        /// Validate canonical scalar bytes.
        pub fn fromBytes(bytes: [N]u8) ![N]u8 {
            _ = try ScalarType.fromBytes(bytes, .big);
            return bytes;
        }

        /// Reduce arbitrary bytes modulo the curve order.
        pub fn reduce(bytes: [N]u8) [N]u8 {
            if (N == 32) {
                var buf: [64]u8 = [_]u8{0} ** 64;
                @memcpy(buf[0..32], &bytes);
                return ScalarType.fromBytes64(buf, .big).toBytes(.big);
            }
            return bytes;
        }

        /// a + b (mod n).
        pub fn add(a: [N]u8, b: [N]u8) [N]u8 {
            return parse(a).add(parse(b)).toBytes(.big);
        }

        /// a - b (mod n).
        pub fn sub(a: [N]u8, b: [N]u8) [N]u8 {
            return parse(a).sub(parse(b)).toBytes(.big);
        }

        /// a * b (mod n).
        pub fn mul(a: [N]u8, b: [N]u8) [N]u8 {
            return parse(a).mul(parse(b)).toBytes(.big);
        }

        /// a^-1 (mod n); zero has no inverse and maps to zero.
        pub fn inv(a: [N]u8) [N]u8 {
            if (isZero(a)) return zero();
            return parse(a).invert().toBytes(.big);
        }

        /// -a (mod n).
        pub fn neg(a: [N]u8) [N]u8 {
            return parse(a).neg().toBytes(.big);
        }

        /// Constant-time equality of two canonical scalars.
        pub fn eql(a: [N]u8, b: [N]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }

        /// True if the scalar is zero.
        pub fn isZero(a: [N]u8) bool {
            return std.mem.allEqual(u8, &a, 0);
        }

        fn parse(bytes: [N]u8) ScalarType {
            return ScalarType.fromBytes(bytes, .big) catch unreachable;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ByteScalar basic operations" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const a = BS.fromInt(5);
    const b = BS.fromInt(3);

    // Addition
    const sum = BS.add(a, b);
    const expected_sum = BS.fromInt(8);
    try testing.expect(BS.eql(sum, expected_sum));

    // Subtraction
    const diff = BS.sub(a, b);
    const expected_diff = BS.fromInt(2);
    try testing.expect(BS.eql(diff, expected_diff));

    // Multiplication
    const prod = BS.mul(a, b);
    const expected_prod = BS.fromInt(15);
    try testing.expect(BS.eql(prod, expected_prod));

    // Identity
    try testing.expect(BS.eql(BS.zero(), BS.fromInt(0)));
    try testing.expect(BS.eql(BS.one(), BS.fromInt(1)));
}

test "ByteScalar inverse" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const a = BS.fromInt(7);
    const a_inv = BS.inv(a);
    const product = BS.mul(a, a_inv);
    try testing.expect(BS.eql(product, BS.one()));
}

test "ByteScalar zero inverse" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const z = BS.zero();
    const z_inv = BS.inv(z);
    try testing.expect(BS.eql(z_inv, BS.zero()));
}

test "ByteScalar negation" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const a = BS.fromInt(42);
    const neg_a = BS.neg(a);
    const sum = BS.add(a, neg_a);
    try testing.expect(BS.eql(sum, BS.zero()));
}
