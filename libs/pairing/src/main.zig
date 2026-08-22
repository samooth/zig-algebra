const std = @import("std");
const pairing = @import("zig-pairing");
const zc = @import("zig-curve");

const BLS12_381_G1 = zc.BLS12_381.G1;
const BLS12_381_G2 = zc.BLS12_381.G2;

pub fn main() !void {
    const std = @import("std");
    const pairing = @import("zig-pairing");

    const G1 = BLS12_381_G1.generator();
    const G2 = BLS12_381_G2.generator();

    const e = pairing.bls12_381_pairing(G1, G2);
    std.debug.print("BLS12-381 pairing(G1, G2) = {}\n", .{e});

    // Bilinearity test: e(a*P, b*Q) = e(P, Q)^(a*b)
    const P2 = G1.mulScalar(2);
    const Q3 = G2.mulScalar(3);
    const e23 = pairing.bls12_381_pairing(P2, Q3);

    const e1 = pairing.bls12_381_pairing(G1, G2);
    const e1_6 = e1.pow(6);

    std.debug.print("e(2P, 3Q) = {}\n", .{e23});
    std.debug.print("e(P, Q)^6 = {}\n", .{e1_6});
    std.debug.print("Bilinearity holds: {}\n", .{e23.eql(e1_6)});

    // BN254 pairing
    const zc = @import("zig-curve");
    const bnG1 = zc.BN254_G1.generator();
    const bnG2 = zc.BN254_G2.generator();
    const bn_e = pairing.bn254_pairing(bnG1, bnG2);
    std.debug.print("BN254 pairing = {}\n", .{bn_e});
}
