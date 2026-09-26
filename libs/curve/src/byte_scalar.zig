// SPDX-License-Identifier: MIT OR Apache-2.0

//! Generic byte-scalar arithmetic for elliptic curve scalar fields.
//!
//! Provides byte-array `[N]u8` operations over any scalar type that supports
//! `fromBytes`, `toBytes`, `add`, `sub`, `mul`, `invert`, `neg`.
//!
//! This enables working with scalars as byte arrays (useful for APIs that
//! consume/produce `[N]u8` big-endian scalars, like SEC1 point encoding).

const std = @import("std");

/// Error set of every `ByteScalar` operation that parses caller-supplied
/// bytes. `error.NotCanonical` means the input was `>= n` (the field order).
pub const ByteScalarError = error{NotCanonical};

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
        ///
        /// # Errors
        /// `error.NotCanonical` when `bytes >= n`.
        pub fn fromBytes(bytes: [N]u8) ByteScalarError![N]u8 {
            _ = try parseChecked(bytes);
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
        ///
        /// # Errors
        /// `error.NotCanonical` when either input is `>= n`. The old
        /// implementation `catch unreachable`d the stdlib
        /// `fromBytes(...)` rejection, so a wire scalar of `n` or more
        /// aborted the process. Use `reduce` first, or `fromBytes` to
        /// validate, when the input is untrusted.
        pub fn add(a: [N]u8, b: [N]u8) ByteScalarError![N]u8 {
            return (try parseChecked(a)).add(try parseChecked(b)).toBytes(.big);
        }

        /// a - b (mod n).
        ///
        /// # Errors
        /// `error.NotCanonical` when either input is `>= n`.
        pub fn sub(a: [N]u8, b: [N]u8) ByteScalarError![N]u8 {
            return (try parseChecked(a)).sub(try parseChecked(b)).toBytes(.big);
        }

        /// a * b (mod n).
        ///
        /// # Errors
        /// `error.NotCanonical` when either input is `>= n`.
        pub fn mul(a: [N]u8, b: [N]u8) ByteScalarError![N]u8 {
            return (try parseChecked(a)).mul(try parseChecked(b)).toBytes(.big);
        }

        /// a^-1 (mod n); zero has no inverse and maps to zero.
        ///
        /// # Errors
        /// `error.NotCanonical` when `a >= n`. Zero still maps to zero
        /// (the legacy total behaviour, and zero is not an inverse).
        pub fn inv(a: [N]u8) ByteScalarError![N]u8 {
            if (isZero(a)) return zero();
            return (try parseChecked(a)).invert().toBytes(.big);
        }

        /// -a (mod n).
        ///
        /// # Errors
        /// `error.NotCanonical` when `a >= n`.
        pub fn neg(a: [N]u8) ByteScalarError![N]u8 {
            return (try parseChecked(a)).neg().toBytes(.big);
        }

        /// Constant-time equality of two canonical scalars.
        pub fn eql(a: [N]u8, b: [N]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }

        /// True if the scalar is zero.
        pub fn isZero(a: [N]u8) bool {
            return std.mem.allEqual(u8, &a, 0);
        }

        /// Parse canonical bytes, mapping the stdlib non-canonical rejection
        /// onto `error.NotCanonical`. Never panics on caller input.
        fn parseChecked(bytes: [N]u8) ByteScalarError!ScalarType {
            return ScalarType.fromBytes(bytes, .big) catch return error.NotCanonical;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ByteScalar rejects non-canonical input instead of panicking" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    // The field order itself is not a canonical scalar: every operation used
    // to `catch unreachable` this stdlib rejection.
    // secp256k1 group order, big-endian.
    const order = [32]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    };
    try testing.expectError(error.NotCanonical, BS.fromBytes(order));
    try testing.expectError(error.NotCanonical, BS.add(order, BS.one()));
    try testing.expectError(error.NotCanonical, BS.sub(order, BS.one()));
    try testing.expectError(error.NotCanonical, BS.mul(order, BS.one()));
    try testing.expectError(error.NotCanonical, BS.inv(order));
    try testing.expectError(error.NotCanonical, BS.neg(order));
    try testing.expectError(error.NotCanonical, BS.add(BS.one(), order));

    // `reduce` is the total entry point for untrusted bytes.
    const reduced = BS.reduce(order);
    try testing.expect(BS.eql(reduced, BS.zero()));
    _ = try BS.add(reduced, BS.one());
}

test "ByteScalar basic operations" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const a = BS.fromInt(5);
    const b = BS.fromInt(3);

    // Addition
    const sum = try BS.add(a, b);
    const expected_sum = BS.fromInt(8);
    try testing.expect(BS.eql(sum, expected_sum));

    // Subtraction
    const diff = try BS.sub(a, b);
    const expected_diff = BS.fromInt(2);
    try testing.expect(BS.eql(diff, expected_diff));

    // Multiplication
    const prod = try BS.mul(a, b);
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
    const a_inv = try BS.inv(a);
    const product = try BS.mul(a, a_inv);
    try testing.expect(BS.eql(product, BS.one()));
}

test "ByteScalar zero inverse" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const z = BS.zero();
    const z_inv = try BS.inv(z);
    try testing.expect(BS.eql(z_inv, BS.zero()));
}

test "ByteScalar negation" {
    const SecpScalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    const BS = ByteScalar(SecpScalar, 32);

    const a = BS.fromInt(42);
    const neg_a = try BS.neg(a);
    const sum = try BS.add(a, neg_a);
    try testing.expect(BS.eql(sum, BS.zero()));
}
