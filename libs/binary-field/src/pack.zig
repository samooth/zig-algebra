const std = @import("std");
const Polynomial = @import("polynomial.zig");

/// Packing of a multilinear polynomial into a univariate polynomial over a
/// tower (binary) field, plus evaluation by coefficient extraction.
///
/// Let H = { `fromInt(i)` : i < 2^k } be the low-bits additive subgroup of F
/// (a GF(2)-subspace of dimension k, so `F.BITS >= k` is required) and
/// Z_H(x) = ∏_{y∈H} (x + y) its vanishing polynomial (a linearized poly of
/// degree N = 2^k, built here by successive adjunction of basis vectors). The
/// packed polynomial g of a multilinear f on {0,1}^k is the unique
/// interpolation
///     g(x_i) = f(i),   x_i = fromInt(i),
/// with the Lagrange basis l_i(x) = Z_H(x)/(x + x_i) / d, where
///     d = Z_H'(x) = ∏_{z∈H∖{0}} z   (constant over H; note Z_H' ≡ 1 only
/// when H is a subfield, i.e. when k is an index of the tower).
///
/// The Lagrange kernel β_r(x) = ∏_j (x_j + 1 + r_j) is a function on H; let
/// B_r be its interpolation. Then the *coefficient-extraction identity*
///
///     f(r) = d · [x^(N-1)] ( g·B_r  mod Z_H )
///
/// holds for ANY additive subgroup H: for i ≠ j, l_i·l_j is divisible by Z_H
/// and l_i² ≡ l_i (mod Z_H), so g·B_r ≡ Σ_i f(i)β_r(i)·l_i (mod Z_H); each
/// l_i has leading coefficient 1/d, hence [x^(N-1)] of the residue is
/// (1/d)·Σ_i f(i)β_r(i) = f(r)/d. This lets a verifier who holds the packed
/// polynomial g (e.g. via a FRI commitment) evaluate f at an arbitrary point
/// r without the table: the algebraic core of the sub-linear Binius
/// evaluation (see TODO.md §1).
pub fn PackedMle(comptime F: type) type {
    return struct {
        const Self = @This();

        /// Largest `k` this field can pack: a subspace of dimension `k` must fit
        /// in `F` (`k <= F.BITS`), and the vanishing polynomial below allocates
        /// `2^(k+1) - 1` elements, so `k` also has to leave room for that
        /// doubling in a `usize`. The old `std.debug.assert(k >= 1 and k <=
        /// F.BITS)` was compiled out in ReleaseFast, where an oversized `k`
        /// wrapped the length arithmetic and then read/wrote out of bounds.
        pub const MAX_K: u8 = @min(F.BITS, @as(u8, @intCast(@bitSizeOf(usize) - 2)));

        /// `error.InvalidDimension` unless `1 <= k <= MAX_K`.
        pub fn checkK(k: u8) error{InvalidDimension}!void {
            if (k < 1 or k > MAX_K) return error.InvalidDimension;
            return;
        }

        /// `N = 2^k` after validating `k` (the shift is only sound once `k` is
        /// in range).
        fn checkedN(k: u8) error{InvalidDimension}!usize {
            try checkK(k);
            return @as(usize, 1) << @intCast(k);
        }

        /// Evaluate a polynomial (Horner).
        fn evalPoly(g: []const F, x: F) F {
            var acc = F.zero();
            var i: usize = g.len;
            while (i > 0) {
                i -= 1;
                acc = acc.mul(x).add(g[i]);
            }
            return acc;
        }

        /// Vanishing polynomial Z_H(x) = ∏_{y∈H}(x + y) of the low-bits
        /// subspace, built by adjoining the basis vectors {1, 2, 4, …}: for
        /// W ⊕ ⟨b⟩, Z_new(x) = Z_W(x)² + Z_W(b)·Z_W(x) (Z_W is linearized).
        ///
        /// `error.InvalidDimension` when `k` is outside `[1, MAX_K]`.
        pub fn vanishingPoly(allocator: std.mem.Allocator, k: u8) ![]F {
            try checkK(k);
            var z = try allocator.alloc(F, 2);
            z[0] = F.zero();
            z[1] = F.one();
            errdefer allocator.free(z);
            for (0..k) |j| {
                const b = F.fromInt(@as(u128, 1) << @intCast(j));
                const zb = evalPoly(z, b);
                const new = try allocator.alloc(F, 2 * z.len - 1);
                @memset(new, F.zero());
                for (z, 0..) |c, i| {
                    new[i] = new[i].add(zb.mul(c)); // Z_W(b)·Z_W(x)
                    new[2 * i] = new[2 * i].add(c.mul(c)); // Z_W(x)²
                }
                allocator.free(z);
                z = new;
            }
            return z;
        }

        /// The i-th un-normalized Lagrange polynomial λ_i(x) = Z_H(x)/(x + x_i),
        /// length N (degree N-1), via synthetic division by the monic linear
        /// (x + x_i) == (x - x_i) in char 2. Note λ_i(x_j) = δ_ij·d with
        /// d = Z_H'(x_i) = z[1] constant over H; the value-normalized basis is
        /// l_i = λ_i/d.
        ///
        /// **This is characteristic-2 specific and is NOT generalized here.** The
        /// obvious change -- `add` to `sub` in the recurrence below -- is a
        /// no-op over GF(2^m), so the binary-field suite cannot confirm it, and
        /// `prime_fixture.zig` shows that `PackedMle.interpolate` does not
        /// round-trip over a prime field either way. Something else in this
        /// structure is also specialized, so generalizing one line would make a
        /// characteristic-2 structure *look* general without being general.
        fn lagrangeBasis(allocator: std.mem.Allocator, z: []const F, x_i: F) ![]F {
            const N = z.len - 1;
            const c = x_i;
            const q = try allocator.alloc(F, N);
            // A = (x + c)·Q: a[N] = q[N-1], a[i] = q[i-1] + c·q[i].
            var carry = z[N];
            var i: usize = N;
            while (i > 0) {
                i -= 1;
                q[i] = carry;
                const ai = if (i == 0) @as(F, z[0]) else z[i];
                carry = ai.add(c.mul(q[i]));
            }
            return q;
        }

        /// The normalization d = Z_H'(x) for any x ∈ H, i.e. the coefficient
        /// of x in Z_H (Z_H' ≡ 1, and hence d = 1, iff H is a subfield).
        fn lagrangeDenom(z: []const F) F {
            return z[1];
        }

        /// Interpolate the packed polynomial g (degree < N) from the MLE table:
        /// g = Σ_i f(i)·l_i with l_i = λ_i/d, coefficient-wise, so that
        /// g(x_i) = f(i).
        ///
        /// `error.InvalidDimension` when `k` is outside `[1, MAX_K]`,
        /// `error.LengthMismatch` when `table.len != 2^k` (the old assert let
        /// `table[i]` read past the end in ReleaseFast).
        pub fn interpolate(allocator: std.mem.Allocator, k: u8, table: []const F) ![]F {
            const N = try checkedN(k);
            if (table.len != N) return error.LengthMismatch;

            const z = try vanishingPoly(allocator, k);
            defer allocator.free(z);
            const dinv = lagrangeDenom(z).inv();

            const g = try allocator.alloc(F, N);
            errdefer allocator.free(g);
            @memset(g, F.zero());

            for (0..N) |i| {
                const row = try lagrangeBasis(allocator, z, F.fromInt(i));
                defer allocator.free(row);
                const c = table[i].mul(dinv);
                for (0..N) |j| g[j] = g[j].add(c.mul(row[j]));
            }
            return g;
        }

        /// The Lagrange kernel β_r(bits(i)) = ∏_j (bit_j(i) + 1 + r_j).
        ///
        /// Total: a `r` shorter than `k` yields zero (no contribution) instead
        /// of reading `r[j]` out of bounds. Use `betaOnHChecked` to detect it.
        pub fn betaOnH(k: u8, r: []const F, i: usize) F {
            return betaOnHChecked(k, r, i) catch F.zero();
        }

        /// Checked kernel evaluation: `error.LengthMismatch` when
        /// `r.len < k`.
        pub fn betaOnHChecked(k: u8, r: []const F, i: usize) error{LengthMismatch}!F {
            if (r.len < k) return error.LengthMismatch;
            var acc = F.one();
            for (0..k) |j| {
                const bit: u8 = @intFromBool((i >> @intCast(j)) & 1 == 1);
                acc = acc.mul(F.fromInt(bit).add(F.one().add(r[j])));
            }
            return acc;
        }

        /// Interpolate B_r (the kernel β_r restricted to H) as a univariate
        /// polynomial of degree < N with B_r(x_i) = β_r(i).
        ///
        /// `error.InvalidDimension` / `error.LengthMismatch` as in
        /// `interpolate` (here the length requirement is on `r`).
        pub fn kernelPoly(allocator: std.mem.Allocator, k: u8, r: []const F) ![]F {
            const N = try checkedN(k);
            if (r.len != k) return error.LengthMismatch;
            const z = try vanishingPoly(allocator, k);
            defer allocator.free(z);
            const dinv = lagrangeDenom(z).inv();
            const B = try allocator.alloc(F, N);
            errdefer allocator.free(B);
            @memset(B, F.zero());
            for (0..N) |i| {
                const row = try lagrangeBasis(allocator, z, F.fromInt(i));
                defer allocator.free(row);
                const v = (try betaOnHChecked(k, r, i)).mul(dinv);
                for (0..N) |j| B[j] = B[j].add(v.mul(row[j]));
            }
            return B;
        }

        /// Reduce P (given as its raw product) modulo Z_H, where z is the
        /// vanishing polynomial of H (z[N] = 1, deg z = N). Uses the monic
        /// relation x^N ≡ Σ_{i<N} z_i·x^i and folds high degrees down in one
        /// descending pass.
        ///
        /// `error.LengthMismatch` when `raw.len > 2N - 1` (the old assert let
        /// `@memcpy` overflow the work buffer in ReleaseFast).
        fn reduceMod(allocator: std.mem.Allocator, z: []const F, raw: []const F) ![]F {
            if (z.len < 2) return error.LengthMismatch;
            const N = z.len - 1;
            if (raw.len > 2 * N - 1) return error.LengthMismatch;
            const work = try allocator.alloc(F, 2 * N - 1);
            defer allocator.free(work);
            @memset(work, F.zero());
            @memcpy(work[0..raw.len], raw);
            var d: usize = 2 * N - 2;
            while (d >= N) : (d -= 1) {
                const c = work[d];
                if (c.isZero()) continue;
                work[d] = F.zero();
                for (0..N) |i| {
                    work[i + d - N] = work[i + d - N].add(c.mul(z[i]));
                }
            }
            return allocator.dupe(F, work[0..N]);
        }

        /// Product a·b mod Z_H (length N), where z is the vanishing polynomial
        /// of H.
        ///
        /// `error.InvalidDimension` / `error.LengthMismatch` as above; the
        /// length check is what keeps `a[i]`/`b[j]` in bounds.
        pub fn mulModVanishing(allocator: std.mem.Allocator, k: u8, z: []const F, a: []const F, b: []const F) ![]F {
            const N = try checkedN(k);
            if (a.len != N or b.len != N or z.len != N + 1) return error.LengthMismatch;
            const raw = try allocator.alloc(F, 2 * N - 1);
            defer allocator.free(raw);
            @memset(raw, F.zero());
            for (0..N) |i| {
                for (0..N) |j| {
                    raw[i + j] = raw[i + j].add(a[i].mul(b[j]));
                }
            }
            return reduceMod(allocator, z, raw);
        }

        /// Evaluate the MLE f (given as its packed polynomial g) at r via
        /// coefficient extraction: f(r) = d·[x^(N-1)](g·B_r mod Z_H) with
        /// d = Z_H'(x) = z[1] (1 iff H is a subfield).
        ///
        /// `error.InvalidDimension` when `k` is out of range, `error.LengthMismatch`
        /// when `g.len != 2^k` or `r.len != k`.
        pub fn eval(allocator: std.mem.Allocator, k: u8, g: []const F, r: []const F) !F {
            const N = try checkedN(k);
            if (g.len != N) return error.LengthMismatch;
            if (r.len != k) return error.LengthMismatch;
            const B = try kernelPoly(allocator, k, r);
            defer allocator.free(B);
            const z = try vanishingPoly(allocator, k);
            defer allocator.free(z);
            const h = try mulModVanishing(allocator, k, z, g, B);
            defer allocator.free(h);
            return h[N - 1].mul(lagrangeDenom(z));
        }
    };
}

/// Novel-basis normalizations c_i = s_i(e_i) for i < k, where s_i is the
/// vanishing polynomial of V_i = span{e_0..e_{i-1}} and e_i = fromInt(2^i).
/// The i-th novel basis element is Ŵ_i(x) = s_i(x)/c_i, matching the additive
/// NTT in `fripcs.zig`. Computed at comptime from the field only.
pub fn novelNorms(comptime S: type, comptime k: u8) [k]S {
    var norms: [k]S = undefined;
    // prev[i] = s_j(e_i) for the current depth j; s_0(x) = x.
    var prev: [k]S = undefined;
    for (0..k) |i| prev[i] = S.fromInt(@as(u128, 1) << @intCast(i)); // s_0(e_i) = e_i
    for (0..k) |j| {
        norms[j] = prev[j]; // c_j = s_j(e_j)
        for (j + 1..k) |i| prev[i] = prev[i].mul(prev[i]).add(norms[j].mul(prev[i]));
    }
    return norms;
}

/// Evaluate a degree-<2^k polynomial given in the *novel* basis (see
/// `fripcs.zig` `Ntt`) at a single point `x`, in O(2^k) field ops. The i-th
/// basis element is Ŵ_i(x) = s_i(x)/s_i(e_i); `coeffs[r]` is the coefficient of
/// ∏_{i∈S(r)} Ŵ_i with S(r) the set bits of r. This is the packing analogue of
/// Horner evaluation: what the FRI-Binius additive NTT computes over the whole
/// domain, restricted to one point. `k <= S.BITS`; the caller frees the scratch.
///
/// `error.InvalidDimension` when `k` is outside `[1, S.BITS]` (the old assert
/// let `norms[i]`/`w[0]` write out of bounds once compiled out) and
/// `error.LengthMismatch` when `coeffs.len != 2^k`.
pub fn novelEval(allocator: std.mem.Allocator, comptime S: type, k: u8, coeffs: []const S, x: S) !S {
    if (k < 1 or k > S.BITS) return error.InvalidDimension;
    if (k > @bitSizeOf(usize) - 2) return error.InvalidDimension;
    const N = @as(usize, 1) << @intCast(k);
    if (coeffs.len != N) return error.LengthMismatch;

    // Norms c_j = s_j(e_j), computed here at runtime (k is a runtime parameter;
    // `novelNorms` is the comptime variant for comptime k).
    var norms: [S.BITS]S = undefined;
    var prev: [S.BITS]S = undefined;
    for (0..k) |i| prev[i] = S.fromInt(@as(u128, 1) << @intCast(i)); // s_0(e_i) = e_i
    for (0..k) |j| {
        norms[j] = prev[j]; // c_j = s_j(e_j)
        for (j + 1..k) |i| prev[i] = prev[i].mul(prev[i]).add(norms[j].mul(prev[i]));
    }
    const w = try allocator.alloc(S, k);
    defer allocator.free(w);
    const p = try allocator.alloc(S, N);
    defer allocator.free(p);
    // w[i] = Ŵ_i(x) = s_i(x)/c_i, with s_i(x) via the subspace recurrence
    // s_i(x) = s_{i-1}(x)² + c_{i-1}·s_{i-1}(x).
    var sx = x; // s_0(x) = x
    w[0] = x; // Ŵ_0(x) = x/c_0, c_0 = 1
    for (1..k) |i| {
        sx = sx.mul(sx).add(norms[i - 1].mul(sx));
        w[i] = sx.mul(norms[i].inv());
    }
    // p[r] = ∏_{i∈S(r)} w[i], via the lowest set bit (O(N)).
    p[0] = S.one();
    for (1..N) |r| {
        const lsb = r & -%r;
        const j = @ctz(lsb);
        p[r] = p[r ^ lsb].mul(w[j]);
    }
    var acc = S.zero();
    for (0..N) |r| acc = acc.add(coeffs[r].mul(p[r]));
    return acc;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Tower = @import("tower.zig");
const Gf16 = Tower.Gf16;
const Gf256 = Tower.Gf256;

fn prng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

fn randomTable(allocator: std.mem.Allocator, comptime F: type, k: u8, seed: u64) ![]F {
    const N = @as(usize, 1) << @intCast(k);
    const t = try allocator.alloc(F, N);
    var r = prng(seed);
    for (t) |*v| v.* = F.fromInt(r.random().uintLessThan(u32, std.math.maxInt(u32)));
    return t;
}

fn randomPoint(allocator: std.mem.Allocator, comptime F: type, k: u8, seed: u64) ![]F {
    const r = try allocator.alloc(F, k);
    var rnd = prng(seed);
    for (r) |*v| v.* = F.fromInt(rnd.random().uintLessThan(u32, std.math.maxInt(u32)));
    return r;
}

test "vanishing polynomial vanishes exactly on the low-bits subspace" {
    const alloc = std.testing.allocator;
    const F = Gf256;
    const k = 3;
    const N = @as(usize, 1) << @intCast(k);
    const z = try PackedMle(F).vanishingPoly(alloc, k);
    defer alloc.free(z);
    try std.testing.expectEqual(PackedMle(F).evalPoly(z, F.fromInt(0)), F.zero());
    for (0..N) |i| {
        // Z_H vanishes on H and is monic of degree N.
        try std.testing.expectEqual(PackedMle(F).evalPoly(z, F.fromInt(i)), F.zero());
    }
    // Nonzero (and not vanishing) at a point outside the subspace.
    const outside = PackedMle(F).evalPoly(z, F.fromInt(N));
    try std.testing.expect(!outside.isZero());
}

test "packed interpolation reproduces the MLE table on H" {
    const alloc = std.testing.allocator;
    const F = Gf256;
    const k = 4;
    const N = @as(usize, 1) << @intCast(k);
    const table = try randomTable(alloc, F, k, 7);
    defer alloc.free(table);
    const g = try PackedMle(F).interpolate(alloc, k, table);
    defer alloc.free(g);
    for (0..N) |i| {
        try std.testing.expectEqual(table[i].value, PackedMle(F).evalPoly(g, F.fromInt(i)).value);
    }
}

test "coefficient-extraction eval matches direct MLE eval at random points" {
    const alloc = std.testing.allocator;
    const F = Gf256;
    const k = 4;
    const table = try randomTable(alloc, F, k, 11);
    defer alloc.free(table);
    const g = try PackedMle(F).interpolate(alloc, k, table);
    defer alloc.free(g);

    const r = try randomPoint(alloc, F, k, 23);
    defer alloc.free(r);
    const mle = Polynomial.Multilinear(F){ .evals = table };
    const direct = try mle.eval(alloc, r);
    const via_packing = try PackedMle(F).eval(alloc, k, g, r);
    try std.testing.expectEqual(direct.value, via_packing.value);
}

test "coefficient-extraction eval agrees with the kernel identity sum" {
    const alloc = std.testing.allocator;
    const F = Gf16;
    const k = 3;
    const N = @as(usize, 1) << @intCast(k);
    const table = try randomTable(alloc, F, k, 5);
    defer alloc.free(table);
    const g = try PackedMle(F).interpolate(alloc, k, table);
    defer alloc.free(g);
    const r = try randomPoint(alloc, F, k, 31);
    defer alloc.free(r);

    var sum = F.zero();
    for (0..N) |i| {
        sum = sum.add(table[i].mul(PackedMle(F).betaOnH(k, r, i)));
    }
    const via_packing = try PackedMle(F).eval(alloc, k, g, r);
    try std.testing.expectEqual(sum.value, via_packing.value);
}

test "packed eval round trips across k and fields (incl. non-subfield k)" {
    const alloc = std.testing.allocator;
    inline for (.{ Gf16, Gf256 }) |F| {
        const max_k = @as(u8, @intCast(@min(F.BITS, 6)));
        var k: u8 = 1;
        while (k <= max_k) : (k += 1) {
            const table = try randomTable(alloc, F, k, @as(u64, k) * 37);
            defer alloc.free(table);
            const g = try PackedMle(F).interpolate(alloc, k, table);
            defer alloc.free(g);
            const r = try randomPoint(alloc, F, k, @as(u64, k) * 91);
            defer alloc.free(r);
            const mle = Polynomial.Multilinear(F){ .evals = table };
            const direct = try mle.eval(alloc, r);
            const via_packing = try PackedMle(F).eval(alloc, k, g, r);
            try std.testing.expectEqual(direct.value, via_packing.value);
        }
    }
}

test "out-of-range dimensions are typed errors, not oversized allocations" {
    const alloc = std.testing.allocator;
    const F = Gf16; // BITS = 4
    const P = PackedMle(F);

    try std.testing.expectEqual(@as(u8, 4), P.MAX_K);
    // k == 0 and k > BITS: both were asserts that vanished in ReleaseFast.
    try std.testing.expectError(error.InvalidDimension, P.vanishingPoly(alloc, 0));
    try std.testing.expectError(error.InvalidDimension, P.vanishingPoly(alloc, F.BITS + 1));
    // k == 255 used to wrap the length arithmetic and then allocate/OOM.
    try std.testing.expectError(error.InvalidDimension, P.vanishingPoly(alloc, 255));
    try std.testing.expectError(error.InvalidDimension, P.interpolate(alloc, 255, &[_]F{}));
    try std.testing.expectError(error.InvalidDimension, P.interpolate(alloc, 0, &[_]F{}));
    try std.testing.expectError(error.InvalidDimension, P.kernelPoly(alloc, 255, &[_]F{}));
    try std.testing.expectError(error.InvalidDimension, P.eval(alloc, 255, &[_]F{}, &[_]F{}));
    try std.testing.expectError(error.InvalidDimension, P.mulModVanishing(alloc, 255, &[_]F{}, &[_]F{}, &[_]F{}));
}

test "length mismatches are typed errors, not out-of-bounds access" {
    const alloc = std.testing.allocator;
    const F = Gf256;
    const P = PackedMle(F);
    const k: u8 = 3;
    const N = @as(usize, 1) << @intCast(k);

    const table = try randomTable(alloc, F, k, 3);
    defer alloc.free(table);
    const r = try randomPoint(alloc, F, k, 4);
    defer alloc.free(r);
    const g = try P.interpolate(alloc, k, table);
    defer alloc.free(g);
    const z = try P.vanishingPoly(alloc, k);
    defer alloc.free(z);

    // Table shorter/longer than 2^k.
    const short_table = table[0 .. N - 1];
    try std.testing.expectError(error.LengthMismatch, P.interpolate(alloc, k, short_table));
    const long_table = try alloc.alloc(F, N + 1);
    defer alloc.free(long_table);
    @memset(long_table, F.zero());
    try std.testing.expectError(error.LengthMismatch, P.interpolate(alloc, k, long_table));

    // Point of the wrong length.
    const short_r = r[0 .. k - 1];
    try std.testing.expectError(error.LengthMismatch, P.kernelPoly(alloc, k, short_r));
    try std.testing.expectError(error.LengthMismatch, P.eval(alloc, k, g, short_r));
    try std.testing.expectError(error.LengthMismatch, P.betaOnHChecked(k, short_r, 1));
    // Legacy kernel helper: zero contribution instead of reading past `r`.
    try std.testing.expect(P.betaOnH(k, short_r, 1).isZero());

    // Packed polynomial of the wrong length.
    const short_g = g[0 .. N - 1];
    const short_z = z[0 .. z.len - 1];
    try std.testing.expectError(error.LengthMismatch, P.eval(alloc, k, short_g, r));
    try std.testing.expectError(error.LengthMismatch, P.mulModVanishing(alloc, k, z, short_g, g));
    try std.testing.expectError(error.LengthMismatch, P.mulModVanishing(alloc, k, short_z, g, g));
}

test "novelEval validates k and coeffs length" {
    const alloc = std.testing.allocator;
    const S = Gf16; // BITS = 4
    const k: u8 = 2;
    const N = @as(usize, 1) << @intCast(k);
    // coeffs[0] == 1 is the constant-one polynomial: the sum collapses to p[0].
    const coeffs = [_]S{ S.one(), S.zero(), S.zero(), S.zero() };
    try std.testing.expectEqual(@as(u128, 1), (try novelEval(alloc, S, k, &coeffs, S.fromInt(9))).value);

    try std.testing.expectError(error.InvalidDimension, novelEval(alloc, S, 0, &coeffs, S.one()));
    try std.testing.expectError(error.InvalidDimension, novelEval(alloc, S, S.BITS + 1, &coeffs, S.one()));
    try std.testing.expectError(error.InvalidDimension, novelEval(alloc, S, 255, &coeffs, S.one()));
    try std.testing.expectError(error.LengthMismatch, novelEval(alloc, S, k, coeffs[0 .. N - 1], S.one()));
    try std.testing.expectError(error.LengthMismatch, novelEval(alloc, S, k, &[_]S{S.one()}, S.one()));
}
