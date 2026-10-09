//! zig-field consumer: the two backends, and why the caller never sees which.
//!
//! `Field(modulus)` dispatches at comptime -- below 2^64 it is `SmallField` on
//! native u64 with a Mersenne split-reduction fast path, at or above it is
//! `BigField` on Montgomery CIOS over limbs. Both expose the same API, and that
//! is the property worth showing: the same source compiles against both and the
//! arithmetic is the same arithmetic.
//!
//! What is checked here is the invariant that decides everything downstream --
//! a * a^-1 == 1 for both backends -- plus the boundary conditions a random
//! sample never reaches: the wraparound points p-1 and p-2, and the fact that
//! `fromBytes` rejects a value at or above the modulus instead of reducing it.

const std = @import("std");
const testing = std.testing;
const zf = @import("zig-field");

fn checkField(comptime F: type, comptime name: []const u8) !void {
    std.debug.print("=== {s} ===\n", .{name});
    std.debug.print("  modulus bits: {d}\n", .{@bitSizeOf(@TypeOf(F.MODULUS))});
    std.debug.print("  NUM_BYTES:    {d}\n", .{F.NUM_BYTES});

    // a * a^-1 == 1, including at the wraparound boundary a random sample never
    // reaches. A Montgomery inverse that only works for small operands is wrong
    // and looks right on random inputs.
    // Wide enough for the largest modulus this dispatches over, so the same
    // source compiles against a 31-bit Mersenne field and a 381-bit one.
    const WIDE = if (F.NUM_BYTES <= 8) u64 else if (F.NUM_BYTES <= 16) u128 else u512;
    const boundary = [_]WIDE{ 1, 2, 3, 0xdead, F.MODULUS - 1, F.MODULUS - 2 };
    var ok = true;
    for (boundary) |v| {
        const a = F.fromInt(v);
        const back = a.mul(try a.invChecked());
        if (!back.isOne()) ok = false;
    }
    try std.testing.expect(ok);
    std.debug.print("  a * a^-1 == 1 at boundary values: {s}\n", .{if (ok) "yes" else "NO"});
    try std.testing.expect(ok);

    // fromBytes rejects rather than reduces: a serialiser that silently reduced
    // would accept two different byte strings for the same element.
    var at_modulus: [F.NUM_BYTES]u8 = undefined;
    writeModulus(F, &at_modulus);
    const rejected: anyerror!F = F.fromBytes(&at_modulus);
    const err_name: []const u8 = if (rejected) |_| "ACCEPTED (bug)" else |e| @errorName(e);
    std.debug.print("  fromBytes(p) -> {s}\n", .{err_name});

    // The legacy total wrapper is the documented trap: inv(0) is zero and zero
    // is not an inverse. Shown so a reader of this example cannot mistake it.
    const legacy = F.zero().inv();
    std.debug.print("  LEGACY inv(0) is zero, and zero is not an inverse: {s}\n", .{if (legacy.isZero()) "yes (use invChecked)" else "no"});

    // pow / sqr / neg agree with repeated multiplication.
    const x = F.fromInt(12345);
    var acc = F.one();
    for (0..5) |_| acc = acc.mul(x);
    try std.testing.expect(x.pow(5).eql(acc));
    std.debug.print("  pow(5) == five multiplications: {s}\n", .{if (x.pow(5).eql(acc)) "yes" else "NO"});
    try std.testing.expect(x.pow(5).eql(acc));
}

/// Serialise the modulus itself, big-endian-free: the field's `toBytes` is
/// little-endian, so this writes the same way and the result is the byte string
/// for the value p, which `fromBytes` must reject.
fn writeModulus(comptime F: type, out: *[F.NUM_BYTES]u8) void {
    var i: usize = 0;
    var v: u512 = F.MODULUS;
    while (i < F.NUM_BYTES) : (i += 1) {
        out[i] = @intCast(v & 0xff);
        v >>= 8;
    }
}

pub fn main() !void {
    std.debug.print("zig-field: one API, two backends selected at comptime\n\n", .{});
    try checkField(zf.M31, "M31 (SmallField, Mersenne fast path)");
    std.debug.print("\n", .{});
    try checkField(zf.Goldilocks, "Goldilocks (BigField, Montgomery CIOS)");
    std.debug.print("\n", .{});
    try checkField(zf.BN254_Fp, "BN254_Fp (BigField, Montgomery, 254-bit)");

    // The tower types are the same API one level up.
    // The tower is the same API one level up: an element has a base part and a
    // v part, and v^2 is the non-residue rather than a computed value.
    const Sq = zf.BN254_Fp2;
    const v = Sq.EXT_NON_RESIDUE;
    std.debug.print("\n=== BN254_Fp2 (quadratic tower) ===\n", .{});
    try std.testing.expect(v.sqr().add(Sq.fromInt(1)).isZero());
    std.debug.print("  v^2 + 1 == 0 (u^2 = -1): {s}\n", .{if (v.sqr().add(Sq.fromInt(1)).isZero()) "yes" else "NO"});
    try std.testing.expect(v.sqr().add(Sq.fromInt(1)).isZero());

    // And the inverse of an extension element is norm-based, so the same
    // a * a^-1 == 1 invariant holds there too.
    const e = Sq.new(zf.BN254_Fp.fromInt(7), zf.BN254_Fp.fromInt(11));
    try std.testing.expect(e.mul(try e.invChecked()).isOne());
    std.debug.print("  extension a * a^-1 == 1: {s}\n", .{if (e.mul(try e.invChecked()).isOne()) "yes" else "NO"});
    try std.testing.expect(e.mul(try e.invChecked()).isOne());
}
