// SPDX-License-Identifier: MIT OR Apache-2.0

//! Nothing-up-my-sleeve generator derivation via hash-to-curve.
//!
//! Provides try-and-increment hash-to-curve (generic over any SEC1 point type)
//! and generator vector derivation for protocols like Bulletproofs, Pedersen
//! commitments, and FROST that need independent, nothing-up-my-sleeve generators.

const std = @import("std");

/// Errors reported by the derivation functions.
///
/// `hashToPoint` used to `catch unreachable` the `bufPrint` of a fixed 64-byte
/// stack buffer (a domain longer than the buffer panicked in safe builds and
/// was undefined behaviour in `ReleaseFast`) and to end the try-and-increment
/// loop with `unreachable` when no point was found. Both are ordinary errors
/// now, so a caller-supplied domain can never abort the process.
pub const DeriveError = error{
    /// The domain does not fit in the label buffer; see `max_domain_len`.
    DomainTooLong,
    /// No valid point was found within `max_attempts` increments.
    NoValidPoint,
};

/// Upper bound on try-and-increment rounds before giving up.
pub const max_attempts: u64 = 100_000;

/// Stack buffer for the `"{domain}:{counter}"` label that is hashed.
const label_buffer_len = 64;
/// Widest decimal we ever format for a counter (a `u64` is 20 digits).
const max_counter_digits = 20;
/// Longest domain accepted by `hashToPoint`: it must leave room for the
/// separator and the counter inside `label_buffer_len`.
pub const max_domain_len = label_buffer_len - max_counter_digits - 1;
/// Longest domain accepted by `generatorVector`, which additionally appends
/// `"/{index}"` and hands the result to `hashToPoint`.
pub const max_generator_vector_domain_len = max_domain_len - 1 - max_counter_digits;

/// Derive a single nothing-up-my-sleeve generator via try-and-increment.
///
/// For counter = 0, 1, ..., hashes `SHA256(domain:counter)` as an x-coordinate
/// and tries the even-y (0x02) then odd-y (0x03) compressed encodings,
/// returning the first valid point. No discrete-log relation with standard
/// generators is known.
///
/// `Point` must support `fromSec1([]const u8) !Point` accepting compressed
/// SEC1 encodings (0x02/0x03 prefix).
///
/// `domain` must be at most `max_domain_len` bytes; a longer domain is
/// rejected with `error.DomainTooLong` instead of overflowing the label
/// buffer. `error.NoValidPoint` is returned if `max_attempts` rounds pass
/// without a decodable point.
pub fn hashToPoint(Point: type, domain: []const u8) DeriveError!Point {
    if (domain.len > max_domain_len) return error.DomainTooLong;

    var counter: u64 = 0;
    while (counter < max_attempts) : (counter += 1) {
        var buf: [label_buffer_len]u8 = undefined;
        // Unreachable given the length check above; typed error, not
        // `unreachable`, so a future change cannot turn this into UB.
        const label = std.fmt.bufPrint(&buf, "{s}:{d}", .{ domain, counter }) catch return error.DomainTooLong;
        const x = sha256d(label);
        for ([_]u8{ 0x02, 0x03 }) |prefix| {
            var compressed: [33]u8 = undefined;
            compressed[0] = prefix;
            @memcpy(compressed[1..], &x);
            if (Point.fromSec1(&compressed)) |p| {
                return p;
            } else |_| {}
        }
    }
    return error.NoValidPoint;
}

/// Derive n independent generators: hashToPoint(domain + "/" + i).
///
/// `domain` must be at most `max_generator_vector_domain_len` bytes so that
/// every `domain + "/" + i` label stays within `hashToPoint`'s own limit.
pub fn generatorVector(
    Point: type,
    domain: []const u8,
    n: usize,
    allocator: std.mem.Allocator,
) (DeriveError || std.mem.Allocator.Error)![]Point {
    if (domain.len > max_generator_vector_domain_len) return error.DomainTooLong;
    var vec = try allocator.alloc(Point, n);
    errdefer allocator.free(vec);
    for (0..n) |i| {
        var buf: [label_buffer_len]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}/{d}", .{ domain, i }) catch return error.DomainTooLong;
        vec[i] = try hashToPoint(Point, label);
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

    const p = try hashToPoint(Secp256k1, "test/domain/v1");
    // Just verify it doesn't crash and produces a non-identity point
    try testing.expect(!std.mem.allEqual(u8, &p.toCompressedSec1(), 0));
}

test "generatorVector produces distinct generators" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    const vec = try generatorVector(Secp256k1, "test/gens", 10, std.testing.allocator);
    defer std.testing.allocator.free(vec);

    try testing.expectEqual(@as(usize, 10), vec.len);
    for (vec, 0..) |a, i| {
        for (vec[i + 1 ..]) |b| {
            try testing.expect(!a.equivalent(b));
        }
    }
}

test "hashToPoint is deterministic" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    const p1 = try hashToPoint(Secp256k1, "deterministic/test");
    const p2 = try hashToPoint(Secp256k1, "deterministic/test");
    try testing.expect(p1.equivalent(p2));
}

test "hashToPoint rejects an over-long domain instead of panicking" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    // Exactly at the limit still works.
    const at_limit = "d" ** max_domain_len;
    try testing.expectError(error.DomainTooLong, hashToPoint(Secp256k1, "d" ** (max_domain_len + 1)));
    _ = try hashToPoint(Secp256k1, at_limit);

    // Long enough to have overflowed the old 64-byte stack buffer.
    try testing.expectError(error.DomainTooLong, hashToPoint(Secp256k1, "d" ** 4096));
    try testing.expectError(error.DomainTooLong, generatorVector(Secp256k1, "d" ** 4096, 2, std.testing.allocator));
}

test "generatorVector rejects a domain that would overflow the label" {
    const Secp256k1 = std.crypto.ecc.Secp256k1;

    try testing.expectError(
        error.DomainTooLong,
        generatorVector(Secp256k1, "d" ** (max_generator_vector_domain_len + 1), 2, std.testing.allocator),
    );
    // At the limit every `domain/i` label is still inside `hashToPoint`'s.
    const vec = try generatorVector(Secp256k1, "d" ** max_generator_vector_domain_len, 2, std.testing.allocator);
    defer std.testing.allocator.free(vec);
    try testing.expect(!vec[0].equivalent(vec[1]));
}

/// A point type that never decodes, to exercise the search-exhausted path.
const NeverPoint = struct {
    pub fn fromSec1(_: []const u8) error{Invalid}!NeverPoint {
        return error.Invalid;
    }
};

test "generatorVector releases its allocation when a derivation fails" {
    // No point is ever decodable, so the first element fails after the
    // allocation: it must not be leaked.
    try testing.expectError(
        error.NoValidPoint,
        generatorVector(NeverPoint, "never", 4, std.testing.allocator),
    );
}

test "hashToPoint reports NoValidPoint when nothing decodes" {
    try testing.expectError(error.NoValidPoint, hashToPoint(NeverPoint, "nothing/here"));
}
