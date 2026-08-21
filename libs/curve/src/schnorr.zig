// SPDX-License-Identifier: MIT OR Apache-2.0

//! Schnorr signature type.
//!
//! A Schnorr signature is a pair (R, z) where R is a nonce commitment
//! (group element) and z is the response scalar.
//!
//! Generic over any point type that supports `add`, `scalarMul`, `eql`.

const std = @import("std");

/// Schnorr signature (R, z) over a curve point type.
pub fn SchnorrSignature(comptime Point: type, comptime Scalar: type) type {
    return struct {
        const Self = @This();

        /// The nonce commitment (group element)
        R: Point,
        /// The response scalar
        z: Scalar,

        /// Create a new signature.
        pub fn init(R: Point, z: Scalar) Self {
            return .{ .R = R, .z = z };
        }

        /// Verify signature: s*G == R + e*P where e = hash(R, P, msg).
        pub fn verify(self: Self, base: Point, public_key: Point, msg: []const u8) bool {
            const e = challenge(base, public_key, self.R, msg);
            const sG = base.scalarMul(self.z);
            const eP = public_key.scalarMul(e);
            return sG.eql(self.R.add(eP));
        }

        /// Compute Schnorr challenge: H(base, public_key, R, msg).
        pub fn challenge(base: Point, public_key: Point, R: Point, msg: []const u8) Scalar {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            // Hash base point
            hashPoint(&hasher, base);
            // Hash public key
            hashPoint(&hasher, public_key);
            // Hash nonce commitment
            hashPoint(&hasher, R);
            // Hash message
            hasher.update(msg);
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            return Scalar.fromBytes(digest) catch Scalar.zero();
        }

        fn hashPoint(hasher: anytype, p: Point) void {
            if (@hasDecl(Point, "toBytes")) {
                const bytes = p.toBytes();
                hasher.update(&bytes);
            } else if (@hasDecl(Point, "x") and @hasDecl(Point, "y")) {
                // Affine point: hash x and y coordinates
                const x_bytes = p.x.toBytes();
                const y_bytes = p.y.toBytes();
                hasher.update(&x_bytes);
                hasher.update(&y_bytes);
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Simple test field (mod 7) for testing.
const F7 = struct {
    value: u64,
    pub const MODULUS: u64 = 7;

    pub fn zero() @This() { return .{ .value = 0 }; }
    pub fn one() @This() { return .{ .value = 1 }; }
    pub fn fromInt(x: u64) @This() { return .{ .value = x % MODULUS }; }
    pub fn fromBytes(bytes: [32]u8) !@This() { return fromInt(bytes[31]); }
    pub fn toBytes(self: @This()) [32]u8 {
        var out: [32]u8 = std.mem.zeroes([32]u8);
        out[31] = @intCast(self.value);
        return out;
    }
    pub fn add(a: @This(), b: @This()) @This() { return fromInt(a.value + b.value); }
    pub fn sub(a: @This(), b: @This()) @This() { return fromInt((a.value + MODULUS - b.value) % MODULUS); }
    pub fn mul(a: @This(), b: @This()) @This() { return fromInt(a.value * b.value); }
    pub fn eql(a: @This(), b: @This()) bool { return a.value == b.value; }
    pub fn random() @This() { return fromInt(3); } // deterministic for testing
};

/// Simple test point for testing.
const TestPoint = struct {
    x: F7,
    y: F7,
    infinity: bool,

    pub fn zero() @This() { return .{ .x = F7.zero(), .y = F7.zero(), .infinity = true }; }
    pub fn eql(a: @This(), b: @This()) bool {
        if (a.infinity and b.infinity) return true;
        if (a.infinity or b.infinity) return false;
        return a.x.eql(b.x) and a.y.eql(b.y);
    }
    pub fn add(a: @This(), b: @This()) @This() {
        if (a.infinity) return b;
        if (b.infinity) return a;
        return .{ .x = a.x.add(b.x), .y = a.y.add(b.y), .infinity = false };
    }
    pub fn scalarMul(p: @This(), s: anytype) @This() {
        if (p.infinity) return p;
        const scalar_val = if (@typeInfo(@TypeOf(s)) == .@"struct") s.value else s;
        return .{
            .x = F7.fromInt(p.x.value * @as(u64, @intCast(scalar_val % 7))),
            .y = F7.fromInt(p.y.value * @as(u64, @intCast(scalar_val % 7))),
            .infinity = false,
        };
    }
};

test "Schnorr signature creation and verification" {
    const Sig = SchnorrSignature(TestPoint, F7);
    const G = TestPoint{ .x = F7.fromInt(1), .y = F7.fromInt(2), .infinity = false };

    // Simulate signing: private key x=3, public key P = x*G
    const x = F7.fromInt(3);
    const P = G.scalarMul(x);

    // Create signature manually (in real code, this would use random nonce)
    const k = F7.fromInt(2);
    const R = G.scalarMul(k);
    const e = Sig.challenge(G, P, R, "test message");
    const z = k.add(e.mul(x));

    const sig = Sig.init(R, z);

    // Verify
    try testing.expect(sig.verify(G, P, "test message"));
    try testing.expect(!sig.verify(G, P, "wrong message"));
}
