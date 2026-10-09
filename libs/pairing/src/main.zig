//! zig-pairing example.
//!
//! Bilinearity is the property the pairing exists for, so it is asserted rather
//! than printed: e(aP, bQ) must equal e(P, Q)^(a*b), and the two sides are
//! computed from *different* arguments (2,3 against 1,6). Comparing the same
//! path on the same argument cancels the error and passes against a pairing that
//! computes the wrong value, which is what happened here.

const std = @import("std");
const testing = std.testing;
const pairing = @import("zig-pairing");
const zc = @import("zig-curve");

pub fn main() !void {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;

    const e = pairing.bls12_381_pairing_impl.pairing(g1, g2);
    std.debug.print("BLS12-381 pairing(G1, G2) = {}\n", .{e});
    // Non-degeneracy: the pairing of the generators is not the identity.
    try testing.expect(!e.eql(@TypeOf(e).one()));

    const p2 = g1.scalarMul(2);
    const q3 = g2.scalarMul(3);
    const e23 = pairing.bls12_381_pairing_impl.pairing(p2, q3);
    const e1_6 = e.powFast(6);

    std.debug.print("e(2P, 3Q) = {}\n", .{e23});
    std.debug.print("e(P, Q)^6 = {}\n", .{e1_6});
    std.debug.print("Bilinearity holds: {}\n", .{e23.eql(e1_6)});
    try testing.expect(e23.eql(e1_6));

    const bn_g1 = zc.bn254.G1_generator;
    const bn_g2 = zc.bn254.G2_generator;
    const bn_e = pairing.bn254_pairing.pairing(bn_g1, bn_g2);
    std.debug.print("BN254 pairing = {}\n", .{bn_e});
    try testing.expect(!bn_e.eql(@TypeOf(bn_e).one()));
}
