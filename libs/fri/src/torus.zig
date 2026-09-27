// SPDX-License-Identifier: MIT OR Apache-2.0

//! FRI domains on the norm-1 torus of `F[p^2]`.
//!
//! # Why a torus
//!
//! FRI's fold needs a multiplicative subgroup of order `2^k` whose element at
//! position `n/2` is `-x_j`. A cyclic 2-power subgroup of any field does that
//! automatically, since the unique element of order 2 in `F*` is `-1`. What it
//! does *not* do is exist: `Domain(F)` is built from `F.two_adicity`, and for
//! `M31` that is **1** -- `2^31 - 1` has `v2(p - 1) = 1`, so the base field has
//! no 2-subgroup of order 4 and a 31-bit STARK field was unusable here.
//!
//! The norm-1 torus `T = { x in F_p^2* : N(x) = 1 }` is cyclic of order
//! `p + 1`, and `2^31 - 1 + 1 = 2^31`, so `T` has 2-adicity **31**. The gap is
//! not marginal: it is the difference between no usable FRI domain and
//! thirty-one of them. `M61` gets 61 from the same `p + 1`.
//!
//! # The generator is derived, then checked by a different computation
//!
//! Every torus element is `(1 + t*v) / (1 - t*v)` by the Cayley
//! parametrization: numerator and denominator both have norm `1 - n*t^2`, so
//! the quotient has norm 1. `T` is cyclic of order `2^A`, so an element has full
//! 2-adic order exactly when `x^(2^(A-1)) = -1`, and a search over `t` finds one
//! immediately -- `t = 2` for `M31`.
//!
//! Two choices here are deliberate. The search runs in **raw `u128` arithmetic**,
//! not through the field API, so the result is a claim about the number itself
//! rather than about the library that will use it. And the resulting order is
//! then **re-checked through the field's own `pow`** by the tests. If
//! construction and verification were the same computation, their agreement
//! would prove nothing.
//!
//! # Nothing here assumes 2 is invertible
//!
//! The FRI fold divides by 2 (`half_inv = 1/2`). Both moduli are odd, so
//! `gcd(2, p) = 1` and 2 is a unit; `twoIsInvertible` states that, and
//! `two is invertible on the torus fields` checks `2 * inv(2) == 1` on the
//! actual field rather than trusting the argument.

const std = @import("std");
const zfield = @import("zig-field");

const testing = std.testing;

/// `F_M31[v]/(v^2 + 1)`, the 31-bit torus field. Also `zig-field`'s `CM31`.
pub const Torus31 = zfield.CM31;
/// `F_M61[v]/(v^2 + 1)`, the 61-bit torus field.
///
/// `M61 = 2^61 - 1` is `3 mod 4`, so `-1` is a quadratic non-residue for the
/// same reason `CM31` uses `-1`. Declared here because `zig-field` has no
/// `M61` extension predefined, and one line is cheaper than a manifest change.
pub const Torus61 = zfield.QuadraticExtension(
    zfield.M61,
    zfield.M61.fromInt(-1),
);

// ============================================================================
// Raw arithmetic. Deliberately not the field API.
// ============================================================================

fn rmod(x: u128, p: u64) u64 {
    return @intCast(x % @as(u128, p));
}

fn radd(x: u64, y: u64, p: u64) u64 {
    return @intCast((@as(u128, x) + y) % p);
}

fn rsub(x: u64, y: u64, p: u64) u64 {
    return @intCast((@as(u128, x) + p - y) % p);
}

fn rmul(x: u64, y: u64, p: u64) u64 {
    return rmod(@as(u128, x) * y, p);
}

/// An element `a + b*v` of the extension, as raw residues, where `v^2 = nres`.
const Raw = struct {
    a: u64,
    b: u64,

    fn one() Raw {
        return .{ .a = 1, .b = 0 };
    }

    /// `x^(p - 2) mod p` per component, by Fermat. `p` is prime, so this is
    /// the inverse where the component is non-zero, and the only places an
    /// inverse is taken have already established that it is.
    fn invComponent(x: u64, p: u64) u64 {
        return rpow(x, p - 2, p);
    }

    fn mul(x: Raw, y: Raw, p: u64, nres: u64) Raw {
        // `nres * b1 * b2` is under 2^183, so the inner product is reduced
        // first: every `rmul` keeps both operands below p.
        const cross = rmul(rmul(nres, x.b, p), y.b, p);
        return .{
            .a = radd(rmul(x.a, y.a, p), cross, p),
            .b = radd(rmul(x.a, y.b, p), rmul(x.b, y.a, p), p),
        };
    }

    fn sqr(x: Raw, p: u64, nres: u64) Raw {
        return x.mul(x, p, nres);
    }

    /// `N(x) = a^2 - nres * b^2`.
    fn norm(x: Raw, p: u64, nres: u64) u64 {
        return rsub(rmul(x.a, x.a, p), rmul(rmul(nres, x.b, p), x.b, p), p);
    }

    fn inv(x: Raw, p: u64, nres: u64) Raw {
        const n = x.norm(p, nres);
        const ni = Raw.invComponent(n, p);
        return .{
            .a = rmul(x.a, ni, p),
            .b = rmul(rsub(0, x.b, p), ni, p),
        };
    }

    fn pow(x: Raw, e: u64, p: u64, nres: u64) Raw {
        var result = Raw.one();
        var base = x;
        var i: u8 = 0;
        while (i < 64) : (i += 1) {
            if (((e >> @intCast(i)) & 1) == 1) result = result.mul(base, p, nres);
            base = base.sqr(p, nres);
        }
        return result;
    }

    fn eql(x: Raw, y: Raw) bool {
        return x.a == y.a and x.b == y.b;
    }
};

fn rpow(x: u64, e: u64, p: u64) u64 {
    var result: u64 = 1;
    var base = x;
    // u8, not u6: a u64 exponent needs 64 iterations and u6 tops out at 63, so
    // `i += 1` overflows on the last one.
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        if (((e >> @intCast(i)) & 1) == 1) result = rmul(result, base, p);
        base = rmul(base, base, p);
    }
    return result;
}

/// Exponent of 2 in `p + 1`, which is the order of the norm-1 torus.
///
/// Computed, not hard-coded: `M31` -> 31, `M61` -> 61, Goldilocks -> 33.
pub fn torusAdicity(comptime Base: type) comptime_int {
    const p: u64 = @as(u64, Base.MODULUS);
    return @ctz(p +% 1);
}

/// A full-2-adic-order generator of the torus, as raw residues.
///
/// Deterministic: the first `t >= 1` whose Cayley image has order exactly
/// `2^A`. `error.TorusGeneratorNotFound` is unreachable for `A >= 2` -- half of
/// `T` is non-square and only `-1` is outside the parametrization -- but it is
/// returned rather than assumed away.
pub const Generator = struct {
    a: u64,
    b: u64,
};

pub fn findGenerator(comptime F: type, comptime Base: type) error{TorusGeneratorNotFound}!Generator {
    const p: u64 = @as(u64, Base.MODULUS);
    const nres: u64 = @as(u64, F.NON_RESIDUE.toInt());
    const A = torusAdicity(Base);
    const minus_one = Raw{ .a = p - 1, .b = 0 };
    const half_order: u64 = @as(u64, 1) << @intCast(A - 1);

    var t: u64 = 1;
    while (t < p) : (t += 1) {
        const num = Raw{ .a = 1, .b = t };
        const den = Raw{ .a = 1, .b = rsub(0, t, p) };
        const x = num.mul(den.inv(p, nres), p, nres);
        if (x.norm(p, nres) != 1) continue;
        if (x.pow(half_order, p, nres).eql(minus_one)) {
            return .{ .a = x.a, .b = x.b };
        }
    }
    return error.TorusGeneratorNotFound;
}

/// Whether 2 is invertible on the torus field `F`.
///
/// Stated rather than assumed, because the FRI fold divides by 2. `F` is
/// `Base[v]/(v^2 - n)`, a field whenever `Base` is, and 2 is the embedding of 2,
/// which is a unit in `F_p` exactly when `p` is odd. Returns false for an even
/// modulus rather than dividing by it.
pub fn twoIsInvertible(comptime Base: type) bool {
    const p: u64 = @as(u64, Base.MODULUS);
    return (p & 1) == 1;
}

// ============================================================================
// The domain
// ============================================================================

/// A FRI domain: the order-`2^log_n` subgroup of the norm-1 torus.
///
/// Structurally identical to `Domain(F)` -- `init`, `size`, `at`, `fill` -- so
/// `proveOn`/`verifyOn` accept either without knowing which they were given.
pub fn TorusDomain(comptime F: type, comptime Base: type) type {
    return struct {
        log_n: u6,
        step_gen: F,

        const Self = @This();

        /// The torus's 2-adicity, as a `u6` so it can be compared with `log_n`.
        pub const two_adicity: u6 = @intCast(torusAdicity(Base));

        /// # Errors
        /// `error.DomainTooLarge` when `log_n` exceeds the torus's 2-adicity,
        /// which is what makes `p + 1` the relevant modulus rather than `p - 1`.
        /// `error.OrderTooLarge` when the derived step generator is not of
        /// order exactly `2^log_n` -- checked here rather than assumed, so a
        /// wrong modulus or a wrong search shows up as a typed error instead of
        /// a proof that quietly fails to verify.
        pub fn init(comptime Field: type, log_n: u6) error{ DomainTooLarge, OrderTooLarge }!Self {
            _ = Field;
            if (log_n == 0) return error.DomainTooLarge;
            if (log_n > two_adicity) return error.DomainTooLarge;
            if (!twoIsInvertible(Base)) return error.OrderTooLarge;

            const p: u64 = @as(u64, Base.MODULUS);
            const nres: u64 = @as(u64, F.NON_RESIDUE.toInt());
            const gen = findGenerator(F, Base) catch return error.OrderTooLarge;

            // g = generator^(2^(A - log_n)) has order exactly 2^log_n.
            const shift: u6 = @intCast(torusAdicity(Base) - log_n);
            const gen_raw = Raw{ .a = gen.a, .b = gen.b };
            const g = gen_raw.pow(@as(u64, 1) << @intCast(shift), p, nres);

            // The order claim, verified rather than inferred from the search.
            const minus_one = Raw{ .a = p - 1, .b = 0 };
            const half = @as(u64, 1) << @intCast(log_n - 1);
            if (!g.pow(half, p, nres).eql(minus_one)) return error.OrderTooLarge;

            return .{
                .log_n = log_n,
                .step_gen = F.new(Base.fromInt(g.a), Base.fromInt(g.b)),
            };
        }

        pub fn size(self: Self) usize {
            return @as(usize, 1) << self.log_n;
        }

        /// The i-th domain element in natural order, `g^i`.
        pub fn at(self: Self, i: usize) F {
            return self.step_gen.pow(i);
        }

        /// # Errors
        /// `error.LengthMismatch` when `buf.len != self.size()`.
        pub fn fill(self: Self, buf: []F) error{LengthMismatch}!void {
            if (buf.len != self.size()) return error.LengthMismatch;
            var x = F.one();
            const g = self.step_gen;
            for (buf) |*slot| {
                slot.* = x;
                x = x.mul(g);
            }
        }

        /// The norm-1 torus condition every element of this domain satisfies:
        /// `N(x) = 1`. Not a universal identity -- the ambient `F_p^2*` has
        /// `(p-1)(p+1)` elements and only `p+1` of them are norm 1 -- so it is a
        /// real, testable property of the domain rather than a comment.
        pub fn norm(x: F) u64 {
            const a = @as(u64, x.c0.toInt());
            const b = @as(u64, x.c1.toInt());
            const p: u64 = @as(u64, Base.MODULUS);
            const nres: u64 = @as(u64, F.NON_RESIDUE.toInt());
            const raw = Raw{ .a = a, .b = b };
            return raw.norm(p, nres);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "torus: the 2-adicity of the torus comes from p + 1, not p - 1" {
    // This is the whole reason the file exists. `M31`'s base field has
    // two-adicity 1, which is why it was declared unusable; `p + 1 = 2^31`
    // gives the torus 31.
    try testing.expectEqual(@as(usize, 1), zfield.M31.two_adicity);
    try testing.expectEqual(@as(comptime_int, 31), torusAdicity(zfield.M31));
    try testing.expectEqual(@as(comptime_int, 61), torusAdicity(zfield.M61));

    // Goldilocks is the field that already worked, and the torus is *worse*
    // there, not better. Its base two_adicity is 32 while `p + 1 =
    // 2*(2^63 - 2^31 + 1)` has 2-adicity 1, so the torus offers Goldilocks a
    // domain of size 2 and `Domain(F)` offers it 2^32. That is why FRI keeps
    // using the multiplicative subgroup there: the torus is a fix for `p + 1`
    // being a large power of two, i.e. for Mersenne primes, and Goldilocks is
    // not one. Worth stating because the natural assumption -- "the torus is
    // always at least as good" -- is false.
    try testing.expectEqual(@as(comptime_int, 1), torusAdicity(zfield.Goldilocks));
    try testing.expect(zfield.Goldilocks.two_adicity > torusAdicity(zfield.Goldilocks));
}

test "torus: the generator has exact order 2^A, verified through the field API" {
    // Constructed in raw u128 arithmetic, checked here through `F.pow`. The two
    // are different computations on purpose; if they agreed because they were
    // the same code, this would prove nothing.
    const Dom = TorusDomain(Torus31, zfield.M31);
    const A = torusAdicity(zfield.M31);

    // The full generator, which is the step generator of the domain of size
    // 2^A. Asking for a smaller domain yields a *power* of it, so testing
    // order 2^A against `Dom.init(..., 8).step_gen` would be testing the wrong
    // element -- of order 2^8.
    const full = try Dom.init(Torus31, @intCast(A));
    const g = full.step_gen;
    try testing.expectEqual(@as(u64, @as(u64, 1) << @intCast(A)), full.size());

    // Order divides 2^A and g^(2^(A-1)) = -1, so the order is exactly 2^A:
    // no smaller power of two divides it.
    try testing.expect(g.pow(@as(u64, 1) << @intCast(A - 1)).eql(Torus31.one().neg()));
    try testing.expect(g.pow(@as(u64, 1) << @intCast(A)).eql(Torus31.one()));

    // And a smaller domain's step generator is of order exactly 2^log_n.
    const dom = try Dom.init(Torus31, @as(u6, 8));
    try testing.expect(dom.step_gen.pow(@as(u64, 1) << @intCast(dom.log_n - 1))
        .eql(Torus31.one().neg()));
    try testing.expect(dom.step_gen.pow(@as(u64, 1) << @intCast(dom.log_n))
        .eql(Torus31.one()));
}

test "torus: every domain element has norm 1" {
    const Dom = TorusDomain(Torus31, zfield.M31);
    for ([_]u6{ 1, 2, 3, 8 }) |log_n| {
        const dom = try Dom.init(Torus31, log_n);
        var i: usize = 0;
        while (i < dom.size()) : (i += 1) {
            try testing.expectEqual(@as(u64, 1), Dom.norm(dom.at(i)));
        }
    }
}

test "torus: the antipode is -x, which is the FRI fold's whole requirement" {
    // `at(i + n/2) == -at(i)` is what lets the fold pair positions (j, j+n/2).
    // It is automatic for any cyclic 2^k subgroup, so this is a check on the
    // arithmetic rather than a discovery -- but it is cheap and it is the
    // property FRI actually depends on.
    const Dom = TorusDomain(Torus31, zfield.M31);
    for ([_]u6{ 1, 2, 5 }) |log_n| {
        const dom = try Dom.init(Torus31, log_n);
        const half = dom.size() / 2;
        var i: usize = 0;
        while (i < half) : (i += 1) {
            try testing.expect(dom.at(i + half).eql(dom.at(i).neg()));
        }
    }
}

test "torus: 2 is invertible, demonstrated rather than assumed" {
    // The FRI fold computes `1/2`. `twoIsInvertible` is the argument; this is
    // the measurement, on the actual field.
    try testing.expect(twoIsInvertible(zfield.M31));
    try testing.expect(twoIsInvertible(zfield.M61));

    const two = Torus31.fromInt(2);
    try testing.expect(!two.isZero());
    try testing.expect(two.mul(two.inv()).eql(Torus31.one()));
    try testing.expect((try two.invChecked()).eql(two.inv()));

    const two61 = Torus61.fromInt(2);
    try testing.expect(!two61.isZero());
    try testing.expect(two61.mul(two61.inv()).eql(Torus61.one()));
}

test "torus: log_n above the torus 2-adicity is a typed error" {
    const Dom = TorusDomain(Torus31, zfield.M31);
    try testing.expectError(error.DomainTooLarge, Dom.init(Torus31, 32));
    try testing.expectError(error.DomainTooLarge, Dom.init(Torus31, 0));
}

test "torus: fill agrees with at" {
    const Dom = TorusDomain(Torus31, zfield.M31);
    const dom = try Dom.init(Torus31, 4);
    var buf = try testing.allocator.alloc(Torus31, dom.size());
    defer testing.allocator.free(buf);
    try dom.fill(buf);
    for (buf, 0..) |x, i| try testing.expect(x.eql(dom.at(i)));
    try testing.expectError(error.LengthMismatch, dom.fill(buf[0 .. buf.len - 1]));
}
