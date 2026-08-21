//! zig-poly example: polynomial arithmetic over a finite field.

const std = @import("std");
const poly = @import("root.zig");

// Minimal F7 field for demonstration
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self { return .{ .value = 0 }; }
    pub fn one() Self { return .{ .value = 1 }; }
    pub fn fromInt(x: u256) Self { return .{ .value = @intCast(x % modulus) }; }
    pub fn toInt(self: Self) u64 { return self.value; }
    pub fn eql(a: Self, b: Self) bool { return a.value == b.value; }
    pub fn add(a: Self, b: Self) Self { return fromInt(a.value + b.value); }
    pub fn sub(a: Self, b: Self) Self { return fromInt(a.value + (modulus - b.value % modulus)); }
    pub fn neg(a: Self) Self { return if (a.value == 0) zero() else fromInt(modulus - a.value); }
    pub fn mul(a: Self, b: Self) Self { return fromInt(a.value * b.value); }
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub fn div(a: Self, b: Self) Self { return mul(a, inv(b)); }
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
    pub fn isZero(self: Self) bool { return self.value == 0; }
    pub fn random() Self { return fromInt(1); }
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== zig-poly example ===\n\n", .{});

    const Poly = poly.Polynomial(F7, 16);

    // --- Construction ---
    try stdout.print("--- Construction ---\n", .{});
    const p = Poly.fromCoeffs(&.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) });
    try stdout.print("p(x) = {}\n", .{p});
    try stdout.print("degree = {}\n", .{p.degree});

    const q = Poly.fromCoeffs(&.{ F7.fromInt(4), F7.fromInt(5) });
    try stdout.print("q(x) = {}\n", .{q});

    // --- Arithmetic ---
    try stdout.print("\n--- Arithmetic ---\n", .{});
    const s = p.add(q);
    try stdout.print("p + q = {}\n", .{s});

    const d = p.sub(q);
    try stdout.print("p - q = {}\n", .{d});

    const m = p.mul(q);
    try stdout.print("p * q = {}\n", .{m});

    // --- Evaluation ---
    try stdout.print("\n--- Evaluation ---\n", .{});
    const x = F7.fromInt(2);
    const y = p.eval(x);
    try stdout.print("p({}) = {}\n", .{ x.value, y.value });

    // --- Division ---
    try stdout.print("\n--- Division ---\n", .{});
    const dividend = Poly.fromCoeffs(&.{ F7.fromInt(6), F7.fromInt(0), F7.fromInt(1) }); // x^2 - 1
    const divisor = Poly.fromCoeffs(&.{ F7.fromInt(6), F7.fromInt(1) }); // x - 1
    const qr = dividend.divRem(divisor);
    try stdout.print("(x^2 - 1) / (x - 1) = {}\n", .{qr.q});
    try stdout.print("remainder = {}\n", .{qr.r});

    // --- Derivative ---
    try stdout.print("\n--- Derivative ---\n", .{});
    const deriv = p.derivative();
    try stdout.print("p'(x) = {}\n", .{deriv});

    // --- Composition ---
    try stdout.print("\n--- Composition ---\n", .{});
    const composed = p.compose(q);
    try stdout.print("p(q(x)) = {}\n", .{composed});

    // --- Power ---
    try stdout.print("\n--- Power ---\n", .{});
    const p3 = p.pow(3);
    try stdout.print("p(x)^3 = {}\n", .{p3});

    // --- Lagrange Interpolation ---
    try stdout.print("\n--- Lagrange Interpolation ---\n", .{});
    const xs = &[_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2) };
    const ys = &[_]F7{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(5) };
    const interp = poly.lagrangeInterpolate(F7, 16, xs, ys);
    try stdout.print("Interpolated: {}\n", .{interp});
    for (xs, ys) |xi, yi| {
        const yi_calc = interp.eval(xi);
        try stdout.print("  f({}) = {} (expected {})\n", .{ xi.value, yi_calc.value, yi.value });
    }

    // --- Vanishing Polynomial ---
    try stdout.print("\n--- Vanishing Polynomial ---\n", .{});
    const points = &[_]F7{ F7.fromInt(1), F7.fromInt(2) };
    const vanish = poly.vanishingPolynomial(F7, 16, points);
    try stdout.print("V(x) = {}\n", .{vanish});
    for (points) |pt| {
        try stdout.print("  V({}) = {}\n", .{ pt.value, vanish.eval(pt).value });
    }

    try stdout.print("\nAll polynomial operations completed successfully!\n", .{});
}
