//! Dense univariate polynomials over a finite field.
//!
//! `Polynomial(F, max_degree)` stores coefficients in a fixed-size array
//! `coeffs[0..max_degree]` where `coeffs[i]` is the coefficient of x^i.
//! All operations are allocation-free and use stack storage only.
//!
//! # Quick Start
//! ```zig
//! const F = ...; // your field type
//! const Poly = Polynomial(F, 64);
//!
//! const p = try Poly.fromCoeffs(&.{ F.fromInt(1), F.fromInt(2), F.fromInt(1) });
//! // p(x) = 1 + 2x + x^2
//! const y = p.eval(F.fromInt(3)); // y = 1 + 6 + 9 = 16
//! ```

const std = @import("std");
const traits = @import("zig-algebra-traits");

/// Dense polynomial over field `F` with at most `max_degree + 1` coefficients.
///
/// # Type Parameters
/// - `F`: Field type satisfying `FieldTrait`.
/// - `max_degree`: Maximum degree; precision = `max_degree + 1` coefficients.
///
/// # Invariants
/// - `degree` is always accurate (leading coefficient is non-zero, or -1 for zero polynomial).
/// - All operations normalize the result automatically.
pub fn Polynomial(comptime F: type, comptime max_degree: usize) type {
    traits.assertField(F);

    return struct {
        const Self = @This();

        /// Coefficients: coeffs[i] = coefficient of x^i.
        coeffs: [max_degree + 1]F = std.mem.zeroes([max_degree + 1]F),
        /// Actual degree, or -1 for the zero polynomial.
        degree: i32 = -1,

        pub const MAX_DEGREE = max_degree;

        // ------------------------------------------------------------------
        // Constructors
        // ------------------------------------------------------------------

        /// Zero polynomial.
        pub fn zero() Self {
            return .{};
        }

        /// Constant polynomial `c`.
        pub fn constant(c: F) Self {
            var p = Self{};
            if (!c.isZero()) {
                p.coeffs[0] = c;
                p.degree = 0;
            }
            return p;
        }

        /// Polynomial `x` (the identity).
        pub fn x() Self {
            if (max_degree == 0) return Self.zero();
            var p = Self{};
            p.coeffs[1] = F.one();
            p.degree = 1;
            return p;
        }

        /// Build from a slice of coefficients `[c0, c1, c2, ...]`.
        ///
        /// # Errors
        /// `error.DegreeTooLarge` when `src.len > max_degree + 1`. The old
        /// `std.debug.assert` is compiled out in `ReleaseFast`, where the copy
        /// loop then wrote past the end of the fixed `coeffs` array.
        pub fn fromCoeffs(src: []const F) error{DegreeTooLarge}!Self {
            if (src.len > max_degree + 1) return error.DegreeTooLarge;
            var p = Self{};
            for (0..src.len) |i| {
                p.coeffs[i] = src[i];
            }
            p.normalize();
            return p;
        }

        /// Build from an array literal.
        ///
        /// The length is a comptime constant here, so an oversized literal is a
        /// compile error rather than a runtime error.
        pub fn fromArray(comptime src: []const F) Self {
            if (src.len > max_degree + 1) @compileError("Polynomial.fromArray: literal has " ++ std.fmt.comptimePrint("{d}", .{src.len}) ++ " coefficients, capacity is " ++ std.fmt.comptimePrint("{d}", .{max_degree + 1}));
            return fromCoeffs(src) catch unreachable;
        }

        // ------------------------------------------------------------------
        // Normalization & Predicates
        // ------------------------------------------------------------------

        /// Strip leading zero coefficients and update `degree`.
        pub fn normalize(self: *Self) void {
            var d: i32 = max_degree;
            while (d >= 0 and self.coeffs[@intCast(d)].isZero()) d -= 1;
            self.degree = d;
        }

        /// Return `true` if this is the zero polynomial.
        pub fn isZero(self: Self) bool {
            return self.degree < 0;
        }

        /// Return `true` if this is a constant polynomial.
        pub fn isConstant(self: Self) bool {
            return self.degree == 0;
        }

        /// Return the leading coefficient, or zero if the polynomial is zero.
        pub fn leadingCoeff(self: Self) F {
            if (self.degree < 0) return F.zero();
            return self.coeffs[@intCast(self.degree)];
        }

        // ------------------------------------------------------------------
        // Comparison
        // ------------------------------------------------------------------

        pub fn eql(self: Self, other: Self) bool {
            if (self.degree != other.degree) return false;
            if (self.degree < 0) return true;
            for (0..@intCast(self.degree + 1)) |i| {
                if (!F.eql(self.coeffs[i], other.coeffs[i])) return false;
            }
            return true;
        }

        // ------------------------------------------------------------------
        // Arithmetic
        // ------------------------------------------------------------------

        /// Polynomial addition.
        pub fn add(self: Self, other: Self) Self {
            var r = Self{};
            const d = @max(self.degree, other.degree);
            if (d < 0) return r;
            for (0..@intCast(d + 1)) |i| {
                const a = if (i <= self.degree) self.coeffs[i] else F.zero();
                const b = if (i <= other.degree) other.coeffs[i] else F.zero();
                r.coeffs[i] = F.add(a, b);
            }
            r.degree = d;
            r.normalize();
            return r;
        }

        /// Polynomial subtraction.
        pub fn sub(self: Self, other: Self) Self {
            var r = Self{};
            const d = @max(self.degree, other.degree);
            if (d < 0) return r;
            for (0..@intCast(d + 1)) |i| {
                const a = if (i <= self.degree) self.coeffs[i] else F.zero();
                const b = if (i <= other.degree) other.coeffs[i] else F.zero();
                r.coeffs[i] = F.sub(a, b);
            }
            r.degree = d;
            r.normalize();
            return r;
        }

        /// Negation.
        pub fn neg(self: Self) Self {
            var r = self;
            for (0..@intCast(self.degree + 1)) |i| {
                r.coeffs[i] = F.neg(r.coeffs[i]);
            }
            return r;
        }

        /// Scalar multiplication.
        pub fn scale(self: Self, s: F) Self {
            if (s.isZero()) return Self.zero();
            var r = self;
            for (0..@intCast(self.degree + 1)) |i| {
                r.coeffs[i] = F.mul(r.coeffs[i], s);
            }
            r.normalize();
            return r;
        }

        /// Polynomial multiplication (naive O(n*m)).
        ///
        /// # Errors
        /// `error.DegreeTooLarge` when the product degree exceeds `max_degree`.
        /// The old `std.debug.assert` is compiled out in `ReleaseFast`, where
        /// `r.coeffs[i + j]` then wrote past the end of the fixed array. Every
        /// operation that can exceed the capacity (including `compose`, `pow`,
        /// `lagrangeInterpolate` and `vanishingPolynomial`) propagates this.
        pub fn mul(self: Self, other: Self) error{DegreeTooLarge}!Self {
            if (self.isZero() or other.isZero()) return Self.zero();
            const d = self.degree + other.degree;
            if (d > max_degree) return error.DegreeTooLarge;

            var r = Self{};
            for (0..@intCast(self.degree + 1)) |i| {
                for (0..@intCast(other.degree + 1)) |j| {
                    const prod = F.mul(self.coeffs[i], other.coeffs[j]);
                    r.coeffs[i + j] = F.add(r.coeffs[i + j], prod);
                }
            }
            r.degree = @intCast(d);
            r.normalize();
            return r;
        }

        /// Evaluate at a point using Horner's method.
        pub fn eval(self: Self, point: F) F {
            if (self.degree < 0) return F.zero();
            var result = self.coeffs[@intCast(self.degree)];
            var i = self.degree;
            while (i > 0) {
                i -= 1;
                result = F.add(F.mul(result, point), self.coeffs[@intCast(i)]);
            }
            return result;
        }

        // ------------------------------------------------------------------
        // Division
        // ------------------------------------------------------------------

        /// Polynomial long division: returns `(quotient, remainder)`.
        ///
        /// # Errors
        /// `error.DivisionByZero` when `divisor` is the zero polynomial. The old
        /// `std.debug.assert` is compiled out in `ReleaseFast`, where the
        /// `while (remainder.degree >= divisor.degree)` loop then never made
        /// progress and `F.inv(0)` was used as a divisor.
        pub fn divRem(self: Self, divisor: Self) error{DivisionByZero}!struct { q: Self, r: Self } {
            if (divisor.isZero()) return error.DivisionByZero;
            if (self.isZero()) return .{ .q = Self.zero(), .r = Self.zero() };
            if (self.degree < divisor.degree) return .{ .q = Self.zero(), .r = self };

            var q = Self{};
            var remainder = self;
            const lead_div = divisor.leadingCoeff();
            const inv_lead = F.inv(lead_div);

            while (remainder.degree >= divisor.degree) {
                const diff = remainder.degree - divisor.degree;
                const coeff = F.mul(remainder.leadingCoeff(), inv_lead);
                q.coeffs[@as(usize, @intCast(diff))] = coeff;

                for (0..@as(usize, @intCast(divisor.degree + 1))) |i| {
                    const term = F.mul(divisor.coeffs[i], coeff);
                    remainder.coeffs[i + @as(usize, @intCast(diff))] = F.sub(remainder.coeffs[i + @as(usize, @intCast(diff))], term);
                }
                remainder.normalize();
            }

            q.degree = self.degree - divisor.degree;
            q.normalize();
            return .{ .q = q, .r = remainder };
        }

        /// Quotient only.
        pub fn div(self: Self, divisor: Self) error{DivisionByZero}!Self {
            return (try self.divRem(divisor)).q;
        }

        /// Remainder only.
        pub fn rem(self: Self, divisor: Self) error{DivisionByZero}!Self {
            return (try self.divRem(divisor)).r;
        }

        // ------------------------------------------------------------------
        // Derivative & Composition
        // ------------------------------------------------------------------

        /// Formal derivative: d/dx of a polynomial.
        pub fn derivative(self: Self) Self {
            if (self.degree <= 0) return Self.zero();
            var r = Self{};
            for (1..@intCast(self.degree + 1)) |i| {
                const coeff = F.fromInt(i);
                r.coeffs[i - 1] = F.mul(self.coeffs[i], coeff);
            }
            r.degree = self.degree - 1;
            r.normalize();
            return r;
        }

        /// Polynomial composition: `self(other(x))`.
        ///
        /// # Errors
        /// `error.DegreeTooLarge` when `deg(self) * deg(other)` exceeds
        /// `max_degree`, which is the normal case for general polynomials
        /// rather than an exceptional one.
        pub fn compose(self: Self, other: Self) error{DegreeTooLarge}!Self {
            if (self.isZero()) return Self.zero();
            var result = Self.constant(self.coeffs[0]);
            var power = other;
            for (1..@as(usize, @intCast(self.degree + 1))) |i| {
                if (!self.coeffs[i].isZero()) {
                    const term = power.scale(self.coeffs[i]);
                    result = result.add(term);
                }
                if (i < @as(usize, @intCast(self.degree))) {
                    power = try power.mul(other);
                }
            }
            return result;
        }

        // ------------------------------------------------------------------
        // Powers
        // ------------------------------------------------------------------

        /// Raise to a non-negative integer power.
        ///
        /// # Errors
        /// `error.DegreeTooLarge` when `deg(self) * exp` exceeds `max_degree`.
        pub fn pow(self: Self, exp: u32) error{DegreeTooLarge}!Self {
            if (exp == 0) return Self.constant(F.one());
            if (self.isZero()) return Self.zero();
            var result = Self.constant(F.one());
            var base = self;
            var e = exp;
            while (e > 0) {
                if (e & 1 == 1) result = try result.mul(base);
                e >>= 1;
                if (e > 0) base = try base.mul(base);
            }
            return result;
        }

        // ------------------------------------------------------------------
        // Formatting
        // ------------------------------------------------------------------

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.isZero()) {
                try writer.writeAll("0");
                return;
            }
            var first = true;
            for (0..@intCast(self.degree + 1)) |i| {
                const c = self.coeffs[i];
                if (c.isZero()) continue;
                if (!first) try writer.writeAll(" + ");
                first = false;
                if (i == 0) {
                    try writer.print("{}", .{c});
                } else if (i == 1) {
                    try writer.print("{}*x", .{c});
                } else {
                    try writer.print("{}*x^{}", .{ c, i });
                }
            }
        }

        /// Convert polynomial to string representation.
        ///
        /// Returns the number of bytes written into `buf`. Uses `{f}` so the
        /// custom `format` method above is used instead of the default struct
        /// dump (Zig 0.16 only consults a `format` method for `{f}`).
        pub fn toString(self: Self, buf: []u8) !usize {
            const out = try std.fmt.bufPrint(buf, "{f}", .{self});
            return out.len;
        }
    };
}

/// Lagrange interpolation: given distinct points `(xs[i], ys[i])`, return the
/// unique polynomial of degree `< n` that passes through them.
///
/// # Errors
/// - `error.LengthMismatch`: `xs.len != ys.len`. The old `std.debug.assert` is
///   compiled out in `ReleaseFast`, where the loop then read `ys[i]` out of
///   bounds.
/// - `error.EmptyInput`: `xs.len == 0` (the old `xs.len > 0` assert; the
///   `xs.len - 1` bound computation underflows on an empty slice).
/// - `error.DegreeTooLarge`: `xs.len - 1 > max_degree`.
/// - `error.DivisionByZero`: duplicate `xs[i]`, which makes the Lagrange
///   denominator zero. `F.inv` is the total legacy wrapper and would silently
///   return zero there.
///
/// # Example
/// ```zig
/// const xs = &.{ F.fromInt(0), F.fromInt(1), F.fromInt(2) };
/// const ys = &.{ F.fromInt(1), F.fromInt(3), F.fromInt(5) };
/// const p = try lagrangeInterpolate(F, 64, xs, ys); // p(x) = 1 + 2x
/// ```
pub fn lagrangeInterpolate(comptime F: type, comptime max_degree: usize, xs: []const F, ys: []const F) error{ LengthMismatch, EmptyInput, DegreeTooLarge, DivisionByZero }!Polynomial(F, max_degree) {
    traits.assertField(F);
    if (xs.len != ys.len) return error.LengthMismatch;
    if (xs.len == 0) return error.EmptyInput;
    if (xs.len - 1 > max_degree) return error.DegreeTooLarge;

    const n = xs.len;
    const Poly = Polynomial(F, max_degree);
    var result = Poly.zero();

    for (0..n) |i| {
        // Compute Lagrange basis polynomial L_i(x)
        var li = Poly.constant(F.one());
        var denom = F.one();

        for (0..n) |j| {
            if (i == j) continue;
            // li = li * (x - x_j)
            var factor = Poly.zero();
            factor.coeffs[0] = F.neg(xs[j]);
            factor.coeffs[1] = F.one();
            factor.degree = 1;
            li = try li.mul(factor);

            denom = F.mul(denom, F.sub(xs[i], xs[j]));
        }

        if (denom.isZero()) return error.DivisionByZero;
        const scale = F.mul(ys[i], F.inv(denom));
        result = result.add(li.scale(scale));
    }

    return result;
}

/// Vanishing polynomial for a set of points: V(x) = prod_i (x - xs[i]).
///
/// Returns the monic polynomial that is zero at every `xs[i]`.
///
/// # Errors
/// `error.DegreeTooLarge` when `xs.len > max_degree`. The old
/// `std.debug.assert` is compiled out in `ReleaseFast`, where the product loop
/// then wrote past the end of the fixed `coeffs` array.
pub fn vanishingPolynomial(comptime F: type, comptime max_degree: usize, xs: []const F) error{DegreeTooLarge}!Polynomial(F, max_degree) {
    traits.assertField(F);
    if (xs.len > max_degree) return error.DegreeTooLarge;

    const Poly = Polynomial(F, max_degree);
    var result = Poly.constant(F.one());

    for (xs) |xi| {
        var factor = Poly.zero();
        factor.coeffs[0] = F.neg(xi);
        factor.coeffs[1] = F.one();
        factor.degree = 1;
        result = try result.mul(factor);
    }

    return result;
}

// ============================================================================
// Tests: typed validation
// ============================================================================

const testing = std.testing;

const TestF7 = struct {
    value: u64,
    pub const MODULUS: u64 = 7;

    pub fn zero() @This() {
        return .{ .value = 0 };
    }
    pub fn one() @This() {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: anytype) @This() {
        return .{ .value = @intCast(@as(u64, @intCast(x)) % MODULUS) };
    }
    pub fn add(a: @This(), b: @This()) @This() {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: @This(), b: @This()) @This() {
        return fromInt(a.value + (MODULUS - b.value % MODULUS));
    }
    pub fn neg(a: @This()) @This() {
        return if (a.value == 0) zero() else fromInt(MODULUS - a.value);
    }
    pub fn mul(a: @This(), b: @This()) @This() {
        return fromInt(a.value * b.value);
    }
    pub fn inv(a: @This()) @This() {
        if (a.isZero()) return zero();
        return fromInt(powInt(a.value, MODULUS - 2));
    }
    pub fn invChecked(a: @This()) error{InverseOfZero}!@This() {
        if (a.isZero()) return error.InverseOfZero;
        return inv(a);
    }
    pub fn inverse(a: @This()) @This() {
        return inv(a);
    }
    pub fn isZero(a: @This()) bool {
        return a.value == 0;
    }
    pub fn eql(a: @This(), b: @This()) bool {
        return a.value == b.value;
    }
    pub fn div(a: @This(), b: @This()) @This() {
        return mul(a, inv(b));
    }
    pub fn pow(base: @This(), exp: u64) @This() {
        return fromInt(powInt(base.value, exp));
    }
    pub fn random() @This() {
        return fromInt(1);
    }
    fn powInt(base: u64, exp: u64) u64 {
        var result: u64 = 1;
        var b = base % MODULUS;
        var e = exp;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) result = result * b;
            b = b * b;
        }
        return result % MODULUS;
    }
};

test "fromCoeffs rejects more coefficients than the fixed capacity" {
    const Poly = Polynomial(TestF7, 2);
    // Capacity is max_degree + 1 == 3 coefficients.
    const fits = [_]TestF7{ TestF7.one(), TestF7.one(), TestF7.one() };
    try testing.expect((try Poly.fromCoeffs(&fits)).eql(try Poly.fromCoeffs(&fits)));
    const too_long = [_]TestF7{ TestF7.one(), TestF7.one(), TestF7.one(), TestF7.one() };
    try testing.expectError(error.DegreeTooLarge, Poly.fromCoeffs(&too_long));
}

test "mul rejects a product degree beyond the fixed capacity" {
    const Poly = Polynomial(TestF7, 3);
    const x = Poly.x();
    const x2 = try x.mul(x);
    const x3 = try x2.mul(x);
    try testing.expectError(error.DegreeTooLarge, x3.mul(x));
    // Inside the capacity the product is exact.
    try testing.expect((try x2.mul(x)).eql(x3));
}

test "compose with a non-monomial q matches the definition evaluated numerically" {
    const Poly = Polynomial(TestF7, 16);
    // p(x) = 1 + 3x, and q(x) = 2 + x + 4x^2, which is deliberately not x^k:
    // the historical defect was an accumulation that only came out right when
    // q was a monomial, so a monomial q cannot settle this.
    const p = try Poly.fromCoeffs(&.{ TestF7.fromInt(1), TestF7.fromInt(3) });
    const q = try Poly.fromCoeffs(&.{ TestF7.fromInt(2), TestF7.fromInt(1), TestF7.fromInt(4) });

    const p_before = p;
    const q_before = q;
    const composed = try p.compose(q);

    // Independent oracle: the definition is sum(c_i * q(x)^i), evaluated with
    // scalar arithmetic. Calling compose to decide what compose should return
    // would pass by construction, which is the failure this test exists to
    // rule out.
    for (0..TestF7.MODULUS) |xi| {
        const x = TestF7.fromInt(xi);
        const q_at_x = q.eval(x);
        var expect = TestF7.zero();
        var qx = TestF7.one();
        for (p.coeffs[0..@as(usize, @intCast(p.degree + 1))]) |c| {
            if (!c.isZero()) expect = expect.add(c.mul(qx));
            qx = qx.mul(q_at_x);
        }
        try testing.expectEqual(TestF7.fromInt(expect.value), TestF7.fromInt(composed.eval(x).value));
    }

    // The state left behind: composing must not consume either operand, or a
    // loop that reuses them silently composes with its own scratch values.
    for (0..TestF7.MODULUS) |xi| {
        const x = TestF7.fromInt(xi);
        try testing.expect(p_before.eval(x).eql(p.eval(x)));
        try testing.expect(q_before.eval(x).eql(q.eval(x)));
    }
}

test "compose reports DegreeTooLarge instead of returning a truncated polynomial" {
    // Capacity is max_degree + 1 == 3 coefficients, so a degree-2 composed with
    // a degree-2 has degree 4 and cannot be represented.
    const Poly = Polynomial(TestF7, 2);
    const p = try Poly.fromCoeffs(&.{ TestF7.one(), TestF7.one(), TestF7.one() });
    const q = try Poly.fromCoeffs(&.{ TestF7.one(), TestF7.one(), TestF7.one() });
    try testing.expectError(error.DegreeTooLarge, p.compose(q));
    // The operands survive the failure: the error comes from a partial `mul`
    // inside the loop, and a caller that retries with a wider type must still
    // have its inputs intact.
    try testing.expectEqual(@as(i32, 2), p.degree);
    try testing.expectEqual(@as(i32, 2), q.degree);
}

test "divRem rejects a zero divisor" {
    const Poly = Polynomial(TestF7, 4);
    const p = try Poly.fromCoeffs(&.{ TestF7.fromInt(1), TestF7.one() });
    try testing.expectError(error.DivisionByZero, p.divRem(Poly.zero()));
    try testing.expectError(error.DivisionByZero, p.div(Poly.zero()));
    try testing.expectError(error.DivisionByZero, p.rem(Poly.zero()));
}

test "lagrangeInterpolate validates lengths, emptiness, capacity and duplicates" {
    const xs0 = [_]TestF7{ TestF7.zero(), TestF7.one() };
    const xs1 = [_]TestF7{TestF7.zero()};
    try testing.expectError(error.LengthMismatch, lagrangeInterpolate(TestF7, 8, &xs0, &xs1));
    try testing.expectError(error.EmptyInput, lagrangeInterpolate(TestF7, 8, &[_]TestF7{}, &[_]TestF7{}));
    const xs3 = [_]TestF7{ TestF7.zero(), TestF7.one(), TestF7.fromInt(2) };
    try testing.expectError(error.DegreeTooLarge, lagrangeInterpolate(TestF7, 1, &xs3, &xs3));
    const dup = [_]TestF7{ TestF7.one(), TestF7.one() };
    try testing.expectError(error.DivisionByZero, lagrangeInterpolate(TestF7, 8, &dup, &dup));
}

test "vanishingPolynomial rejects more points than the capacity" {
    const xs = [_]TestF7{ TestF7.one(), TestF7.fromInt(2), TestF7.fromInt(3) };
    try testing.expectError(error.DegreeTooLarge, vanishingPolynomial(TestF7, 2, &xs));
    // Within capacity the polynomial vanishes on every point.
    const v = try vanishingPolynomial(TestF7, 3, &xs);
    for (xs) |x| try testing.expect(v.eval(x).isZero());
}

test "derivative and toString compile and behave" {
    const Poly = Polynomial(TestF7, 8);
    const p = try Poly.fromCoeffs(&.{ TestF7.fromInt(1), TestF7.fromInt(2), TestF7.fromInt(3) });
    // d/dx (1 + 2x + 3x^2) = 2 + 6x
    const d = p.derivative();
    try testing.expect(d.degree == 1);
    try testing.expect(d.coeffs[0].eql(TestF7.fromInt(2)));
    try testing.expect(d.coeffs[1].eql(TestF7.fromInt(6)));
    // A constant has zero derivative.
    try testing.expect(Poly.constant(TestF7.fromInt(5)).derivative().isZero());

    var buf: [1024]u8 = undefined;
    const n = try p.toString(&buf);
    try testing.expect(n > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "x^2") != null);
}
