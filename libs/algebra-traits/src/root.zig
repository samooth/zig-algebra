//! zig-algebra-traits
//!
//! Contratos de tipo (traits) para álgebra computacional en Zig.
//! Fundamento del ecosistema zig-algebra-core.

pub const traits = @import("traits.zig");

const std = @import("std");

// Re-export all trait functions for convenience
pub const AlgebraError = traits.AlgebraError;
pub const SetTrait = traits.SetTrait;
pub const GroupTrait = traits.GroupTrait;
pub const AdditiveGroupTrait = traits.AdditiveGroupTrait;
pub const MultiplicativeGroupTrait = traits.MultiplicativeGroupTrait;
pub const RingTrait = traits.RingTrait;
pub const FieldTrait = traits.FieldTrait;
pub const PrimeFieldTrait = traits.PrimeFieldTrait;
pub const FieldExtensionTrait = traits.FieldExtensionTrait;
pub const VectorSpaceTrait = traits.VectorSpaceTrait;
pub const PolynomialRingTrait = traits.PolynomialRingTrait;
pub const EllipticCurveTrait = traits.EllipticCurveTrait;
pub const PairingFriendlyTrait = traits.PairingFriendlyTrait;
pub const CommitmentSchemeTrait = traits.CommitmentSchemeTrait;
pub const NttTrait = traits.NttTrait;
pub const HashToFieldTrait = traits.HashToFieldTrait;
pub const HashToCurveTrait = traits.HashToCurveTrait;
pub const MerkleTreeTrait = traits.MerkleTreeTrait;
pub const TranscriptTrait = traits.TranscriptTrait;
pub const FieldRngTrait = traits.FieldRngTrait;

// Re-export assertion helpers
pub const assertField = traits.assertField;
pub const assertRing = traits.assertRing;
pub const assertGroup = traits.assertGroup;
pub const assertEllipticCurve = traits.assertEllipticCurve;
pub const assertPairingFriendly = traits.assertPairingFriendly;

// Re-export generic algorithms
pub const pow = traits.pow;
pub const sum = traits.sum;
pub const product = traits.product;
pub const egcd = traits.egcd;
pub const dotProduct = traits.dotProduct;
pub const evalPolyHorner = traits.evalPolyHorner;
pub const lagrangeInterpolate = traits.lagrangeInterpolate;
pub const lagrangeCoefficient = traits.lagrangeCoefficient;

const testing = std.testing;

const TestF7 = struct {
    const Self = @This();
    value: u64,
    const modulus: u64 = 7;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: anytype) Self {
        return .{ .value = @intCast(@as(u64, @intCast(x)) % modulus) };
    }
    pub fn add(a: Self, b: Self) Self {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value + (modulus - b.value % modulus));
    }
    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(modulus - a.value);
    }
    pub fn mul(a: Self, b: Self) Self {
        return fromInt(a.value * b.value);
    }
    pub fn inv(a: Self) Self {
        if (a.isZero()) return zero();
        return Self.pow(a, modulus - 2);
    }
    pub fn pow(base: Self, e: u64) Self {
        var result = Self.one();
        var b = base;
        var exp = e;
        while (exp > 0) : (exp >>= 1) {
            if (exp & 1 == 1) result = Self.mul(result, b);
            b = Self.mul(b, b);
        }
        return result;
    }
    pub fn invChecked(a: Self) error{InverseOfZero}!Self {
        if (a.isZero()) return error.InverseOfZero;
        return inv(a);
    }
    pub fn inverse(a: Self) Self {
        return inv(a);
    }
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }
    pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
        return mul(a, try b.invChecked());
    }
    pub fn isZero(a: Self) bool {
        return a.value == 0;
    }
    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    /// Trivial vector-space structure: the field is a 1-dimensional space over
    /// itself, so scaling is multiplication.
    pub fn scale(s: Self, v: Self) Self {
        return mul(s, v);
    }
    pub const dimension: usize = 1;
};

test "dotProduct rejects a length mismatch instead of reading out of bounds" {
    const a = [_]TestF7{ TestF7.fromInt(1), TestF7.fromInt(2) };
    const b = [_]TestF7{TestF7.fromInt(3)};
    try testing.expectError(error.LengthMismatch, dotProduct(TestF7, TestF7, &a, &b));
}

test "lagrangeCoefficient rejects an out-of-range index" {
    const xs = [_]TestF7{ TestF7.fromInt(1), TestF7.fromInt(2) };
    try testing.expectError(error.IndexOutOfBounds, lagrangeCoefficient(TestF7, &xs, 2, TestF7.fromInt(3)));
}

test "lagrangeInterpolate rejects mismatched xs/ys" {
    const xs = [_]TestF7{ TestF7.fromInt(0), TestF7.fromInt(1) };
    const ys = [_]TestF7{TestF7.fromInt(1)};
    try testing.expectError(error.LengthMismatch, lagrangeInterpolate(TestF7, &xs, &ys, testing.allocator));
}

test "lagrangeCoefficient satisfies the partition of unity on distinct xs" {
    const xs = [_]TestF7{ TestF7.fromInt(0), TestF7.fromInt(1), TestF7.fromInt(2) };
    for ([_]u64{ 3, 4, 5 }) |pt| {
        var total = TestF7.zero();
        for (0..xs.len) |i| {
            total = TestF7.add(total, try lagrangeCoefficient(TestF7, &xs, i, TestF7.fromInt(pt)));
        }
        try testing.expect(total.eql(TestF7.one()));
    }
}
