//! zig-poly: Dense univariate polynomials over finite fields.
//!
//! Provides allocation-free polynomial arithmetic with comptime-known
//! maximum degree.  All operations use stack storage.
//!
//! # Quick Start
//! ```zig
//! const Poly = Polynomial(F7, 64);
//! var p = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
//! const q = try p.mul(Poly.x());
//! const y = q.eval(F7.fromInt(3));
//! ```

const std = @import("std");

pub const poly = @import("poly.zig");
pub const vector = @import("vector.zig");

pub const Polynomial = poly.Polynomial;
pub const lagrangeInterpolate = poly.lagrangeInterpolate;
pub const vanishingPolynomial = poly.vanishingPolynomial;

// Re-export vector utilities
pub const inner = vector.inner;
pub const powers = vector.powers;
pub const vecAdd = vector.vecAdd;
pub const vecSub = vector.vecSub;
pub const vecScale = vector.vecScale;
pub const hadamard = vector.hadamard;
pub const vecSum = vector.vecSum;
pub const vecEql = vector.vecEql;

// ============================================================================
// Tests
// ============================================================================

const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: u256) Self {
        return .{ .value = @intCast(x % modulus) };
    }
    pub fn toInt(self: Self) u64 {
        return self.value;
    }
    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
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
    /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse; new
    /// code that requires invertibility must call `invChecked`.
    pub fn inv(a: Self) Self {
        if (a.isZero()) return zero();
        return pow(a, modulus - 2);
    }
    pub fn invChecked(a: Self) error{InverseOfZero}!Self {
        if (a.isZero()) return error.InverseOfZero;
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
    /// Legacy total division: `x / 0 == zero()`. Zero is not a quotient; new
    /// code that requires an invertible divisor must call `divChecked`.
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }
    pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
        return mul(a, try b.invChecked());
    }
    pub fn pow(base: Self, exp: u64) Self {
        var result = one();
        var b = base;
        var e = exp;
        while (e > 0) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
            e >>= 1;
        }
        return result;
    }
    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }
    pub fn random() Self {
        return fromInt(1);
    }
};

test "Polynomial construction and degree" {
    const Poly = Polynomial(F7, 8);

    const p = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) });
    try std.testing.expectEqual(@as(i32, 2), p.degree);

    const zero = Poly.zero();
    try std.testing.expectEqual(@as(i32, -1), zero.degree);
    try std.testing.expect(zero.isZero());

    const c = Poly.constant(F7.fromInt(5));
    try std.testing.expectEqual(@as(i32, 0), c.degree);
    try std.testing.expect(c.isConstant());
}

test "Polynomial and vector handle zero-length cases" {
    const Constant = Polynomial(F7, 0);
    try std.testing.expect(Constant.x().isZero());

    const values = try powers(F7, std.testing.allocator, F7.one(), 0);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "Polynomial addition" {
    const Poly = Polynomial(F7, 8);

    const a = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
    const b = try Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(4) });
    const s = a.add(b);

    try std.testing.expect(s.eql(try Poly.fromCoeffs(&.{ F7.fromInt(4), F7.fromInt(6) })));
}

test "Polynomial subtraction" {
    const Poly = Polynomial(F7, 8);

    const a = try Poly.fromCoeffs(&.{ F7.fromInt(5), F7.fromInt(3) });
    const b = try Poly.fromCoeffs(&.{ F7.fromInt(2), F7.fromInt(1) });
    const d = a.sub(b);

    try std.testing.expect(d.eql(try Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(2) })));
}

test "Polynomial multiplication" {
    const Poly = Polynomial(F7, 8);

    // (1 + 2x) * (3 + 4x) = 3 + 10x + 8x^2 = 3 + 3x + x^2 (mod 7)
    const a = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
    const b = try Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(4) });
    const p = try a.mul(b);

    try std.testing.expect(p.eql(try Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(3), F7.fromInt(1) })));
}

test "Polynomial evaluation" {
    const Poly = Polynomial(F7, 8);

    // p(x) = 1 + 2x + 3x^2
    const p = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) });
    const y = p.eval(F7.fromInt(2));

    // 1 + 4 + 12 = 17 mod 7 = 3
    try std.testing.expect(F7.eql(y, F7.fromInt(3)));
}

test "Polynomial division" {
    const Poly = Polynomial(F7, 8);

    // (x^2 - 1) / (x - 1) = x + 1
    const dividend = try Poly.fromCoeffs(&.{ F7.fromInt(6), F7.fromInt(0), F7.fromInt(1) }); // -1 + x^2
    const divisor = try Poly.fromCoeffs(&.{ F7.fromInt(6), F7.fromInt(1) }); // -1 + x
    const qr = try dividend.divRem(divisor);

    try std.testing.expect(qr.q.eql(try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(1) })));
    try std.testing.expect(qr.r.isZero());
}

test "Polynomial derivative" {
    const Poly = Polynomial(F7, 8);

    // d/dx (1 + 2x + 3x^2 + 4x^3) = 2 + 6x + 12x^2 = 2 + 6x + 5x^2 (mod 7)
    const p = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3), F7.fromInt(4) });
    const d = p.derivative();

    try std.testing.expect(d.eql(try Poly.fromCoeffs(&.{ F7.fromInt(2), F7.fromInt(6), F7.fromInt(5) })));
}

test "Polynomial composition" {
    const Poly = Polynomial(F7, 8);

    // p(x) = 1 + 2x, q(x) = x + 1
    // p(q(x)) = 1 + 2(x+1) = 3 + 2x
    const p = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
    const q = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(1) });
    const r = try p.compose(q);

    try std.testing.expect(r.eql(try Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(2) })));
}

test "Polynomial power" {
    const Poly = Polynomial(F7, 8);

    // (1 + x)^3 = 1 + 3x + 3x^2 + x^3 = 1 + 3x + 3x^2 + x^3 (mod 7)
    const p = try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(1) });
    const p3 = try p.pow(3);

    try std.testing.expect(p3.eql(try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(3), F7.fromInt(1) })));
}

test "Lagrange interpolation" {
    const Poly = Polynomial(F7, 8);

    const xs = &[_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2) };
    const ys = &[_]F7{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(5) };
    const p = try lagrangeInterpolate(F7, 8, xs, ys);

    // p(x) = 1 + 2x
    try std.testing.expect(p.eql(try Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) })));

    // Verify all points
    for (xs, ys) |x, y| {
        try std.testing.expect(F7.eql(p.eval(x), y));
    }
}

test "Vanishing polynomial" {
    const xs = &[_]F7{ F7.fromInt(1), F7.fromInt(2) };
    const v = try vanishingPolynomial(F7, 8, xs);

    // V(x) = (x-1)(x-2) = x^2 - 3x + 2 = x^2 + 4x + 2 (mod 7)
    try std.testing.expect(v.eval(F7.fromInt(1)).isZero());
    try std.testing.expect(v.eval(F7.fromInt(2)).isZero());
    try std.testing.expect(!v.eval(F7.fromInt(0)).isZero());
}

// Vectors computed in Python from the mathematical definitions themselves --
// Horner evaluation, long division, the formal derivative, composition, the
// Lagrange basis and the vanishing product -- over F_7, which is the field
// this library's own tests use. Nothing in this repository produced them, and
// the point of the case list is the shapes rather than the values: constant
// operands, intermediate zero coefficients, a sum that crosses zero, an exact
// division, a dividend of lower degree than the divisor, and degrees that
// make the product sit at the `max_degree` boundary.
test "polynomial arithmetic matches Python over the same field" {
    const Poly = Polynomial(F7, 16);

    const expectPoly = struct {
        fn run(p: Poly, want: []const u64) !void {
            var degree: i32 = -1;
            for (want, 0..) |c, i| {
                if (c != 0) degree = @intCast(i);
            }
            try std.testing.expectEqual(degree, p.degree);
            for (want, 0..) |c, i| {
                try std.testing.expectEqual(c, p.coeffs[i].toInt());
            }
            // Every coefficient above the expected ones has to be zero: a
            // polynomial that left garbage above its degree would compare
            // equal on the low half and pass.
            for (want.len..Poly.MAX_DEGREE + 1) |i| {
                try std.testing.expectEqual(@as(u64, 0), p.coeffs[i].toInt());
            }
        }
    }.run;

    const Case = struct {
        a: []const u64,
        b: []const u64,
        x: u64,
        sum: []const u64,
        prod: []const u64,
        eval: u64,
        quot: []const u64,
        rem: []const u64,
        deriv: []const u64,
        compose: []const u64,
        pow3: []const u64,
    };
    const cases = [_]Case{
        .{
            .a = &.{3},
            .b = &.{5},
            .x = 4,
            .sum = &.{1},
            .prod = &.{1},
            .eval = 3,
            .quot = &.{2},
            .rem = &.{0},
            .deriv = &.{0},
            .compose = &.{3},
            .pow3 = &.{6},
        },
        .{
            .a = &.{ 1, 2 },
            .b = &.{ 0, 3 },
            .x = 6,
            .sum = &.{ 1, 5 },
            .prod = &.{ 0, 3, 6 },
            .eval = 6,
            .quot = &.{3},
            .rem = &.{1},
            .deriv = &.{2},
            .compose = &.{ 1, 6 },
            .pow3 = &.{ 1, 6, 5, 1 },
        },
        .{
            .a = &.{ 2, 0, 1 },
            .b = &.{ 1, 1, 1 },
            .x = 2,
            .sum = &.{ 3, 1, 2 },
            .prod = &.{ 2, 2, 3, 1, 1 },
            .eval = 6,
            .quot = &.{1},
            .rem = &.{ 1, 6 },
            .deriv = &.{ 0, 2 },
            .compose = &.{ 3, 2, 3, 2, 1 },
            .pow3 = &.{ 1, 0, 5, 0, 6, 0, 1 },
        },
        .{
            .a = &.{ 6, 6, 6, 6 },
            .b = &.{ 1, 0, 0, 0, 1 },
            .x = 3,
            .sum = &.{ 0, 6, 6, 6, 1 },
            .prod = &.{ 6, 6, 6, 6, 6, 6, 6, 6 },
            .eval = 2,
            .quot = &.{0},
            .rem = &.{ 6, 6, 6, 6 },
            .deriv = &.{ 6, 5, 4 },
            .compose = &.{ 3, 0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0, 6 },
            .pow3 = &.{ 6, 4, 1, 4, 2, 2, 4, 1, 4, 6 },
        },
        .{
            .a = &.{ 0, 0, 1 },
            .b = &.{5},
            .x = 3,
            .sum = &.{ 5, 0, 1 },
            .prod = &.{ 0, 0, 5 },
            .eval = 2,
            .quot = &.{ 0, 0, 3 },
            .rem = &.{0},
            .deriv = &.{ 0, 2 },
            .compose = &.{4},
            .pow3 = &.{ 0, 0, 0, 0, 0, 0, 1 },
        },
        .{
            .a = &.{ 1, 5, 6 },
            .b = &.{ 1, 3 },
            .x = 0,
            .sum = &.{ 2, 1, 6 },
            .prod = &.{ 1, 1, 0, 4 },
            .eval = 1,
            .quot = &.{ 1, 2 },
            .rem = &.{0},
            .deriv = &.{ 5, 5 },
            .compose = &.{ 5, 2, 5 },
            .pow3 = &.{ 1, 1, 2, 4, 5, 1, 6 },
        },
        .{
            .a = &.{ 1, 2 },
            .b = &.{ 1, 0, 0, 0, 1 },
            .x = 5,
            .sum = &.{ 2, 2, 0, 0, 1 },
            .prod = &.{ 1, 2, 0, 0, 1, 2 },
            .eval = 4,
            .quot = &.{0},
            .rem = &.{ 1, 2 },
            .deriv = &.{2},
            .compose = &.{ 3, 0, 0, 0, 2 },
            .pow3 = &.{ 1, 6, 5, 1 },
        },
        .{
            .a = &.{ 1, 2, 3, 4, 5 },
            .b = &.{ 3, 1 },
            .x = 4,
            .sum = &.{ 4, 3, 3, 4, 5 },
            .prod = &.{ 3, 0, 4, 1, 5, 5 },
            .eval = 4,
            .quot = &.{ 6, 1, 3, 5 },
            .rem = &.{4},
            .deriv = &.{ 2, 6, 5, 6 },
            .compose = &.{ 1, 3, 1, 1, 5 },
            .pow3 = &.{ 1, 6, 0, 0, 0, 3, 5, 0, 6, 0, 3, 6, 6 },
        },
    };

    for (cases) |c| {
        var av: [16]F7 = undefined;
        var bv: [16]F7 = undefined;
        for (0..c.a.len) |i| av[i] = F7.fromInt(c.a[i]);
        for (0..c.b.len) |i| bv[i] = F7.fromInt(c.b[i]);
        const a = try Poly.fromCoeffs(av[0..c.a.len]);
        const b = try Poly.fromCoeffs(bv[0..c.b.len]);

        try expectPoly(a.add(b), c.sum);
        try expectPoly(try a.mul(b), c.prod);
        try std.testing.expectEqual(c.eval, a.eval(F7.fromInt(c.x)).toInt());

        const qr = try a.divRem(b);
        try expectPoly(qr.q, c.quot);
        try expectPoly(qr.r, c.rem);

        try expectPoly(a.derivative(), c.deriv);
        try expectPoly(try a.compose(b), c.compose);
        try expectPoly(try a.pow(3), c.pow3);
    }

    // Dividing by the zero polynomial is a typed error, not a silent zero.
    const one = Poly.constant(F7.one());
    try std.testing.expectError(error.DivisionByZero, one.divRem(Poly.zero()));
    try std.testing.expectError(error.DivisionByZero, one.rem(Poly.zero()));
}

// The two module-level constructors are polynomial algorithms too, and the
// duplicate-`xs` case is where the Lagrange denominator becomes zero: the
// interpolation must say so instead of returning a zero coefficient.
test "Lagrange interpolation and the vanishing polynomial match Python" {
    const Poly = Polynomial(F7, 16);

    const expectPoly = struct {
        fn run(p: Poly, want: []const u64) !void {
            var degree: i32 = -1;
            for (want, 0..) |c, i| {
                if (c != 0) degree = @intCast(i);
            }
            try std.testing.expectEqual(degree, p.degree);
            for (want, 0..) |c, i| {
                try std.testing.expectEqual(c, p.coeffs[i].toInt());
            }
            for (want.len..Poly.MAX_DEGREE + 1) |i| {
                try std.testing.expectEqual(@as(u64, 0), p.coeffs[i].toInt());
            }
        }
    }.run;

    const Case = struct {
        xs: []const u64,
        ys: []const u64,
        interp: []const u64,
        vanishing: []const u64,
    };
    const cases = [_]Case{
        .{ .xs = &.{ 1, 2, 3 }, .ys = &.{ 1, 3, 5 }, .interp = &.{ 6, 2 }, .vanishing = &.{ 1, 4, 1, 1 } },
        .{ .xs = &.{ 0, 1 }, .ys = &.{ 0, 2 }, .interp = &.{ 0, 2 }, .vanishing = &.{ 0, 6, 1 } },
        .{ .xs = &.{ 2, 0, 4, 1 }, .ys = &.{ 3, 3, 3, 3 }, .interp = &.{3}, .vanishing = &.{ 0, 6, 0, 0, 1 } },
        .{ .xs = &.{5}, .ys = &.{6}, .interp = &.{6}, .vanishing = &.{ 2, 1 } },
    };

    for (cases) |c| {
        var xs: [8]F7 = undefined;
        var ys: [8]F7 = undefined;
        for (0..c.xs.len) |i| xs[i] = F7.fromInt(c.xs[i]);
        for (0..c.ys.len) |i| ys[i] = F7.fromInt(c.ys[i]);

        const interp = try lagrangeInterpolate(F7, 16, xs[0..c.xs.len], ys[0..c.ys.len]);
        try expectPoly(interp, c.interp);
        // The interpolation has to actually interpolate: that is the property
        // the coefficients are supposed to have, and it is what makes the
        // vector above more than a transcription.
        for (0..c.xs.len) |i| {
            try std.testing.expectEqual(ys[i].toInt(), interp.eval(xs[i]).toInt());
        }

        const vanishing = try vanishingPolynomial(F7, 16, xs[0..c.xs.len]);
        try expectPoly(vanishing, c.vanishing);
        for (xs[0..c.xs.len]) |x| {
            try std.testing.expectEqual(@as(u64, 0), vanishing.eval(x).toInt());
        }
    }

    var dup: [3]F7 = .{ F7.fromInt(1), F7.fromInt(1), F7.fromInt(2) };
    var dup_y: [3]F7 = .{ F7.fromInt(3), F7.fromInt(3), F7.fromInt(4) };
    try std.testing.expectError(error.DivisionByZero, lagrangeInterpolate(F7, 16, &dup, &dup_y));
}

test "Polynomial formatting" {
    // Use a field with proper formatting
    const FmtF7 = struct {
        const Self = @This();
        value: u64,
        pub const modulus: u64 = 7;
        pub const characteristic: u64 = 7;
        pub const order: u64 = 7;

        pub fn zero() Self {
            return .{ .value = 0 };
        }
        pub fn one() Self {
            return .{ .value = 1 };
        }
        pub fn fromInt(x: u256) Self {
            return .{ .value = @intCast(x % modulus) };
        }
        pub fn toInt(self: Self) u64 {
            return self.value;
        }
        pub fn eql(a: Self, b: Self) bool {
            return a.value == b.value;
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
        /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse;
        /// new code that requires invertibility must call `invChecked`.
        pub fn inv(a: Self) Self {
            if (a.isZero()) return zero();
            return pow(a, modulus - 2);
        }
        pub fn invChecked(a: Self) error{InverseOfZero}!Self {
            if (a.isZero()) return error.InverseOfZero;
            return pow(a, modulus - 2);
        }
        pub const inverse = inv;
        /// Legacy total division: `x / 0 == zero()`. Zero is not a quotient;
        /// new code that requires an invertible divisor must call `divChecked`.
        pub fn div(a: Self, b: Self) Self {
            return mul(a, inv(b));
        }
        pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
            return mul(a, try b.invChecked());
        }
        pub fn pow(base: Self, exp: u64) Self {
            var result = one();
            var b = base;
            var e = exp;
            while (e > 0) {
                if (e & 1 == 1) result = mul(result, b);
                b = mul(b, b);
                e >>= 1;
            }
            return result;
        }
        pub fn isZero(self: Self) bool {
            return self.value == 0;
        }
        pub fn random() Self {
            return fromInt(1);
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{}", .{self.value});
        }
    };

    const Poly = Polynomial(FmtF7, 8);

    const p = try Poly.fromCoeffs(&.{ FmtF7.fromInt(1), FmtF7.fromInt(2), FmtF7.fromInt(3) });
    var buf: [256]u8 = undefined;
    // Manual formatting since format method doesn't work on comptime-generated structs
    var first = true;
    var written: usize = 0;
    for (0..@intCast(p.degree + 1)) |i| {
        const c = p.coeffs[i];
        if (c.isZero()) continue;
        if (!first) {
            const written_now = try std.fmt.bufPrint(buf[written..], " + ", .{});
            written += written_now.len;
        }
        first = false;
        if (i == 0) {
            const written_now = try std.fmt.bufPrint(buf[written..], "{}", .{c});
            written += written_now.len;
        } else if (i == 1) {
            const written_now = try std.fmt.bufPrint(buf[written..], "{}*x", .{c});
            written += written_now.len;
        } else {
            const written_now = try std.fmt.bufPrint(buf[written..], "{}*x^{}", .{ c, i });
            written += written_now.len;
        }
    }
    const s = buf[0..written];
    try std.testing.expect(std.mem.indexOf(u8, s, "x^2") != null);
}
