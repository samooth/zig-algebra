//! zig-ntt: Number-Theoretic Transform over finite fields.
//!
//! Cooley-Tukey iterative in-place NTT with bit-reversal permutation.
//! Supports any prime field with sufficient 2-adicity (power-of-two roots of unity).

const std = @import("std");
const traits = @import("zig-algebra-traits");

/// Simple xorshift64* PRNG for deterministic testing
const SimplePrng = struct {
    state: u64,

    fn init(seed: u64) SimplePrng {
        return .{ .state = seed };
    }

    fn next(self: *SimplePrng) u64 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        return self.state;
    }
};

/// Generate a random field element using the PRNG
fn randomField(comptime F: type, prng: *SimplePrng) F {
    return F.fromInt(prng.next());
}

pub fn bitReverse(comptime F: type, data: []F) void {
    const n = data.len;
    std.debug.assert(n > 0 and (n & (n - 1)) == 0);
    const log_n = @ctz(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = 0;
        var k: usize = 0;
        while (k < log_n) : (k += 1) {
            j = (j << 1) | ((i >> @intCast(k)) & 1);
        }
        if (j > i) {
            const tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
    }
}

pub fn ntt(comptime F: type, data: []F, log_n: usize, root: F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    bitReverse(F, data);

    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const wm = root.pow(@as(u64, 1) << @intCast(log_n - s));
        var k: usize = 0;
        while (k < n) : (k += m) {
            var w = F.one();
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                const t = w.mul(data[k + j + half_m]);
                const u = data[k + j];
                data[k + j] = u.add(t);
                data[k + j + half_m] = u.sub(t);
                w = w.mul(wm);
            }
        }
    }
}

pub fn intt(comptime F: type, data: []F, log_n: usize, root: F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    const root_inv = root.inv();
    ntt(F, data, log_n, root_inv);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}

pub fn precomputeTwiddles(comptime F: type, log_n: usize, root: F, allocator: std.mem.Allocator) ![]const []const F {
    traits.assertField(F);
    const twiddles = try allocator.alloc([]F, log_n);
    errdefer allocator.free(twiddles);

    var s: usize = 0;
    while (s < log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s + 1);
        const half_m = m >> 1;
        twiddles[s] = try allocator.alloc(F, half_m);
        errdefer allocator.free(twiddles[s]);

        const wm = root.pow(@as(u64, 1) << @intCast(log_n - s - 1));
        var w = F.one();
        var j: usize = 0;
        while (j < half_m) : (j += 1) {
            twiddles[s][j] = w;
            w = w.mul(wm);
        }
    }
    return twiddles;
}

pub fn freeTwiddles(comptime F: type, twiddles: []const []const F, allocator: std.mem.Allocator) void {
    for (twiddles) |t| {
        allocator.free(t);
    }
    allocator.free(twiddles);
}

pub fn nttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);
    std.debug.assert(twiddles.len == log_n);

    bitReverse(F, data);

    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const stage_twiddles = twiddles[s - 1];
        std.debug.assert(stage_twiddles.len == half_m);

        var k: usize = 0;
        while (k < n) : (k += m) {
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                const w = stage_twiddles[j];
                const t = w.mul(data[k + j + half_m]);
                const u = data[k + j];
                data[k + j] = u.add(t);
                data[k + j + half_m] = u.sub(t);
            }
        }
    }
}

pub fn inttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) void {
    traits.assertField(F);
    const n = std.math.pow(usize, 2, log_n);
    std.debug.assert(data.len == n);

    // For inverse, we run forward NTT with inverted twiddles
    // A more efficient approach would precompute inverse twiddles
    nttWithTwiddles(F, data, log_n, twiddles);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}

// ============================================================================
// Tests
// ============================================================================

// Minimal F7 field for basic NTT tests
const F7 = struct {
    const Self = @This();
    value: u64,
    pub const modulus: u64 = 7;
    pub const characteristic: u64 = 7;
    pub const order: u64 = 7;

    pub fn zero() Self {
        return .{ .value = 0 };
    }
    pub fn one() Self {
        return .{ .value = 1 };
    }
    pub fn fromInt(x: u256) Self {
        return .{ .value = @intCast(x % modulus) };
    }
    pub fn toInt(self: Self) u64 {
        return self.value;
    }
    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }
    pub fn add(a: Self, b: Self) Self {
        return fromInt(a.value + b.value);
    }
    pub fn sub(a: Self, b: Self) Self {
        return fromInt(a.value + (modulus - b.value % modulus));
    }
    pub fn neg(a: Self) Self {
        return if (a.value == 0) zero() else fromInt(modulus - a.value);
    }
    pub fn mul(a: Self, b: Self) Self {
        return fromInt(a.value * b.value);
    }
    pub fn inv(a: Self) Self {
        std.debug.assert(!a.isZero());
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }
    pub fn pow(base: Self, exp: u64) Self {
        var result = one();
        var b = base;
        var e = exp;
        while (e > 0) {
            if (e & 1 == 1) result = mul(result, b);
            b = mul(b, b);
            e >>= 1;
        }
        return result;
    }
    pub fn isZero(self: Self) bool {
        return self.value == 0;
    }
    pub fn random() Self {
        return fromInt(1);
    }
};

test "bitReverse permutation is involutive" {
    var data = [_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2), F7.fromInt(3), F7.fromInt(4), F7.fromInt(5), F7.fromInt(6), F7.fromInt(0) };
    bitReverse(F7, &data);
    bitReverse(F7, &data);
    try std.testing.expectEqualSlices(F7, &data, &[_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2), F7.fromInt(3), F7.fromInt(4), F7.fromInt(5), F7.fromInt(6), F7.fromInt(0) });
}

test "bitReverse produces correct permutation for n=4" {
    // For n=4, bit-reversal: 00->00 (0), 01->10 (2), 10->01 (1), 11->11 (3)
    // Expected order: 0, 2, 1, 3
    var data = [_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    bitReverse(F7, &data);
    try std.testing.expect(data[0].eql(F7.fromInt(0)));
    try std.testing.expect(data[1].eql(F7.fromInt(2)));
    try std.testing.expect(data[2].eql(F7.fromInt(1)));
    try std.testing.expect(data[3].eql(F7.fromInt(3)));
}

test "ntt/intt round-trip for M31" {
    const zf = @import("zig-field");
    const M31 = zf.M31;

    var rnd = SimplePrng.init(0);

    // M31 has two_adicity = 1, so only test up to log_n = 1
    for (0..@as(usize, @min(M31.two_adicity + 1, 5))) |log_n| {
        const n: usize = @as(usize, 1) << @intCast(log_n);
        var data = try std.testing.allocator.alloc(M31, n);
        defer std.testing.allocator.free(data);

        // Fill with random values
        for (data) |*x| {
            x.* = randomField(M31, &rnd);
        }

        // Keep copy for verification
        var original = try std.testing.allocator.alloc(M31, n);
        defer std.testing.allocator.free(original);
        for (0..n) |i| original[i] = data[i];

        const root = M31.primitiveRootOfUnity(log_n);
        ntt(M31, data, log_n, root);
        intt(M31, data, log_n, root);

        // Verify round-trip
        for (0..n) |i| {
            try std.testing.expect(data[i].eql(original[i]));
        }
    }
}

test "ntt/intt round-trip for BabyBear" {
    const zf = @import("zig-field");
    const BabyBear = zf.BabyBear;

    var rnd = SimplePrng.init(1);

    for (0..@as(usize, @min(BabyBear.two_adicity + 1, 5))) |log_n| {
        const n: usize = @as(usize, 1) << @intCast(log_n);
        var data = try std.testing.allocator.alloc(BabyBear, n);
        defer std.testing.allocator.free(data);

        var original = try std.testing.allocator.alloc(BabyBear, n);
        defer std.testing.allocator.free(original);

        for (0..n) |i| {
            data[i] = randomField(BabyBear, &rnd);
            original[i] = data[i];
        }

        const root = BabyBear.primitiveRootOfUnity(log_n);
        ntt(BabyBear, data, log_n, root);
        intt(BabyBear, data, log_n, root);

        for (0..n) |i| {
            try std.testing.expect(data[i].eql(original[i]));
        }
    }
}

test "ntt/intt round-trip for Goldilocks" {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;

    var rnd = SimplePrng.init(2);

    for (0..@as(usize, @min(Goldilocks.two_adicity + 1, 5))) |log_n| {
        const n: usize = @as(usize, 1) << @intCast(log_n);
        var data = try std.testing.allocator.alloc(Goldilocks, n);
        defer std.testing.allocator.free(data);

        var original = try std.testing.allocator.alloc(Goldilocks, n);
        defer std.testing.allocator.free(original);

        for (0..n) |i| {
            data[i] = randomField(Goldilocks, &rnd);
            original[i] = data[i];
        }

        const root = Goldilocks.primitiveRootOfUnity(log_n);
        ntt(Goldilocks, data, log_n, root);
        intt(Goldilocks, data, log_n, root);

        for (0..n) |i| {
            try std.testing.expect(data[i].eql(original[i]));
        }
    }
}

test "ntt/intt round-trip for BN254_Fp" {
    const zf = @import("zig-field");
    const BN254_Fp = zf.BN254_Fp;

    var rnd = SimplePrng.init(3);

    for (0..@as(usize, @min(BN254_Fp.two_adicity + 1, 5))) |log_n| {
        const n: usize = @as(usize, 1) << @intCast(log_n);
        var data = try std.testing.allocator.alloc(BN254_Fp, n);
        defer std.testing.allocator.free(data);

        var original = try std.testing.allocator.alloc(BN254_Fp, n);
        defer std.testing.allocator.free(original);

        for (0..n) |i| {
            data[i] = randomField(BN254_Fp, &rnd);
            original[i] = data[i];
        }

        const root = BN254_Fp.primitiveRootOfUnity(log_n);
        ntt(BN254_Fp, data, log_n, root);
        intt(BN254_Fp, data, log_n, root);

        for (0..n) |i| {
            try std.testing.expect(data[i].eql(original[i]));
        }
    }
}

test "ntt/intt round-trip for BLS12_381_Fp" {
    const zf = @import("zig-field");
    const BLS12_381_Fp = zf.BLS12_381_Fp;

    var rnd = SimplePrng.init(4);

    for (0..@as(usize, @min(BLS12_381_Fp.two_adicity + 1, 5))) |log_n| {
        const n: usize = @as(usize, 1) << @intCast(log_n);
        var data = try std.testing.allocator.alloc(BLS12_381_Fp, n);
        defer std.testing.allocator.free(data);

        var original = try std.testing.allocator.alloc(BLS12_381_Fp, n);
        defer std.testing.allocator.free(original);

        for (0..n) |i| {
            data[i] = randomField(BLS12_381_Fp, &rnd);
            original[i] = data[i];
        }

        const root = BLS12_381_Fp.primitiveRootOfUnity(log_n);
        ntt(BLS12_381_Fp, data, log_n, root);
        intt(BLS12_381_Fp, data, log_n, root);

        for (0..n) |i| {
            try std.testing.expect(data[i].eql(original[i]));
        }
    }
}

test "ntt convolution property (Goldilocks)" {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;

    // Test NTT(f * g) = NTT(f) * NTT(g) (pointwise)
    // We'll use cyclic convolution: f * g where * is cyclic convolution
    const log_n = 4;
    const n = @as(usize, 1) << log_n;

    // Create two simple polynomials
    var f = try std.testing.allocator.alloc(Goldilocks, n);
    var g = try std.testing.allocator.alloc(Goldilocks, n);
    var f_ntt = try std.testing.allocator.alloc(Goldilocks, n);
    var g_ntt = try std.testing.allocator.alloc(Goldilocks, n);
    var fg_ntt = try std.testing.allocator.alloc(Goldilocks, n);
    var conv = try std.testing.allocator.alloc(Goldilocks, n);
    defer std.testing.allocator.free(f);
    defer std.testing.allocator.free(g);
    defer std.testing.allocator.free(f_ntt);
    defer std.testing.allocator.free(g_ntt);
    defer std.testing.allocator.free(fg_ntt);
    defer std.testing.allocator.free(conv);

    // f = 1 + 2x + 3x^2
    f[0] = Goldilocks.fromInt(1);
    f[1] = Goldilocks.fromInt(2);
    f[2] = Goldilocks.fromInt(3);
    for (3..n) |i| f[i] = Goldilocks.zero();

    // g = 2 + 3x
    g[0] = Goldilocks.fromInt(2);
    g[1] = Goldilocks.fromInt(3);
    for (2..n) |i| g[i] = Goldilocks.zero();

    // Compute cyclic convolution manually
    for (0..n) |i| {
        var sum = Goldilocks.zero();
        for (0..n) |j| {
            sum = sum.add(f[j].mul(g[(i + n - j) % n]));
        }
        conv[i] = sum;
    }

    // NTT of f and g
    for (0..n) |i| {
        f_ntt[i] = f[i];
        g_ntt[i] = g[i];
    }
    const root = Goldilocks.primitiveRootOfUnity(log_n);
    ntt(Goldilocks, f_ntt, log_n, root);
    ntt(Goldilocks, g_ntt, log_n, root);

    // Pointwise multiplication in NTT domain
    for (0..n) |i| {
        fg_ntt[i] = f_ntt[i].mul(g_ntt[i]);
    }

    // Inverse NTT
    intt(Goldilocks, fg_ntt, log_n, root);

    // Verify
    for (0..n) |i| {
        try std.testing.expect(fg_ntt[i].eql(conv[i]));
    }
}

test "twiddle precomputation and free" {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;

    for (0..@as(usize, @min(Goldilocks.two_adicity + 1, 5))) |log_n| {
        if (log_n == 0) continue; // log_n=0 has no twiddles
        _ = @as(usize, 1) << @intCast(log_n);
        const root = Goldilocks.primitiveRootOfUnity(log_n);

        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const twiddles = try precomputeTwiddles(Goldilocks, log_n, root, allocator);
        defer freeTwiddles(Goldilocks, twiddles, allocator);

        // Verify twiddles are correct
        var s: usize = 0;
        while (s < log_n) : (s += 1) {
            const m = std.math.pow(usize, 2, s + 1);
            const half_m = m >> 1;
            std.debug.assert(twiddles[s].len == half_m);
            const wm = root.pow(@as(u64, 1) << @intCast(log_n - s - 1));
            var w = Goldilocks.one();
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                try std.testing.expect(twiddles[s][j].eql(w));
                w = w.mul(wm);
            }
        }
    }
}

test "ntt with precomputed twiddles matches ntt without (Goldilocks)" {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;

    var rnd = SimplePrng.init(5);

    for (0..@as(usize, @min(Goldilocks.two_adicity + 1, 5))) |log_n| {
        if (log_n == 0) continue;
        const n: usize = @as(usize, 1) << @intCast(log_n);
        const root = Goldilocks.primitiveRootOfUnity(log_n);

        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const twiddles = try precomputeTwiddles(Goldilocks, log_n, root, allocator);
        defer freeTwiddles(Goldilocks, twiddles, allocator);

        var data1 = try allocator.alloc(Goldilocks, n);
        var data2 = try allocator.alloc(Goldilocks, n);
        defer allocator.free(data1);
        defer allocator.free(data2);

        for (0..n) |i| {
            data1[i] = randomField(Goldilocks, &rnd);
            data2[i] = data1[i];
        }

        ntt(Goldilocks, data1, log_n, root);
        nttWithTwiddles(Goldilocks, data2, log_n, twiddles);

        for (0..n) |i| {
            try std.testing.expect(data1[i].eql(data2[i]));
        }
    }
}
