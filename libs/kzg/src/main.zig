//! zig-kzg consumer: commit, open at a point, and check the two things that can go
//! wrong.
//!
//! KZG's soundness rests on the setup. `Setup.generate` takes a caller-supplied
//! `tau` and publishes it in the source, so **the discrete log of every commitment
//! is known** and the scheme is not binding. That is stated in the README and it
//! is not a footnote: it means this example, and every test in this library,
//! demonstrates that the *arithmetic* is right, not that a proof has been kept.
//! A deployment needs a powers-of-tau ceremony with the toxic waste destroyed.
//!
//! So the example checks the arithmetic both ways. A correct opening verifies --
//! which is the half that makes the negative mean anything -- and then a wrong
//! evaluation point does not, and an off-curve commitment does not either. Both of
//! those guards exist in `verify` and were the two `kzg` guards the mutation log
//! recorded as dead code; nothing in the tree called them.

const std = @import("std");
const testing = std.testing;
const kzg = @import("zig-kzg");
const zc = @import("zig-curve");

const Fr = zc.bn254.Fr;
const G1 = zc.bn254.G1;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A tau chosen by the caller -- and readable in this file, which is the whole
    // reason the setup is labelled tests/dev only.
    const tau = Fr.fromInt(0xfeed_beef);
    const max_degree = 16;
    var setup = try kzg.Setup.generate(alloc, tau, max_degree);
    defer setup.deinit();

    // p(x) = 3 + 5x + 7x^2
    const coeffs = [_]Fr{ Fr.fromInt(3), Fr.fromInt(5), Fr.fromInt(7) };
    const commitment = try kzg.commit(&setup, alloc, &coeffs);

    std.debug.print("zig-kzg over BN254, max_degree={d}\n\n", .{max_degree});
    try std.testing.expect(commitment.isOnCurve());
    std.debug.print("  commitment on curve: {s}\n", .{if (commitment.isOnCurve()) "yes" else "NO"});

    const z = Fr.fromInt(11);
    const y = kzg.evaluate(&coeffs, z);
    std.debug.print("  p(11) computed locally: {d}\n", .{y.toU64()});

    // The honest case first, because everything below is measured against it.
    {
        const opening = try kzg.prove(&setup, alloc, &coeffs, z);
        const witness = opening.witness;
        const ok = kzg.verify(&setup, commitment, z, y, witness);
        try std.testing.expect(ok);
        std.debug.print("\n  correct opening verifies:        {s}\n", .{if (ok) "yes" else "NO"});
    }

    // A wrong claimed value. The pairing equation is what rejects it.
    {
        const y_wrong = y.add(Fr.one());
        const opening = try kzg.prove(&setup, alloc, &coeffs, z);
        const witness = opening.witness;
        const ok = kzg.verify(&setup, commitment, z, y_wrong, witness);
        try std.testing.expect(!ok);
        std.debug.print("  wrong claimed value rejected:   {s}\n", .{if (!ok) "yes" else "NO"});
    }

    // An off-curve commitment. This is one of the two guards the mutation log
    // recorded as dead code, because nothing called them -- they are now reachable
    // from a consumer, which is the point of an example.
    {
        var bad = commitment;
        bad.x = bad.x.add(kzg.Fp.one()); // moves it off y^2 = x^3 + 3
        const opening = try kzg.prove(&setup, alloc, &coeffs, z);
        const witness = opening.witness;
        const ok = kzg.verify(&setup, bad, z, y, witness);
        try std.testing.expect(!ok);
        std.debug.print("  off-curve commitment rejected:  {s}\n", .{if (!ok) "yes" else "NO"});
    }

    // A point at infinity: the branch that substitutes the identity, which no
    // other case reaches.
    {
        const infinity = G1.zero();
        const opening = try kzg.prove(&setup, alloc, &coeffs, z);
        const witness = opening.witness;
        const ok = kzg.verify(&setup, infinity, z, y, witness);
        try std.testing.expect(!ok);
        std.debug.print("  identity commitment rejected:   {s}\n", .{if (!ok) "yes" else "NO"});
    }

    // The zero polynomial: both points are the point at infinity, and it is the
    // branch no other case reaches.
    {
        const zero_coeffs = [_]Fr{Fr.zero()};
        const c0 = try kzg.commit(&setup, alloc, &zero_coeffs);
        const opening0 = try kzg.prove(&setup, alloc, &zero_coeffs, z);
        const w0 = opening0.witness;
        const ok = kzg.verify(&setup, c0, z, Fr.zero(), w0);
        try std.testing.expect(ok);
        std.debug.print("  zero polynomial verifies:       {s}\n", .{if (ok) "yes" else "NO"});
    }

    // Degree beyond the setup is rejected rather than silently truncated.
    {
        var big: [max_degree + 2]Fr = undefined; // degree 17, one past the setup
        for (&big) |*c| c.* = Fr.one();
        const e = kzg.commit(&setup, alloc, &big);
        try std.testing.expect(e == error.DegreeExceedsSetup);
        std.debug.print("  degree beyond setup rejected:   {s}\n", .{if (e == error.DegreeExceedsSetup) "yes" else "NO"});
    }

    std.debug.print("\n  NOTE: this setup's tau is in the source. The scheme is not binding.\n", .{});
    std.debug.print("  A deployment needs a powers-of-tau ceremony.\n", .{});
}
