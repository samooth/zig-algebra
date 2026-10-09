//! zig-curve consumer: the same group, reached three ways, and they must agree.
//!
//! A curve library's correctness is not that an operation returns *a* point. It
//! is that the paths disagree nowhere: the windowed Jacobian ladder, the naive
//! double-and-add kept as a reference, and the affine formulas must all land on
//! the same point for the same scalar. That is the property this checks, because a
//! ladder that is fast and wrong agrees with itself perfectly.
//!
//! The second half is MSM. Pippenger's bucket method is the reason a batch of
//! scalar multiplications is practical at all, and its failure mode is a bucket
//! dropped or double-counted -- which produces a point, not an error. So the batch
//! is checked against the sum of the individual products.

const std = @import("std");
const zc = @import("zig-curve");
const zf = @import("zig-field");

const G1 = zc.bn254.G1;
const G1Proj = zc.bn254.G1Projective;
const Fr = zc.bn254.Fr;
const gen = zc.bn254.G1_generator;

/// BN254's group order r, as a decimal. `[r]G` is the identity, which is the
/// curve analogue of `[p]x == 0` and is the boundary a random sample never hits.
/// Big-endian, which is what `fromBytes` reads.
const R_ORDER_AS_U512: u512 =
    0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001;
const R_ORDER: Fr = Fr.fromBytes(&[_]u8{
    48,  100, 78,  114, 225, 49,  160, 41,
    184, 80,  69,  182, 129, 129, 88,  93,
    40,  51,  232, 72,  121, 185, 112, 145,
    67,  225, 245, 147, 240, 0,   0,   1,
}) catch unreachable;

const scalars = [_]u64{ 1, 2, 3, 4, 7, 15, 16, 255, 256, 65535, 65536 };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    std.debug.print("zig-curve: one group, three paths\n\n", .{});
    std.debug.print("=== the generator is on the curve, and the group is closed ===\n", .{});
    std.debug.print("  generator on y^2 = x^3 + 3: {s}\n", .{if (gen.isOnCurve()) "yes" else "NO"});
    std.debug.print("  2G == G + G (affine vs ladder): {s}\n", .{if (gen.scalarMul(2).eql(gen.add(gen))) "yes" else "NO"});

    // The ladder must agree with repeated addition, which is the reference the
    // library's own tests use.
    std.debug.print("\n=== ladder agrees with naive double-and-add ===\n", .{});
    std.debug.print("  scalar | agree\n", .{});
    var disagreements: usize = 0;
    for (scalars) |k| {
        const fast = gen.scalarMul(@as(u64, k));
        var slow = G1.zero();
        for (0..k) |_| slow = slow.add(gen);
        const ok = fast.eql(slow);
        if (!ok) disagreements += 1;
        std.debug.print("  {d:>6} | {s}\n", .{ k, if (ok) "yes" else "NO" });
    }

    // Zero and the group order are the two boundaries a random sample misses:
    // 0*G is the identity, and r*G is too.
    std.debug.print("\n=== boundaries ===\n", .{});
    std.debug.print("  0 * G is the identity: {s}\n", .{if (gen.scalarMul(0).infinity) "yes" else "NO"});
    try std.testing.expect(gen.scalarMul(0).infinity);

    // The group order, as a field element. [r]G is the identity for the same reason
    // [p]x is zero in a field: it is the modulus of the scalar group.
    std.debug.print("  [r]G is the identity (r = the group order): {s}\n", .{if (gen.scalarMul(R_ORDER_AS_U512).infinity) "yes" else "NO"});

    // Projective and affine are the same point in different coordinates.
    // Projective and affine are the same group in different coordinates: the
    // projective ladder must land where the affine one does.
    const proj2 = gen.toProjective().scalarMul(2);
    std.debug.print("  projective [2]G -> affine equals affine [2]G: {s}\n", .{
        if (proj2.toAffine().eql(gen.scalarMul(2))) "yes" else "NO",
    });

    // MSM against the sum of the individual products.
    std.debug.print("\n=== MSM (Pippenger) against the sum of individual products ===\n", .{});
    const n = 32;
    var pts: [n]G1 = undefined;
    var scs: [n]Fr = undefined;
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const rnd = prng.random();
    for (&pts) |*p| {
        // [k]G for a random k: an affine point, which is what msm takes.
        p.* = gen.scalarMul(@as(u64, rnd.int(u16) + 1));
    }
    for (&scs) |*s| s.* = Fr.fromInt(rnd.int(u16) + 1);

    const batched = try zc.msm.msm(G1, G1Proj, Fr, alloc, &pts, &scs);
    var sum = G1Proj.zero();
    for (pts, scs) |p, s| {
        sum = sum.add(p.scalarMul(s.toU64()).toProjective());
    }
    const ok = batched.toAffine().eql(sum.toAffine());
    std.debug.print("  n={d}: Pippenger equals the naive sum: {s}\n", .{ n, if (ok) "yes" else "NO" });
    try std.testing.expect(ok);

    // A length mismatch is rejected rather than silently truncated.
    std.debug.print("  length mismatch is rejected: {s}\n", .{
        if (zc.msm.msm(G1, G1Proj, Fr, alloc, pts[0 .. n - 1], &scs) == error.LengthMismatch) "yes" else "NO",
    });

    std.debug.print("\n{d} ladder disagreement(s)\n", .{disagreements});
}
