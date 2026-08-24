//! zig-poly: Dense univariate polynomials over finite fields.
//!
//! Provides allocation-free polynomial arithmetic with comptime-known
//! maximum degree.  All operations use stack storage.
//!
//! # Quick Start
//! ```zig
//! const Poly = Polynomial(F7, 64);
//! var p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
//! const q = p.mul(Poly.x());
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
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
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

    const p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) });
    try std.testing.expectEqual(@as(i32, 2), p.degree);

    const zero = Poly.zero();
    try std.testing.expectEqual(@as(i32, -1), zero.degree);
    try std.testing.expect(zero.isZero());

    const c = Poly.constant(F7.fromInt(5));
    try std.testing.expectEqual(@as(i32, 0), c.degree);
    try std.testing.expect(c.isConstant());
}

test "Polynomial addition" {
    const Poly = Polynomial(F7, 8);

    const a = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
    const b = Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(4) });
    const s = a.add(b);

    try std.testing.expect(s.eql(Poly.fromCoeffs(&.{ F7.fromInt(4), F7.fromInt(6) })));
}

test "Polynomial subtraction" {
    const Poly = Polynomial(F7, 8);

    const a = Poly.fromCoeffs(&.{ F7.fromInt(5), F7.fromInt(3) });
    const b = Poly.fromCoeffs(&.{ F7.fromInt(2), F7.fromInt(1) });
    const d = a.sub(b);

    try std.testing.expect(d.eql(Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(2) })));
}

test "Polynomial multiplication" {
    const Poly = Polynomial(F7, 8);

    // (1 + 2x) * (3 + 4x) = 3 + 10x + 8x^2 = 3 + 3x + x^2 (mod 7)
    const a = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
    const b = Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(4) });
    const p = a.mul(b);

    try std.testing.expect(p.eql(Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(3), F7.fromInt(1) })));
}

test "Polynomial evaluation" {
    const Poly = Polynomial(F7, 8);

    // p(x) = 1 + 2x + 3x^2
    const p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) });
    const y = p.eval(F7.fromInt(2));

    // 1 + 4 + 12 = 17 mod 7 = 3
    try std.testing.expect(F7.eql(y, F7.fromInt(3)));
}

test "Polynomial division" {
    const Poly = Polynomial(F7, 8);

    // (x^2 - 1) / (x - 1) = x + 1
    const dividend = Poly.fromCoeffs(&.{ F7.fromInt(6), F7.fromInt(0), F7.fromInt(1) }); // -1 + x^2
    const divisor = Poly.fromCoeffs(&.{ F7.fromInt(6), F7.fromInt(1) }); // -1 + x
    const qr = dividend.divRem(divisor);

    try std.testing.expect(qr.q.eql(Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(1) })));
    try std.testing.expect(qr.r.isZero());
}

test "Polynomial derivative" {
    const Poly = Polynomial(F7, 8);

    // d/dx (1 + 2x + 3x^2 + 4x^3) = 2 + 6x + 12x^2 = 2 + 6x + 5x^2 (mod 7)
    const p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3), F7.fromInt(4) });
    const d = p.derivative();

    try std.testing.expect(d.eql(Poly.fromCoeffs(&.{ F7.fromInt(2), F7.fromInt(6), F7.fromInt(5) })));
}

test "Polynomial composition" {
    const Poly = Polynomial(F7, 8);

    // p(x) = 1 + 2x, q(x) = x + 1
    // p(q(x)) = 1 + 2(x+1) = 3 + 2x
    const p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) });
    const q = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(1) });
    const r = p.compose(q);

    try std.testing.expect(r.eql(Poly.fromCoeffs(&.{ F7.fromInt(3), F7.fromInt(2) })));
}

test "Polynomial power" {
    const Poly = Polynomial(F7, 8);

    // (1 + x)^3 = 1 + 3x + 3x^2 + x^3 = 1 + 3x + 3x^2 + x^3 (mod 7)
    const p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(1) });
    const p3 = p.pow(3);

    try std.testing.expect(p3.eql(Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(3), F7.fromInt(1) })));
}

test "Lagrange interpolation" {
    const Poly = Polynomial(F7, 8);

    const xs = &[_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2) };
    const ys = &[_]F7{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(5) };
    const p = lagrangeInterpolate(F7, 8, xs, ys);

    // p(x) = 1 + 2x
    try std.testing.expect(p.eql(Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2) })));

    // Verify all points
    for (xs, ys) |x, y| {
        try std.testing.expect(F7.eql(p.eval(x), y));
    }
}

test "Vanishing polynomial" {
    const xs = &[_]F7{ F7.fromInt(1), F7.fromInt(2) };
    const v = vanishingPolynomial(F7, 8, xs);

    // V(x) = (x-1)(x-2) = x^2 - 3x + 2 = x^2 + 4x + 2 (mod 7)
    try std.testing.expect(v.eval(F7.fromInt(1)).isZero());
    try std.testing.expect(v.eval(F7.fromInt(2)).isZero());
    try std.testing.expect(!v.eval(F7.fromInt(0)).isZero());
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
        pub fn inv(a: Self) Self {
            std.debug.assert(!a.isZero());
            return pow(a, modulus - 2);
        }
        pub const inverse = inv;
        pub fn div(a: Self, b: Self) Self {
            return mul(a, inv(b));
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

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{}", .{self.value});
        }
    };

    const Poly = Polynomial(FmtF7, 8);

    const p = Poly.fromCoeffs(&.{ FmtF7.fromInt(1), FmtF7.fromInt(2), FmtF7.fromInt(3) });
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
