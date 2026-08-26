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

const nowNs = @import("zig-parallel").timing.nowNs;

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
const curve_msm = @import("zig-curve").msm;
const ntt_mod = @import("zig-ntt");

// --- NTT 2^20 over BN254 Fr (2-adicity 28; M31 has 2-adicity 1) ---

const FrScalar = zf.Field(0x30644E72E131A029B85045B68181585D2833E84879B9709143E1F593F0000001);

var ntt_buf: []FrScalar = &.{};
var ntt_tw: []const []const FrScalar = &.{};

fn nttSetup() void {
    if (ntt_buf.len != 0) return;
    const F = FrScalar;
    ntt_buf = std.heap.page_allocator.alloc(F, 1 << 20) catch @panic("oom");
    for (ntt_buf, 0..) |*x, i| x.* = F.fromInt(@as(u64, i % 1000));
    const root = F.rootOfUnity(ntt_buf.len);
    ntt_tw = ntt_mod.precomputeTwiddles(F, 20, root, std.heap.page_allocator) catch @panic("oom");
}

fn nttFr() void {
    nttSetup();
    ntt_mod.nttWithTwiddles(FrScalar, ntt_buf, 20, ntt_tw);
    sink ^= @intFromBool(ntt_buf[0].isZero());
}

// --- MSM 2^16 with Pippenger ---

const Msm16kState = struct {
    var pts: [65536]zc.bn254.G1 = undefined;
    var scs: [65536]zc.bn254.Fr = undefined;
    var ready = false;

    fn setup() void {
        if (ready) return;
        // Points: successive additions generate (i+1)*G cheaply.
        var p = zc.bn254.G1_generator;
        for (&pts, 0..) |*pt, i| {
            pt.* = p;
            p = p.add(zc.bn254.G1_generator);
            scs[i] = zc.bn254.Fr.fromInt(@as(u64, i *% 2654435761 +% 12345));
        }
        ready = true;
    }
};

fn msmPippenger64k() void {
    Msm16kState.setup();
    const r = curve_msm.msm(
        zc.bn254.G1,
        zc.bn254.G1Projective,
        zc.bn254.Fr,
        std.heap.page_allocator,
        &Msm16kState.pts,
        &Msm16kState.scs,
    ) catch return;
    sink ^= @intFromBool(r.isZero());
}

fn msmNaive() void {
    const Fr = zc.bn254.Fr;
    var acc = zc.bn254.G1Projective.zero();
    for (0..256) |i| {
        const p = zc.bn254.G1_generator.scalarMul(@as(u64, i * 7 + 1));
        const s64: u64 = @intCast(Fr.fromInt(@as(u64, i * 2654435761 % 1000000007)).toU64());
        acc = acc.add(G1PFromAff(p).scalarMul(s64));
    }
    sink ^= @intFromBool(acc.isZero());
}

fn G1PFromAff(p: zc.bn254.G1) zc.bn254.G1Projective {
    return .{ .x = p.x, .y = p.y, .z = zf.BN254_Fp.one() };
}

fn msmPippenger() void {
    const Fr = zc.bn254.Fr;
    var pts: [256]zc.bn254.G1 = undefined;
    var scs: [256]Fr = undefined;
    for (0..256) |i| {
        pts[i] = zc.bn254.G1_generator.scalarMul(@as(u64, i * 7 + 1));
        scs[i] = Fr.fromInt(@as(u64, i * 2654435761 % 1000000007));
    }
    const r = curve_msm.msm(zc.bn254.G1, zc.bn254.G1Projective, Fr, std.heap.page_allocator, &pts, &scs) catch return;
    sink ^= @intFromBool(r.isZero());
}

fn pairingBnTower() void {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const e = bn_tower.pairing(g1, g2);
    sink ^= @intFromBool(e.isZero());
}

fn pairingBnTowerSparse() void {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const e = bn_tower.pairingSparse(g1, g2);
    sink ^= @intFromBool(e.isZero());
}

fn pairingBnTowerDense() void {
    const g1 = zc.bn254.G1_generator;
    const g2 = zc.bn254.G2_generator;
    const e = bn_tower.pairingDense(g1, g2);
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
    _ = bench("BN254 tower sparse loop", 5, pairingBnTowerSparse);
    _ = bench("BN254 tower dense ref", 5, pairingBnTowerDense);
    _ = bench("MSM n=256 naive", 20, msmNaive);
    _ = bench("MSM n=256 pippenger", 200, msmPippenger);
    _ = bench("MSM n=65536 pippenger", 10, msmPippenger64k);
    _ = bench("NTT 2^20 Fr (twiddles)", 5, nttFr);

    std.debug.print("\n(sink={d})\n", .{sink & 1});
}
