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

/// `2^log_n` with a real bounds check. The old code called
/// `std.math.pow(usize, 2, log_n)` directly, which overflows (and traps) for
/// `log_n >= @bitSizeOf(usize)`.
fn sizeFromLog(log_n: usize) error{LogTooLarge}!usize {
    if (log_n >= @bitSizeOf(usize)) return error.LogTooLarge;
    return @as(usize, 1) << @intCast(log_n);
}

pub fn bitReverse(comptime F: type, data: []F) error{InvalidLength}!void {
    const n = data.len;
    // The old `std.debug.assert` is compiled out in `ReleaseFast`, where
    // `@ctz(0)` on an empty slice is undefined and a non-power-of-two length
    // walks off the end of the permutation.
    if (n == 0 or (n & (n - 1)) != 0) return error.InvalidLength;
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

/// # Errors
/// `error.LogTooLarge` when `log_n` is too large for `usize` to hold
/// `2^log_n`, and `error.LengthMismatch` when `data.len != 2^log_n`. The
/// old `std.debug.assert` is compiled out in `ReleaseFast`, where the
/// butterfly loop then wrote outside `data`.
pub fn ntt(comptime F: type, data: []F, log_n: usize, root: F) error{ LogTooLarge, LengthMismatch, InvalidLength }!void {
    traits.assertField(F);
    const n = try sizeFromLog(log_n);
    if (data.len != n) return error.LengthMismatch;

    try bitReverse(F, data);

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

/// # Errors
/// `error.LogTooLarge`, `error.LengthMismatch`, `error.InvalidLength`, as in
/// `ntt`.
pub fn intt(comptime F: type, data: []F, log_n: usize, root: F) error{ LogTooLarge, LengthMismatch, InvalidLength }!void {
    traits.assertField(F);
    const n = try sizeFromLog(log_n);
    if (data.len != n) return error.LengthMismatch;

    const root_inv = root.inv();
    try ntt(F, data, log_n, root_inv);

    const n_inv = F.fromInt(n).inv();
    for (data) |*x| {
        x.* = x.mul(n_inv);
    }
}

/// # Errors
/// `error.LogTooLarge` when `2^log_n` overflows `usize`, plus
/// `error.OutOfMemory`.
pub fn precomputeTwiddles(comptime F: type, log_n: usize, root: F, allocator: std.mem.Allocator) error{ LogTooLarge, OutOfMemory }![]const []const F {
    traits.assertField(F);
    _ = try sizeFromLog(log_n);
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

/// # Errors
/// `error.LogTooLarge`, `error.LengthMismatch` (for `data`),
/// `error.InvalidTwiddles` (for `twiddles` or a stage slice), and
/// `error.InvalidLength`. The old `std.debug.assert`s vanish in `ReleaseFast`,
/// where the twiddle indexing then reads out of bounds.
pub fn nttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) error{ LogTooLarge, LengthMismatch, InvalidTwiddles, InvalidLength }!void {
    traits.assertField(F);
    const n = try sizeFromLog(log_n);
    if (data.len != n) return error.LengthMismatch;
    if (twiddles.len != log_n) return error.InvalidTwiddles;

    try bitReverse(F, data);

    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const stage_twiddles = twiddles[s - 1];
        if (stage_twiddles.len != half_m) return error.InvalidTwiddles;

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

/// # Errors
/// `error.LogTooLarge`, `error.LengthMismatch`, `error.InvalidTwiddles`,
/// `error.InvalidLength`, as in `nttWithTwiddles`.
pub fn inttWithTwiddles(comptime F: type, data: []F, log_n: usize, twiddles: []const []const F) error{ LogTooLarge, LengthMismatch, InvalidTwiddles, InvalidLength }!void {
    traits.assertField(F);
    const n = try sizeFromLog(log_n);
    if (data.len != n) return error.LengthMismatch;
    if (twiddles.len != log_n) return error.InvalidTwiddles;

    try bitReverse(F, data);

    var s: usize = 1;
    while (s <= log_n) : (s += 1) {
        const m = std.math.pow(usize, 2, s);
        const half_m = m >> 1;
        const stage_twiddles = twiddles[s - 1];
        if (stage_twiddles.len != half_m) return error.InvalidTwiddles;

        var k: usize = 0;
        while (k < n) : (k += m) {
            var j: usize = 0;
            while (j < half_m) : (j += 1) {
                const w = if (j == 0) F.one() else stage_twiddles[half_m - j].neg();
                const t = w.mul(data[k + j + half_m]);
                const u = data[k + j];
                data[k + j] = u.add(t);
                data[k + j + half_m] = u.sub(t);
            }
        }
    }

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
    /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse;
    /// new code that requires invertibility must call `invChecked`.
    pub fn inv(a: Self) Self {
        if (a.isZero()) return zero();
        return pow(a, modulus - 2);
    }
    pub fn invChecked(a: Self) error{InverseOfZero}!Self {
        if (a.isZero()) return error.InverseOfZero;
        return pow(a, modulus - 2);
    }
    pub const inverse = inv;
    /// Legacy total division: `x / 0 == zero()`.
    pub fn div(a: Self, b: Self) Self {
        return mul(a, inv(b));
    }
    pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
        return mul(a, try b.invChecked());
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
    try bitReverse(F7, &data);
    try bitReverse(F7, &data);
    try std.testing.expectEqualSlices(F7, &data, &[_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2), F7.fromInt(3), F7.fromInt(4), F7.fromInt(5), F7.fromInt(6), F7.fromInt(0) });
}

test "bitReverse produces correct permutation for n=4" {
    // For n=4, bit-reversal: 00->00 (0), 01->10 (2), 10->01 (1), 11->11 (3)
    // Expected order: 0, 2, 1, 3
    var data = [_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
    try bitReverse(F7, &data);
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

        const root = try M31.primitiveRootOfUnity(log_n);
        try ntt(M31, data, log_n, root);
        try intt(M31, data, log_n, root);

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

        const root = try BabyBear.primitiveRootOfUnity(log_n);
        try ntt(BabyBear, data, log_n, root);
        try intt(BabyBear, data, log_n, root);

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

        const root = try Goldilocks.primitiveRootOfUnity(log_n);
        try ntt(Goldilocks, data, log_n, root);
        try intt(Goldilocks, data, log_n, root);

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

        const root = try BN254_Fp.primitiveRootOfUnity(log_n);
        try ntt(BN254_Fp, data, log_n, root);
        try intt(BN254_Fp, data, log_n, root);

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

        const root = try BLS12_381_Fp.primitiveRootOfUnity(log_n);
        try ntt(BLS12_381_Fp, data, log_n, root);
        try intt(BLS12_381_Fp, data, log_n, root);

        for (0..n) |i| {
            try std.testing.expect(data[i].eql(original[i]));
        }
    }
}

test "intt with precomputed twiddles round-trips" {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;
    const log_n: usize = 4;
    const n: usize = @as(usize, 1) << log_n;
    const root = try Goldilocks.primitiveRootOfUnity(log_n);
    const allocator = std.testing.allocator;

    const twiddles = try precomputeTwiddles(Goldilocks, log_n, root, allocator);
    defer freeTwiddles(Goldilocks, twiddles, allocator);

    var data = try allocator.alloc(Goldilocks, n);
    defer allocator.free(data);
    var original = try allocator.alloc(Goldilocks, n);
    defer allocator.free(original);
    var rnd = SimplePrng.init(6);
    for (0..n) |i| {
        data[i] = randomField(Goldilocks, &rnd);
        original[i] = data[i];
    }

    try nttWithTwiddles(Goldilocks, data, log_n, twiddles);
    try inttWithTwiddles(Goldilocks, data, log_n, twiddles);
    try std.testing.expectEqualSlices(Goldilocks, original, data);
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
    const root = try Goldilocks.primitiveRootOfUnity(log_n);
    try ntt(Goldilocks, f_ntt, log_n, root);
    try ntt(Goldilocks, g_ntt, log_n, root);

    // Pointwise multiplication in NTT domain
    for (0..n) |i| {
        fg_ntt[i] = f_ntt[i].mul(g_ntt[i]);
    }

    // Inverse NTT
    try intt(Goldilocks, fg_ntt, log_n, root);

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
        const root = try Goldilocks.primitiveRootOfUnity(log_n);

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
        const root = try Goldilocks.primitiveRootOfUnity(log_n);

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

        try ntt(Goldilocks, data1, log_n, root);
        try nttWithTwiddles(Goldilocks, data2, log_n, twiddles);

        for (0..n) |i| {
            try std.testing.expect(data1[i].eql(data2[i]));
        }
    }
}

test "ntt rejects a length mismatch instead of writing out of bounds" {
    const F = F7;
    const log_n = 2; // n = 4
    const root = F.fromInt(3); // not a real root for F7, but lengths are checked first
    var short: [3]F = undefined;
    for (&short) |*x| x.* = F.fromInt(1);
    try std.testing.expectError(error.LengthMismatch, ntt(F, &short, log_n, root));
    try std.testing.expectError(error.LengthMismatch, intt(F, &short, log_n, root));

    // A matching length still works.
    var ok: [4]F = undefined;
    for (&ok) |*x| x.* = F.fromInt(1);
    try ntt(F, &ok, log_n, root);
    try intt(F, &ok, log_n, root);
}

test "bitReverse rejects an empty or non-power-of-two length" {
    var empty: [0]F7 = undefined;
    try std.testing.expectError(error.InvalidLength, bitReverse(F7, &empty));
    var three: [3]F7 = undefined;
    for (&three) |*x| x.* = F7.fromInt(1);
    try std.testing.expectError(error.InvalidLength, bitReverse(F7, &three));
    var four: [4]F7 = undefined;
    for (&four) |*x| x.* = F7.fromInt(1);
    try bitReverse(F7, &four);
}

test "transforms reject a log_n that overflows usize" {
    var two: [2]F7 = undefined;
    for (&two) |*x| x.* = F7.fromInt(1);
    try std.testing.expectError(error.LogTooLarge, ntt(F7, &two, 64, F7.one()));
    try std.testing.expectError(error.LogTooLarge, intt(F7, &two, 200, F7.one()));
    try std.testing.expectError(
        error.LogTooLarge,
        precomputeTwiddles(F7, 64, F7.one(), std.testing.allocator),
    );
}

test "twiddle variants validate the twiddle table shape" {
    const zf = @import("zig-field");
    const F = zf.Goldilocks;
    const log_n = 3;
    const root = try F.primitiveRootOfUnity(log_n);
    const twiddles = try precomputeTwiddles(F, log_n, root, std.testing.allocator);
    defer freeTwiddles(F, twiddles, std.testing.allocator);

    var data: [8]F = undefined;
    for (&data) |*x| x.* = F.fromInt(1);

    try std.testing.expectError(error.InvalidTwiddles, nttWithTwiddles(F, &data, log_n, twiddles[0 .. log_n - 1]));
    try std.testing.expectError(error.InvalidTwiddles, inttWithTwiddles(F, &data, log_n, twiddles[0 .. log_n - 1]));

    // A stage of the wrong length is rejected instead of indexed out of bounds.
    const bad_stage = [_][]const F{twiddles[0][0..1]};
    try std.testing.expectError(error.InvalidTwiddles, nttWithTwiddles(F, &data, log_n, &bad_stage));

    // The correct table round-trips.
    var copy = data;
    try nttWithTwiddles(F, &copy, log_n, twiddles);
    try inttWithTwiddles(F, &copy, log_n, twiddles);
    for (data, copy) |orig, back| {
        try std.testing.expect(orig.eql(back));
    }
}
