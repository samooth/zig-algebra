const std = @import("std");
const pairing_impl = @import("bls12_381.zig");
const zf = @import("zig-field");
const zc = @import("zig-curve");

const Fp = zf.BLS12_381_Fp;
const Fp2 = zc.bls12_381.Fp2;
const G1Point = zc.bls12_381.G1;
const G2Point = zc.bls12_381.G2;
const Fp12 = pairing_impl.Fp12;

var sink: usize = 0;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec)));
}

fn bench(comptime name: []const u8, iterations: usize, comptime func: fn () void) u64 {
    // Warm up
    for (0..3) |_| func();
    const t0 = nowNs();
    for (0..iterations) |_| func();
    const dt = (nowNs() - t0) / iterations;
    std.debug.print("{s:<28} {d:>10} ns\n", .{ name, dt });
    return dt;
}

// --- Bench functions ---

fn fpMulSmall() void {
    // M31: 31-bit Mersenne prime
    const M31 = zf.M31;
    var a = M31.fromInt(123456789);
    var b = M31.fromInt(987654321);
    a = a.mul(b);
    b = b.mul(a);
    sink ^= @intFromBool(a.isZero());
}

fn fpMulBig() void {
    var a = Fp.fromInt(0xDEADBEEF);
    var b = Fp.fromInt(0xCAFEBABE);
    a = a.mul(b);
    b = b.mul(a);
    sink ^= @intFromBool(a.isZero());
}

fn fpInvBig() void {
    var a = Fp.fromInt(0xDEADBEEF);
    a = a.inv();
    sink ^= @intFromBool(a.isZero());
}

fn fp2Mul() void {
    var a = Fp2.new(Fp.fromInt(3), Fp.fromInt(5));
    var b = Fp2.new(Fp.fromInt(7), Fp.fromInt(11));
    a = a.mul(b);
    b = b.mul(a);
    sink ^= @intFromBool(a.isZero());
}

fn fp12Mul() void {
    // Build two non-trivial Fp12 elements from G2 coordinates
    const g2 = zc.bls12_381.G2_generator;
    var a = Fp12{ .c0 = pairing_impl.Fp6.fromFp2(g2.x), .c1 = pairing_impl.Fp6.fromFp2(g2.y) };
    var b = Fp12{ .c0 = pairing_impl.Fp6.fromFp2(g2.y), .c1 = pairing_impl.Fp6.fromFp2(g2.x) };
    a = a.mul(b);
    b = b.mul(a);
    sink ^= @intFromBool(a.isZero());
}

fn curveScalarMul() void {
    const g1 = zc.bls12_381.G1_generator;
    _ = g1.scalarMul(@as(u64, 0xDEADBEEF));
}

fn pairingBls() void {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;
    const e = pairing_impl.pairing(g1, g2);
    sink ^= @intFromBool(e.isZero());
}

const bn_direct = @import("bn254_direct.zig");
const bn_tower = @import("bn254_tower.zig");

fn pairingBnTower() void {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const e = bn_tower.pairing(g1, g2);
    sink ^= @intFromBool(e.isZero());
}

fn pairingBn() void {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const e = bn_direct.pairing(g1, g2);
    sink ^= @intFromBool(e.isZero());
}

pub fn main() !void {
    std.debug.print("\n=== zig-algebra benchmarks ===\n\n", .{});

    std.debug.print("--- Field arithmetic ---\n", .{});
    _ = bench("M31 mul (SmallField)", 1_000_000, fpMulSmall);
    _ = bench("BLS12-381 Fp mul (BigField)", 100_000, fpMulBig);
    _ = bench("BLS12-381 Fp inv", 10_000, fpInvBig);
    _ = bench("Fp2 mul", 100_000, fp2Mul);
    _ = bench("Fp12 mul", 50_000, fp12Mul);

    std.debug.print("\n--- Curve ---\n", .{});
    _ = bench("BLS12-381 scalarMul [k]G1", 1_000, curveScalarMul);

    std.debug.print("\n--- Pairing ---\n", .{});
    _ = bench("BLS12-381 optimal ate", 20, pairingBls);
    _ = bench("BN254 ate (direct deg-12)", 5, pairingBn);
    _ = bench("BN254 optimal ate (tower)", 5, pairingBnTower);

    std.debug.print("\n(sink={d})\n", .{sink & 1});
}
