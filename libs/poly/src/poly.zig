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
//! var p = Poly.fromCoeffs(&.{ F.fromInt(1), F.fromInt(2), F.fromInt(1) });
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
            var p = Self{};
            p.coeffs[1] = F.one();
            p.degree = 1;
            return p;
        }

        /// Build from a slice of coefficients `[c0, c1, c2, ...]`.
        ///
        /// # Panics
        /// Debug-asserts that `src.len <= max_degree + 1`.
        pub fn fromCoeffs(src: []const F) Self {
            std.debug.assert(src.len <= max_degree + 1);
            var p = Self{};
            for (0..src.len) |i| {
                p.coeffs[i] = src[i];
            }
            p.normalize();
            return p;
        }

        /// Build from an array literal.
        pub fn fromArray(comptime src: []const F) Self {
            return fromCoeffs(src);
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
        /// # Panics
        /// Debug-asserts that the result degree does not exceed `max_degree`.
        pub fn mul(self: Self, other: Self) Self {
            if (self.isZero() or other.isZero()) return Self.zero();
            const d = self.degree + other.degree;
            std.debug.assert(d <= max_degree);

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
        /// `divisor` must not be zero.
        pub fn divRem(self: Self, divisor: Self) struct { q: Self, r: Self } {
            std.debug.assert(!divisor.isZero());
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
        pub fn div(self: Self, divisor: Self) Self {
            return self.divRem(divisor).q;
        }

        /// Remainder only.
        pub fn rem(self: Self, divisor: Self) Self {
            return self.divRem(divisor).r;
        }

        // ------------------------------------------------------------------
        // Derivative & Composition
        // ------------------------------------------------------------------

        /// Formal derivative: d/dx of a polynomial.
        pub fn derivative(self: Self) Self {
            if (self.degree <= 0) return Self.zero();
            var r = Self{};
            for (1..@intCast(self.degree + 1)) |i| {
                const coeff = F.fromInt(@intCast(i));
                r.coeffs[i - 1] = F.mul(self.coeffs[i], coeff);
            }
            r.degree = self.degree - 1;
            r.normalize();
            return r;
        }

        /// Polynomial composition: `self(other(x))`.
        pub fn compose(self: Self, other: Self) Self {
            if (self.isZero()) return Self.zero();
            var result = Self.constant(self.coeffs[0]);
            var power = other;
            for (1..@as(usize, @intCast(self.degree + 1))) |i| {
                if (!self.coeffs[i].isZero()) {
                    const term = power.scale(self.coeffs[i]);
                    result = result.add(term);
                }
                if (i < @as(usize, @intCast(self.degree))) {
                    power = power.mul(other);
                }
            }
            return result;
        }

        // ------------------------------------------------------------------
        // Powers
        // ------------------------------------------------------------------

        /// Raise to a non-negative integer power.
        pub fn pow(self: Self, exp: u32) Self {
            if (exp == 0) return Self.constant(F.one());
            if (self.isZero()) return Self.zero();
            var result = Self.constant(F.one());
            var base = self;
            var e = exp;
            while (e > 0) {
                if (e & 1 == 1) result = result.mul(base);
                base = base.mul(base);
                e >>= 1;
            }
            return result;
        }

        // ------------------------------------------------------------------
        // Formatting
        // ------------------------------------------------------------------

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
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
    };
}

/// Lagrange interpolation: given distinct points `(xs[i], ys[i])`, return the
/// unique polynomial of degree `< n` that passes through them.
///
/// # Constraints
/// - `xs.len == ys.len`
/// - All `xs[i]` must be distinct.
/// - `xs.len - 1 <= max_degree`
///
/// # Example
/// ```zig
/// const xs = &.{ F.fromInt(0), F.fromInt(1), F.fromInt(2) };
/// const ys = &.{ F.fromInt(1), F.fromInt(3), F.fromInt(5) };
/// const p = lagrangeInterpolate(F, 64, xs, ys); // p(x) = 1 + 2x
/// ```
pub fn lagrangeInterpolate(comptime F: type, comptime max_degree: usize, xs: []const F, ys: []const F) Polynomial(F, max_degree) {
    traits.assertField(F);
    std.debug.assert(xs.len == ys.len);
    std.debug.assert(xs.len > 0);
    std.debug.assert(xs.len - 1 <= max_degree);

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
            li = li.mul(factor);

            denom = F.mul(denom, F.sub(xs[i], xs[j]));
        }

        const scale = F.mul(ys[i], F.inv(denom));
        result = result.add(li.scale(scale));
    }

    return result;
}

/// Vanishing polynomial for a set of points: V(x) = prod_i (x - xs[i]).
///
/// Returns the monic polynomial that is zero at every `xs[i]`.
pub fn vanishingPolynomial(comptime F: type, comptime max_degree: usize, xs: []const F) Polynomial(F, max_degree) {
    traits.assertField(F);
    std.debug.assert(xs.len <= max_degree);

    const Poly = Polynomial(F, max_degree);
    var result = Poly.constant(F.one());

    for (xs) |xi| {
        var factor = Poly.zero();
        factor.coeffs[0] = F.neg(xi);
        factor.coeffs[1] = F.one();
        factor.degree = 1;
        result = result.mul(factor);
    }

    return result;
}
