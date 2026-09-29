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

// The expected values come from the definitions in Python over F_7 --
// λ_i(x) = Π_{j≠i}(x − x_j) / Π_{j≠i}(x_i − x_j), the dot product, and the
// Lagrange basis built by multiplying the linear factors -- so this is a second
// implementation rather than a transcription of whatever these functions
// print. The coefficient vectors include a single point, points containing
// zero, and the identity point x ∈ xs.
test "Lagrange coefficients, dot products and interpolation match Python over F_7" {
    const Coef = struct { xs: []const u64, i: usize, x: u64, want: u64 };
    const coef_cases = [_]Coef{
        .{ .xs = &.{ 1, 2, 3 }, .i = 0, .x = 0, .want = 3 },
        .{ .xs = &.{ 1, 2, 3 }, .i = 1, .x = 0, .want = 4 },
        .{ .xs = &.{ 1, 2, 3 }, .i = 2, .x = 4, .want = 3 },
        .{ .xs = &.{ 0, 1, 4, 9 }, .i = 3, .x = 2, .want = 1 },
        .{ .xs = &.{2}, .i = 0, .x = 5, .want = 1 },
        .{ .xs = &.{ 1, 2, 3, 4 }, .i = 1, .x = 6, .want = 1 },
    };
    for (coef_cases) |c| {
        var xs: [4]TestF7 = undefined;
        for (0..c.xs.len) |i| xs[i] = TestF7.fromInt(c.xs[i]);
        const got = try lagrangeCoefficient(TestF7, xs[0..c.xs.len], c.i, TestF7.fromInt(c.x));
        try testing.expectEqual(c.want, got.value);
    }

    const Dot = struct { a: []const u64, b: []const u64, want: u64 };
    const dot_cases = [_]Dot{
        .{ .a = &.{ 1, 2, 3 }, .b = &.{ 4, 5, 6 }, .want = 4 },
        .{ .a = &.{6}, .b = &.{6}, .want = 1 },
        .{ .a = &.{ 0, 1, 2, 3 }, .b = &.{ 3, 2, 1, 0 }, .want = 4 },
    };
    for (dot_cases) |c| {
        var a: [4]TestF7 = undefined;
        var b: [4]TestF7 = undefined;
        for (0..c.a.len) |i| a[i] = TestF7.fromInt(c.a[i]);
        for (0..c.b.len) |i| b[i] = TestF7.fromInt(c.b[i]);
        const got = try dotProduct(TestF7, TestF7, a[0..c.a.len], b[0..c.b.len]);
        try testing.expectEqual(c.want, got.value);
    }

    const Lag = struct { xs: []const u64, ys: []const u64, coeffs: []const u64 };
    const lag_cases = [_]Lag{
        .{ .xs = &.{ 1, 2, 3 }, .ys = &.{ 1, 3, 5 }, .coeffs = &.{ 6, 2 } },
        .{ .xs = &.{ 0, 1, 2 }, .ys = &.{ 4, 5, 6 }, .coeffs = &.{ 4, 1 } },
        .{ .xs = &.{ 2, 5, 1, 6 }, .ys = &.{ 3, 0, 4, 1 }, .coeffs = &.{ 4, 0, 2, 5 } },
    };
    for (lag_cases) |c| {
        var xs: [4]TestF7 = undefined;
        var ys: [4]TestF7 = undefined;
        for (0..c.xs.len) |i| xs[i] = TestF7.fromInt(c.xs[i]);
        for (0..c.ys.len) |i| ys[i] = TestF7.fromInt(c.ys[i]);
        const coeffs = try lagrangeInterpolate(TestF7, xs[0..c.xs.len], ys[0..c.ys.len], testing.allocator);
        defer testing.allocator.free(coeffs);
        // The result always has one slot per point, so the polynomial the
        // Python side trimmed of its trailing zeros has to match the leading
        // coefficients and the rest has to be zero.
        try testing.expect(c.coeffs.len <= coeffs.len);
        for (coeffs, 0..) |v, i| {
            const want: u64 = if (i < c.coeffs.len) c.coeffs[i] else 0;
            try testing.expectEqual(want, v.value);
        }
    }
}

// Duplicated points make the denominator zero. The coefficient used to come
// back as a plausible zero, because it reached the total legacy `F.inv`; it is
// now a typed error, the same answer `poly.lagrangeInterpolate` has given since
// 0.3.0.
// The denominator vanishes exactly when the value being asked for is
// repeated. It used to come back as a plausible zero, because it reached the
// total legacy `F.inv`; it is now a typed error, the same answer
// `poly.lagrangeInterpolate` has given since 0.3.0.
test "lagrangeCoefficient rejects a repeated node instead of returning zero" {
    var dup: [3]TestF7 = .{ TestF7.fromInt(1), TestF7.fromInt(1), TestF7.fromInt(2) };
    try testing.expectError(error.DegenerateNodes, lagrangeCoefficient(TestF7, &dup, 0, TestF7.fromInt(3)));
    try testing.expectError(error.DegenerateNodes, lagrangeCoefficient(TestF7, &dup, 1, TestF7.fromInt(3)));

    // A duplicate that is not adjacent, and a duplicate away from the index
    // being asked for: the loop has to look at every pair, not just neighbours.
    var spread: [4]TestF7 = .{ TestF7.fromInt(5), TestF7.fromInt(1), TestF7.fromInt(6), TestF7.fromInt(5) };
    try testing.expectError(error.DegenerateNodes, lagrangeCoefficient(TestF7, &spread, 0, TestF7.fromInt(0)));
    try testing.expectError(error.DegenerateNodes, lagrangeCoefficient(TestF7, &spread, 3, TestF7.fromInt(0)));

    // The contract is narrower than "no duplicates anywhere", and the docstring
    // says so: a coefficient whose own value is unique is still well defined
    // even when some other value is repeated, because its denominator only
    // involves the pairs that include it. What such a set is *not* is a valid
    // Lagrange basis, and that is the caller's constraint.
    const unique = try lagrangeCoefficient(TestF7, &dup, 2, TestF7.fromInt(3));
    try testing.expectEqual(@as(u64, 4), unique.value); // (3-1)(3-1) / (2-1)(2-1) = 4
    const middle = try lagrangeCoefficient(TestF7, &spread, 1, TestF7.fromInt(0));
    try testing.expect(middle.value != 0);
}

// The interpolator refuses the same input, for the same reason.
test "lagrangeInterpolate rejects repeated nodes" {
    var xs: [3]TestF7 = .{ TestF7.fromInt(1), TestF7.fromInt(1), TestF7.fromInt(2) };
    var ys: [3]TestF7 = .{ TestF7.fromInt(3), TestF7.fromInt(3), TestF7.fromInt(4) };
    try testing.expectError(error.DegenerateNodes, lagrangeInterpolate(TestF7, &xs, &ys, testing.allocator));
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

test "invChecked rejects zero while inv stays total" {
    // Guards `invChecked`, and pins the pair's contract: the legacy `inv` is
    // total and propagates zero, the checked one errors. Written
    // mutation-first: with the guard made vacuous, the `expectError` below is
    // the only thing that fails.
    try testing.expectError(error.InverseOfZero, TestF7.invChecked(TestF7.zero()));
    try testing.expect(TestF7.inv(TestF7.zero()).isZero());

    // And a real inverse is still an inverse, so the guard is not simply
    // rejecting everything.
    const a = TestF7.fromInt(3);
    try testing.expect((try a.invChecked()).mul(a).eql(TestF7.one()));
    try testing.expect(TestF7.inverse(a).mul(a).eql(TestF7.one()));
}
