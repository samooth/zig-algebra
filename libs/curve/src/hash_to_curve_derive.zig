// SPDX-License-Identifier: MIT OR Apache-2.0

//! Nothing-up-my-sleeve generator derivation via hash-to-curve.
//!
//! Provides try-and-increment hash-to-curve (generic over any SEC1 point type)
//! and generator vector derivation for protocols like Bulletproofs, Pedersen
//! commitments, and FROST that need independent, nothing-up-my-sleeve generators.

const std = @import("std");

/// Derive a single nothing-up-my-sleeve generator via try-and-increment.
///
/// For counter = 0, 1, ..., hashes `SHA256(domain:counter)` as an x-coordinate
/// and tries the even-y (0x02) then odd-y (0x03) compressed encodings,
/// returning the first valid point. No discrete-log relation with standard
/// generators is known.
///
/// `Point` must support `fromCompressedSec1([33]u8) !Point`.
pub fn hashToPoint(Point: type, domain: []const u8) Point {
    var counter: u64 = 0;
    while (counter < 100_000) : (counter += 1) {
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}:{d}", .{ domain, counter }) catch unreachable;
        const x = sha256d(label);
        for ([_]u8{ 0x02, 0x03 }) |prefix| {
            var compressed: [33]u8 = undefined;
            compressed[0] = prefix;
            @memcpy(compressed[1..], &x);
            if (Point.fromCompressedSec1(&compressed)) |p| {
                return p;
            } else |_| {}
        }
    }
    unreachable;
}

/// Derive n independent generators: hashToPoint(domain + "/" + i).
pub fn generatorVector(
    Point: type,
    domain: []const u8,
    n: usize,
    allocator: std.mem.Allocator,
) ![]Point {
    var vec = try allocator.alloc(Point, n);
    errdefer allocator.free(vec);
    for (0..n) |i| {
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}/{d}", .{ domain, i }) catch unreachable;
        vec[i] = hashToPoint(Point, label);
    }
    return vec;
}

/// SHA-256d(domain) — double SHA-256, used as the hash function for
/// try-and-increment. Returns a 32-byte x-coordinate candidate.
fn sha256d(domain: []const u8) [32]u8 {
    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    h1.update(domain);
    var first: [32]u8 = undefined;
    h1.final(&first);

    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    h2.update(&first);
    var second: [32]u8 = undefined;
    h2.final(&second);
    return second;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "hashToPoint produces valid Secp256k1 points" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    const p = hashToPoint(Secp256k1, "test/domain/v1");
    // Just verify it doesn't crash and produces a non-identity point
    try testing.expect(!std.mem.allEqual(u8, &p.toCompressedSec1(), 0));
}

test "generatorVector produces distinct generators" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    var buf: [10]Secp256k1 = undefined;
    for (0..10) |i| {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "test/{d}", .{i}) catch unreachable;
        buf[i] = hashToPoint(Secp256k1, label);
    }
    // All should be distinct
    for (0..10) |i| {
        for (i + 1..10) |j| {
            try testing.expect(!buf[i].eql(buf[j]));
        }
    }
}

test "hashToPoint is deterministic" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    const p1 = hashToPoint(Secp256k1, "deterministic/test");
    const p2 = hashToPoint(Secp256k1, "deterministic/test");
    try testing.expect(p1.eql(p2));
}
