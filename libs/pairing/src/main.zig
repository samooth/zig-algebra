const std = @import("std");
const pairing = @import("zig-pairing");
const zc = @import("zig-curve");

pub fn main() !void {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;

    const e = pairing.bls12_381_pairing_impl.pairing(g1, g2);
    std.debug.print("BLS12-381 pairing(G1, G2) = {}\n", .{e});

    const p2 = g1.scalarMul(2);
    const q3 = g2.scalarMul(3);
    const e23 = pairing.bls12_381_pairing_impl.pairing(p2, q3);
    const e1_6 = e.powFast(6);

    std.debug.print("e(2P, 3Q) = {}\n", .{e23});
    std.debug.print("e(P, Q)^6 = {}\n", .{e1_6});
    std.debug.print("Bilinearity holds: {}\n", .{e23.eql(e1_6)});

    const bn_g1 = zc.bn254.G1_generator;
    const bn_g2 = zc.bn254.G2_generator;
    const bn_e = pairing.bn254_pairing.pairing(bn_g1, bn_g2);
    std.debug.print("BN254 pairing = {}\n", .{bn_e});
}
