const std = @import("std");
const pairing_impl = @import("bls12_381.zig");
const zf = @import("zig-field");
const zc = @import("zig-curve");

const Fp = zf.BLS12_381_Fp;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec)));
}

pub fn main() !void {
    const g1 = zc.bls12_381.G1_generator;
    const g2 = zc.bls12_381.G2_generator;

    // Warm up
    _ = pairing_impl.pairing(g1, g2);

    const iterations: usize = 10;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = pairing_impl.pairing(g1, g2);
    }
    const t1 = nowNs();
    const pair_ns = (t1 - t0) / iterations;

    // Field mul benchmark
    const a = Fp.fromInt(12345);
    const b = Fp.fromInt(67890);
    var sink: usize = 0;
    const t2 = nowNs();
    for (0..10000) |_| {
        var prod = a.mul(b);
        prod = prod.mul(prod);
        sink ^= @intFromBool(prod.isZero());
    }
    const t3 = nowNs();
    const fpmul_ns = (t3 - t2) / 10000;

    // Fp2 mul benchmark
    const Fp2 = zc.bls12_381.Fp2;
    const fa = Fp2.new(Fp.fromInt(3), Fp.fromInt(5));
    const fb = Fp2.new(Fp.fromInt(7), Fp.fromInt(11));
    const t4 = nowNs();
    for (0..10000) |_| {
        var prod = fa.mul(fb);
        prod = prod.mul(prod);
        sink ^= @intFromBool(prod.isZero());
    }
    const t5 = nowNs();
    const fp2mul_ns = (t5 - t4) / 10000;

    std.debug.print("\n=== BLS12-381 benchmarks ===\n", .{});
    std.debug.print("pairing:         {d:>8} µs\n", .{pair_ns / 1000});
    std.debug.print("Fp mul:          {d:>8} ns\n", .{fpmul_ns});
    std.debug.print("Fp2 mul:         {d:>8} ns\n", .{fp2mul_ns});
}
