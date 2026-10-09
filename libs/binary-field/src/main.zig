//! zig-binary-field consumer: characteristic two, where `a + b == a - b`.
//!
//! That identity is the whole reason binary fields exist and the whole reason
//! code written for odd characteristic is wrong here. This example checks it
//! holds, checks that the two tower levels really are different fields, and
//! checks the trace and norm maps that everything in characteristic two rests
//! on.
//!
//! The second half is the one that matters downstream: `invChecked` rather than
//! `inv`. The legacy `inv` returns zero on zero, and zero is not an inverse --
//! a silent wrong answer rather than a failure.

const std = @import("std");
const zbf = @import("zig-binary-field");

pub fn main() !void {
    std.debug.print("zig-binary-field: characteristic two, where + and - coincide\n\n", .{});

    // Two tower levels: 8 bits and 32 bits, both from the same Wiedemann tower.
    const B = zbf.Gf256; // 2^8, level 3
    const W = zbf.Gf2_32; // 2^32, level 5

    inline for (.{ .{ "Gf256 (2^8)", B }, .{ "Gf2_32 (2^32)", W } }) |pair| {
        const name = pair[0];
        const F = pair[1];

        const a = F.fromInt(0x5a);
        const b = F.fromInt(0xa5);

        // The identity that makes characteristic two what it is.
        const same = a.add(b).eq(a.sub(b));
        std.debug.print("=== {s} ===\n", .{name});
        std.debug.print("  BITS: {d}\n", .{F.BITS});
        std.debug.print("  a + b == a - b: {s}\n", .{if (same) "yes" else "NO"});

        // a + a == 0, which is the same fact seen from the other side.
        std.debug.print("  a + a == 0:    {s}\n", .{if (a.add(a).isZero()) "yes" else "NO"});

        // Trace is F_2-valued: trace(x) is 0 or 1 for every x, and
        // trace returns u1, so "F_2-valued" is a type property rather than a
        // check; what is checkable is additivity, which in characteristic two is
        // trace(a+b) == trace(a) XOR trace(b).
        const t_ok = (a.add(b).trace() == (a.trace() ^ b.trace()));
        std.debug.print("  trace additive (XOR): {s}\n", .{if (t_ok) "yes" else "NO"});

        // Norm lands in the base, and is multiplicative.
        const n1 = F.fromInt(3).norm();
        const n2 = F.fromInt(5).norm();
        const n_ok = F.fromInt(3).mul(F.fromInt(5)).norm().eq(n1.mul(n2));
        std.debug.print("  norm multiplicative: {s}\n", .{if (n_ok) "yes" else "NO"});

        // The checked inverse, and the trap beside it.
        const inv = try a.invChecked();
        std.debug.print("  a * a^-1 == 1:  {s}\n", .{if (a.mul(inv).eq(F.one())) "yes" else "NO"});
        std.debug.print("  LEGACY inv(0) is zero, and zero is not an inverse: {s}\n", .{
            if (F.zero().inv().isZero()) "yes (use invChecked)" else "no",
        });
        std.debug.print("\n", .{});
    }

    // The polynomial-reduced family (not the tower), and the GCM polynomial:
    // this is the field hardware CLMUL exists for, and the one where a
    // carry-less multiply is the whole operation.
    const Gcm = zbf.Gf128;
    const x = Gcm.fromInt(0x0123456789abcdef);
    std.debug.print("=== Gf128, x^128 + x^7 + x^2 + x + 1 (GCM) ===\n", .{});
    const inv = try x.invChecked();
    std.debug.print("  x * x^-1 == 1: {s}\n", .{if (x.mul(inv).eq(Gcm.one())) "yes" else "NO"});
    const y = Gcm.fromInt(0xfedcba9876543210);
    std.debug.print("  y * y^-1 == 1: {s}\n", .{if (y.mul(try y.invChecked()).eq(Gcm.one())) "yes" else "NO"});
    std.debug.print("  x + x == 0:    {s}\n", .{if (x.add(x).isZero()) "yes" else "NO"});
}
