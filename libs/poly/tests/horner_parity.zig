//! Four copies of Horner evaluation, and whether they still agree.
//!
//! `docs/poly-mul-measurement.md` records that `zig-poly` has no consumer in this
//! repository and that the polynomial arithmetic the ecosystem actually performs
//! is duplicated inline. This file is the instrument behind that claim's second
//! half: it runs every Horner implementation that is *reachable* over the same
//! inputs and fails if any two disagree.
//!
//! Reachable is three of the four, and the fourth is the finding:
//!
//! | Site | Name | Reachable from here |
//! |---|---|---
//! | `libs/algebra-traits/src/traits.zig:1066` | `evalPolyHorner` | yes, `pub`, generic over `F` |
//! | `libs/kzg/src/root.zig:106` | `evaluate` | yes, `pub`, over `bn254.Fr` |
//! | `libs/poly/src/poly.zig:215` | `Polynomial.eval` | yes, over a comptime-sized array |
//! | `libs/binary-field/src/sumcheck.zig:244` and `pack.zig:59` | `evalPoly` | **no, both private** |
//!
//! Two of the four copies cannot be compared without changing their visibility,
//! which is itself part of why they could drift unnoticed: a private helper has
//! no cross-library test that could see it. The three that are public agree on
//! every input below, which makes this latent divergence rather than a live bug.
//!
//! Wired by an explicit test module in the root `build.zig` rather than by
//! `wire_tests_roots`, because that helper imports only the library a file lives
//! in and this one needs four. It is listed in `non_test_sources` for the same
//! reason `libs/field/tests/benchmark.zig` is.
//!
//! Run it with `zig build test`.

const std = @import("std");
const testing = std.testing;

const zp = @import("zig-poly");
const zt = @import("zig-algebra-traits");
const zk = @import("zig-kzg");
const zc = @import("zig-curve");

const Fr = zc.bn254.Fr;

test "horner: three reachable implementations agree over random inputs" {
    var prng = std.Random.DefaultPrng.init(0x686f726e);
    const rnd = prng.random();

    // Lengths chosen to include the cases that separate the conventions:
    // empty, a single coefficient, an even count and an odd count (the parity
    // that broke the Karatsuba benchmark), and a long one.
    const lengths = [_]usize{ 0, 1, 2, 3, 7, 8, 9, 33, 64, 65 };

    inline for (lengths) |len| {
        const coeffs = try testing.allocator.alloc(Fr, len);
        defer testing.allocator.free(coeffs);
        for (coeffs) |*c| {
            var b: [32]u8 = undefined;
            rnd.bytes(&b);
            c.* = Fr.fromBytes(&b) catch Fr.fromInt(rnd.int(u32));
        }
        const x = blk: {
            var b: [32]u8 = undefined;
            rnd.bytes(&b);
            break :blk Fr.fromBytes(&b) catch Fr.fromInt(rnd.int(u32));
        };

        // 1. algebra-traits, generic over F and asserted against FieldTrait.
        const want = zt.evalPolyHorner(Fr, coeffs, x);

        // 2. kzg, over the same slice type.
        try testing.expectEqual(want, zk.evaluate(coeffs, x));

        // 3. zig-poly, over a comptime-sized array, which is the representation
        //    difference that the four copies exist to route around.
        if (len > 0) {
            const Poly = zp.Polynomial(Fr, len - 1);
            const p = try Poly.fromCoeffs(coeffs);
            try testing.expectEqual(want, p.eval(x));
        } else {
            // zig-poly cannot represent the zero polynomial's empty coefficient
            // list: `Polynomial(F, 0).zero()` is a constant, not an empty slice.
            // The two slice-based implementations both return zero here, so the
            // array-based one has no equivalent case to be compared against.
            try testing.expect(want.isZero());
        }
    }
}

test "horner: an empty coefficient list is zero for both slice-based copies" {
    // The array-based implementation has no empty case (documented above), so
    // this pins the two that do. If one of them ever starts to panic, index or
    // return a non-zero on an empty slice, this is the test that sees it.
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var b: [32]u8 = undefined;
    rnd.bytes(&b);
    const x = Fr.fromBytes(&b) catch Fr.zero();

    const empty: []const Fr = &.{};
    try testing.expect(zt.evalPolyHorner(Fr, empty, x).isZero());
    try testing.expect(zk.evaluate(empty, x).isZero());
}
