// SPDX-License-Identifier: MIT OR Apache-2.0

const std = @import("std");
const h2c = @import("zig-curve").hash_to_curve;
const bn254 = @import("zig-curve").bn254;
const pasta = @import("zig-curve").pasta;

test "hashToField BN254_Fp produces valid elements" {
    const us = h2c.hashToField(bn254.Fp, "hello world", "BN254_G1_XMD:SHA-256_SSWU_RO_", 2);
    const bytes0 = us[0].toBytes();
    const bytes1 = us[1].toBytes();
    std.debug.assert(bytes0.len == 32);
    std.debug.assert(bytes1.len == 32);
}

test "hashToField is deterministic" {
    const us1 = h2c.hashToField(bn254.Fp, "test", "dst", 2);
    const us2 = h2c.hashToField(bn254.Fp, "test", "dst", 2);
    std.debug.assert(us1[0].eql(us2[0]));
    std.debug.assert(us1[1].eql(us2[1]));
}

test "hashToField different messages produce different elements" {
    const us1 = h2c.hashToField(bn254.Fp, "message1", "dst", 1);
    const us2 = h2c.hashToField(bn254.Fp, "message2", "dst", 1);
    std.debug.assert(!us1[0].eql(us2[0]));
}

test "mapToCurveSvdW produces valid BN254 points" {
    const u = bn254.Fp.fromInt(42);
    const p = try h2c.mapToCurveSvdW(bn254.Fp, bn254.G1_a, bn254.G1_b, u);

    // Verify: y^2 = x^3 + a*x + b
    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(bn254.G1_a.mul(p.x)).add(bn254.G1_b);
    std.debug.assert(y2.eql(rhs));
}

test "mapToCurveSvdW is deterministic" {
    const u = bn254.Fp.fromInt(123);
    const p1 = try h2c.mapToCurveSvdW(bn254.Fp, bn254.G1_a, bn254.G1_b, u);
    const p2 = try h2c.mapToCurveSvdW(bn254.Fp, bn254.G1_a, bn254.G1_b, u);
    std.debug.assert(p1.x.eql(p2.x));
    std.debug.assert(p1.y.eql(p2.y));
}

test "mapToCurveSvdW zero maps to valid point" {
    const u = bn254.Fp.zero();
    const p = try h2c.mapToCurveSvdW(bn254.Fp, bn254.G1_a, bn254.G1_b, u);

    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(bn254.G1_b);
    std.debug.assert(y2.eql(rhs));
}

test "mapToCurveSvdW one maps to valid point" {
    const u = bn254.Fp.one();
    const p = try h2c.mapToCurveSvdW(bn254.Fp, bn254.G1_a, bn254.G1_b, u);

    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(bn254.G1_b);
    std.debug.assert(y2.eql(rhs));
}

test "hashToCurve produces valid BN254 points" {
    const p = try h2c.hashToCurve(bn254.Fp, bn254.G1_a, bn254.G1_b, "hello", "BN254_G1_XMD:SHA-256_SSWU_RO_");

    // Verify: y^2 = x^3 + b
    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(bn254.G1_b);
    std.debug.assert(y2.eql(rhs));
}

test "hashToCurve is deterministic" {
    const p1 = try h2c.hashToCurve(bn254.Fp, bn254.G1_a, bn254.G1_b, "test", "dst");
    const p2 = try h2c.hashToCurve(bn254.Fp, bn254.G1_a, bn254.G1_b, "test", "dst");
    std.debug.assert(p1.x.eql(p2.x));
    std.debug.assert(p1.y.eql(p2.y));
}

test "hashToCurve different messages produce different points" {
    const p1 = try h2c.hashToCurve(bn254.Fp, bn254.G1_a, bn254.G1_b, "message1", "dst");
    const p2 = try h2c.hashToCurve(bn254.Fp, bn254.G1_a, bn254.G1_b, "message2", "dst");
    std.debug.assert(!p1.x.eql(p2.x) or !p1.y.eql(p2.y));
}

test "mapToCurveSvdW Pasta Pallas" {
    const u = pasta.PallasFp.fromInt(7);
    const p = try h2c.mapToCurveSvdW(pasta.PallasFp, pasta.Pallas_a, pasta.Pallas_b, u);

    // Verify: y^2 = x^3 + a*x + b
    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(pasta.Pallas_a.mul(p.x)).add(pasta.Pallas_b);
    std.debug.assert(y2.eql(rhs));
}

test "hashToCurve Pasta Pallas" {
    const p = try h2c.hashToCurve(pasta.PallasFp, pasta.Pallas_a, pasta.Pallas_b, "test", "PALLAS_G1_XMD:SHA-256_SSWU_RO_");

    // Verify: y^2 = x^3 + b
    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(pasta.Pallas_b);
    std.debug.assert(y2.eql(rhs));
}

test "mapToCurveSvdW BLS12-381" {
    const bls = @import("zig-curve").bls12_381;
    const u = bls.Fp.fromInt(99);
    const p = try h2c.mapToCurveSvdW(bls.Fp, bls.G1_a, bls.G1_b, u);

    // Verify: y^2 = x^3 + b
    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(bls.G1_b);
    std.debug.assert(y2.eql(rhs));
}

test "mapToCurveSvdW BLS12-381 various inputs" {
    const bls = @import("zig-curve").bls12_381;
    const inputs = [_]u64{ 0, 1, 2, 7, 42, 99, 1000 };
    for (inputs) |i| {
        const u = bls.Fp.fromInt(i);
        const p = try h2c.mapToCurveSvdW(bls.Fp, bls.G1_a, bls.G1_b, u);

        const y2 = p.y.mul(p.y);
        const x3 = p.x.mul(p.x).mul(p.x);
        const rhs = x3.add(bls.G1_b);
        std.debug.assert(y2.eql(rhs));
    }
}

test "hashToCurve BLS12-381" {
    const bls = @import("zig-curve").bls12_381;
    const p = try h2c.hashToCurve(bls.Fp, bls.G1_a, bls.G1_b, "test", "BLS12381_G1_XMD:SHA-256_SSWU_RO_");

    // Verify: y^2 = x^3 + b
    const y2 = p.y.mul(p.y);
    const x3 = p.x.mul(p.x).mul(p.x);
    const rhs = x3.add(bls.G1_b);
    std.debug.assert(y2.eql(rhs));
}
