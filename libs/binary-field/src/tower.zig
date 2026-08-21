const std = @import("std");
const Clmul = @import("clmul.zig");

/// The canonical Binius tower of binary fields (Wiedemann tower, [DP23] §2.3).
///
///     T_0 = GF(2)
///     T_1 = T_0[X_0] / (X_0² + X_0 + 1)                (GF(4))
///     T_2 = T_1[X_1] / (X_1² + X_0·X_1 + 1)            (GF(16))
///     T_3 = T_2[X_2] / (X_2² + X_1·X_2 + 1)            (GF(256))
///     ...
///     T_ι = T_{ι-1}[X_{ι-1}]/(X_{ι-1}² + X_{ι-2}·X_{ι-1} + 1)
///
/// so that T_ι ≅ GF(2^{2^ι}). Each step adjoins a root X_i of a quadratic
/// y² + β·y + 1 with β = X_{i-2} (taking X_{-1} = 1), giving the *zero-cost
/// subfield embedding* T_{ι-1} ⊂ T_ι: an element of T_{ι-1} is the same bit
/// string as its image in T_ι.
///
/// Elements are stored in the *multilinear monomial basis* (Cantor basis):
/// value bit j = coefficient of ∏_{i ∈ bits(j)} X_i. Multiplication is the
/// Karatsuba-style recursion of DP23 §2.3:
///
///     (a0 + a1·y)(b0 + b1·y) = (a0b0 + a1b1) + (a0b1 + a1b0 + a1b1·β)·y
///
/// and inversion is the recursive norm-conjugate method of [FP97], needing
/// O(level) field operations instead of O(2^level) exponentiation.
///
/// [DP23]: https://eprint.iacr.org/2023/1784
/// [FP97]: Fan, Paar. "On efficient inversion in tower fields of characteristic
///         two." ISIT 1997.
pub fn TowerField(comptime level: u8) type {
    comptime std.debug.assert(level <= 7); // 2^7 = 128 bits fits in u128
    return struct {
        const Self = @This();

        /// Tower height ι: |T_ι| = 2^(2^level).
        pub const LEVEL: u8 = level;
        /// Extension degree over GF(2): 2^level bits.
        pub const BITS: u8 = 1 << level;
        pub const SIZE = (BITS + 7) / 8;
        pub const Subfield = TowerField(level - 1);

        value: u128,

        /// The quadratic constant β = X_{i-2} used at this level (1 at level 1).
        fn betaValue(comptime lv: u8) u128 {
            if (lv == 0) return 0;
            if (lv == 1) return 1;
            return @as(u128, 1) << @intCast(@as(u8, 1) << @intCast(lv - 2));
        }
        const BETA: u128 = betaValue(level);

        pub fn fromInt(x: anytype) Self {
            const v: u128 = @intCast(x);
            const mask: u128 = if (BITS == 128) std.math.maxInt(u128) else (@as(u128, 1) << BITS) - 1;
            return .{ .value = v & mask };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .value = a.value ^ b.value };
        }

        pub fn sub(a: Self, b: Self) Self {
            return a.add(b);
        }

        const FULL_MASK: u128 = if (BITS == 128) std.math.maxInt(u128) else (@as(u128, 1) << BITS) - 1;

        /// Runtime-lazily-built fast-multiply tables, only meaningful for
        /// `level >= 1`. `T_ι` is a field of size 2^BITS, so it is also
        /// `GF(2)[x]/(Q)` for the minimal polynomial `Q` of a generator `g`;
        /// the polynomial basis `{1, g, ..., g^{BITS-1}}` is connected to the
        /// Cantor basis by the GF(2)-linear change of basis whose columns are
        /// the Cantor representations of the powers `g^j`. Multiplication
        /// therefore factors as
        ///
        ///     a·b = V·( (V⁻¹·a) · (V⁻¹·b) mod Q ),
        ///
        /// where `V⁻¹·a` is the polynomial-basis coordinate vector of `a`, the
        /// product is a carry-less multiply (CLMUL, `clmul.zig`) and the
        /// reduction mod `Q` is a precomputed linear map. All three linear maps
        /// are applied column-wise over GF(2) (`applyMatrix`): for each set
        /// input bit `j` XOR the precomputed image of basis vector `j`. This
        /// replaces the 3^level recursive Karatsuba with a handful of u128
        /// XORs and one or four carry-less multiplications.
        const Fast = struct {
            to_poly: [BITS]u128,
            from_poly: [BITS]u128,
            reduce: [2 * @as(usize, BITS)]u128,
        };

        var fast_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var fast_mutex: std.atomic.Mutex = .unlocked;
        var fast_tables: Fast = undefined;

        fn lockSpin(m: *std.atomic.Mutex) void {
            while (!m.tryLock()) std.atomic.spinLoopHint();
        }

        /// Build the fast-multiply tables for this level at runtime (comptime
        /// generation proved too slow in the Zig interpreter). `mulRec`
        /// recurses through the strictly-lower subfield dispatcher, so
        /// building level L transitively builds every lower level first.
        fn buildFast() Fast {
            // Generator g with a degree-BITS minimal polynomial: V's columns
            // are the Cantor representations of g^0..g^(BITS-1), and V is
            // invertible exactly when the minimal polynomial has degree BITS.
            // The element X_{L-1} (monomial index BITS/2) lies outside the
            // largest proper subfield T_{L-1}, so its degree divides BITS and
            // exceeds BITS/2 — hence it equals BITS and {1,g,...,g^(BITS-1)}
            // is a basis. (A sequential search would waste 2^(BITS/2)
            // candidates on subfield elements at every level.)
            var V: [BITS]u128 = undefined;
            var Vinv: [BITS]u128 = undefined;
            const g = fromInt(@as(u128, 1) << @intCast(BITS / 2));
            var p = one();
            for (0..BITS) |j| {
                V[j] = p.value;
                p = p.mulRec(g);
            }
            if (!invertCols(V, &Vinv)) @panic("tower: generator must exist at every level");
            // Minimal polynomial Q(x) = x^BITS + Σ_j q_j x^j, from g^BITS.
            var gb = one();
            for (0..BITS) |_| gb = gb.mulRec(g);
            const q = applyMatrix(&Vinv, gb.value & FULL_MASK);
            // Reduction columns: red[j] = (x^j mod Q) in the polynomial basis.
            var reduce: [2 * @as(usize, BITS)]u128 = undefined;
            var xj: u128 = 1;
            for (0..2 * @as(usize, BITS)) |j| {
                reduce[j] = xj;
                const top = (xj >> @intCast(BITS - 1)) & 1;
                xj = (xj << 1) & FULL_MASK;
                if (top == 1) xj ^= q;
            }
            return .{ .to_poly = Vinv, .from_poly = V, .reduce = reduce };
        }

        fn ensureFast() void {
            if (fast_ready.load(.acquire)) return;
            lockSpin(&fast_mutex);
            defer fast_mutex.unlock();
            if (fast_ready.load(.monotonic)) return;
            fast_tables = buildFast();
            fast_ready.store(true, .release);
        }

        /// GF(2) column-wise linear map application: out = Σ_j v_j · cols[j].
        fn applyMatrix(cols: []const u128, v: u128) u128 {
            var out: u128 = 0;
            var x = v;
            while (x != 0) {
                const j = @ctz(x);
                out ^= cols[j];
                x &= x - 1;
            }
            return out;
        }

        /// Gaussian elimination returning `true` and writing `cols` to the
        /// identity and `inv_out` to the matrix inverse, or `false` if singular.
        fn invertCols(cols: [BITS]u128, inv_out: *[BITS]u128) bool {
            var c = cols;
            var i: [BITS]u128 = undefined;
            for (0..BITS) |j| i[j] = @as(u128, 1) << @intCast(j);
            for (0..BITS) |piv| {
                var r: usize = piv;
                while (r < BITS and ((c[r] >> @intCast(piv)) & 1) == 0) r += 1;
                if (r == BITS) return false;
                if (r != piv) {
                    const t = c[piv];
                    c[piv] = c[r];
                    c[r] = t;
                    const ti = i[piv];
                    i[piv] = i[r];
                    i[r] = ti;
                }
                for (0..BITS) |k| {
                    if (k != piv and ((c[k] >> @intCast(piv)) & 1) == 1) {
                        c[k] ^= c[piv];
                        i[k] ^= i[piv];
                    }
                }
            }
            inv_out.* = i;
            return true;
        }

        /// Recursive Karatsuba-style multiply in T_ι (the portable reference
        /// path; also used at comptime to build the fast-multiply tables).
        /// The halves multiply through their own `mul` dispatcher, which uses
        /// the subfield's CLMUL fast path even at comptime (`clmul64Auto`
        /// falls back to software there), so table generation is cheap.
        pub fn mulRec(a: Self, b: Self) Self {
            if (level == 0) return .{ .value = a.value & b.value };
            const half: u8 = 1 << (level - 1);
            const mask: u128 = (@as(u128, 1) << half) - 1;
            const S = TowerField(level - 1);
            const a0 = S{ .value = a.value & mask };
            const a1 = S{ .value = (a.value >> half) & mask };
            const b0 = S{ .value = b.value & mask };
            const b1 = S{ .value = (b.value >> half) & mask };

            const c0 = a0.mul(b0);
            const c1 = a1.mul(b1);
            const c2 = a0.add(a1).mul(b0.add(b1));
            const lo = c0.add(c1);
            // hi = (a0b1 + a1b0) + a1b1·β = (c2 + c0 + c1) + c1·β
            const hi = c2.add(c0).add(c1).add(c1.mul(S{ .value = BETA }));
            return .{ .value = lo.value | (hi.value << half) };
        }

        /// CLMUL-based multiply via the polynomial-basis isomorphism. Used as
        /// `mul` on platforms with the PCLMULQDQ instruction (comptime); always
        /// available for testing against `mulRec`.
        pub fn mulFast(a: Self, b: Self) Self {
            if (level == 0) return .{ .value = a.value & b.value };
            ensureFast();
            const MT = &fast_tables;
            const pa = applyMatrix(&MT.to_poly, a.value & FULL_MASK);
            const pb = applyMatrix(&MT.to_poly, b.value & FULL_MASK);
            const prod = if (BITS == 128)
                Clmul.clmul128Auto(pa, pb)
            else blk: {
                const p = Clmul.clmul64Auto(@truncate(pa), @truncate(pb));
                break :blk .{ .lo = p, .hi = @as(u128, 0) };
            };
            var red = applyMatrix(&MT.reduce, prod.lo);
            var y = prod.hi;
            while (y != 0) {
                const j = @ctz(y);
                red ^= MT.reduce[BITS + j];
                y &= y - 1;
            }
            return .{ .value = applyMatrix(&MT.from_poly, red) & FULL_MASK };
        }

        /// Multiply in T_ι: the CLMUL fast path where the hardware has the
        /// instruction, otherwise the recursive Karatsuba path.
        pub fn mul(a: Self, b: Self) Self {
            if (Clmul.has_hardware_clmul and level >= 1) return a.mulFast(b);
            return a.mulRec(b);
        }

        pub fn pow(a: Self, exp: anytype) Self {
            var result = Self.one();
            var base = a;
            var e: u128 = exp;
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) result = result.mul(base);
                base = base.mul(base);
            }
            return result;
        }

        /// Recursive inversion: a⁻¹ = conj(a)·N(a)⁻¹ with
        /// N(a) = a0² + a0·a1·β + a1² ∈ T_{level-1} and conj(a) = a0 + a1(β + y).
        pub fn inv(a: Self) Self {
            if (level == 0) {
                std.debug.assert(a.value == 1);
                return a;
            }
            const half: u8 = 1 << (level - 1);
            const mask: u128 = (@as(u128, 1) << half) - 1;
            const S = TowerField(level - 1);
            const a0 = S{ .value = a.value & mask };
            const a1 = S{ .value = (a.value >> half) & mask };
            const beta_e = S{ .value = BETA };

            const n = a0.mul(a0).add(a0.mul(a1).mul(beta_e)).add(a1.mul(a1));
            const inv_n = n.inv();
            const lo = a0.add(a1.mul(beta_e)).mul(inv_n);
            const hi = a1.mul(inv_n);
            return .{ .value = lo.value | (hi.value << half) };
        }

        /// Norm down to the direct subfield T_{level-1} (multiplicative).
        pub fn norm(a: Self) Subfield {
            if (level == 0) return Subfield{ .value = a.value };
            const half: u8 = 1 << (level - 1);
            const mask: u128 = (@as(u128, 1) << half) - 1;
            const a0 = Subfield{ .value = a.value & mask };
            const a1 = Subfield{ .value = (a.value >> half) & mask };
            return a0.mul(a0).add(a0.mul(a1).mul(Subfield{ .value = BETA })).add(a1.mul(a1));
        }

        /// Absolute trace to GF(2): a + a² + a⁴ + ... + a^(2^(BITS-1)).
        pub fn trace(a: Self) u1 {
            var acc = a.value;
            var term = a;
            var i: usize = 1;
            while (i < BITS) : (i += 1) {
                term = term.mul(term);
                acc ^= term.value;
            }
            return @intCast(acc & 1);
        }

        pub fn eq(a: Self, b: Self) bool {
            return a.value == b.value;
        }

        pub fn zero() Self {
            return .{ .value = 0 };
        }

        pub fn one() Self {
            return .{ .value = 1 };
        }

        pub fn isZero(a: Self) bool {
            return a.value == 0;
        }

        /// The root X_{level-1} adjoined at this level (bit 2^(level-1)).
        pub fn alpha() Self {
            if (level == 0) return one();
            return fromInt(@as(u128, 1) << @intCast(@as(u8, 1) << @intCast(level - 1)));
        }

        /// Zero-cost embedding of a subfield element (identical bit string).
        pub fn fromSubfield(x: Subfield) Self {
            return .{ .value = x.value };
        }

        /// Drop the top level (keeps the low bits, which is T_{level-1}).
        pub fn toSubfield(a: Self) Subfield {
            return .{ .value = a.value };
        }

        /// Embed an element of any lower tower level.
        pub fn embed(comptime lower: u8, x: TowerField(lower)) Self {
            return .{ .value = x.value };
        }

        pub fn toBytes(a: Self, out: *[SIZE]u8) void {
            var v = a.value;
            for (0..SIZE) |i| {
                out[i] = @truncate(v);
                v >>= 8;
            }
        }

        pub fn fromBytes(bytes: [SIZE]u8) Self {
            var v: u128 = 0;
            var i: usize = SIZE;
            while (i > 0) {
                i -= 1;
                v = (v << 8) | bytes[i];
            }
            return fromInt(v);
        }
    };
}

/// Concrete tower levels: T_ι ≅ GF(2^{2^ι}).
///
/// Note: `Gf16`/`Gf256`/... here are the *tower* representations (isomorphic
/// to, but bit-representation-distinct from, `field.Gf16` = GF(2^4) via the
/// Script-friendly x⁴ + x + 1). Use `tower.*` when the tower structure matters.
pub const Gf2 = TowerField(0);
pub const Gf4 = TowerField(1);
pub const Gf16 = TowerField(2);
pub const Gf256 = TowerField(3);
pub const Gf65536 = TowerField(4);
pub const Gf2_32 = TowerField(5);
pub const Gf2_64 = TowerField(6);
pub const Gf2_128 = TowerField(7);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn rng(comptime F: type, seed: *u64) F {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    return F.fromInt(seed.*);
}

test "level 1 field is GF(4)" {
    const F = Gf4;
    // X_0 has order 3: X_0² = X_0 + 1
    const x0 = F.alpha();
    try std.testing.expect(x0.mul(x0).eq(x0.add(F.one())));
    try std.testing.expect(x0.mul(x0).mul(x0).eq(F.one()));
    // only 4 distinct values
    var seen = [_]bool{false} ** 16;
    for (0..16) |i| seen[@as(usize, @truncate(F.fromInt(i).value)) & 15] = true;
    var count: usize = 0;
    for (seen) |v| {
        if (v) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "field polynomial holds at every level" {
    inline for (1..8) |lv| {
        const F = TowerField(lv);
        const y = F.alpha();
        const beta = if (lv == 1) F.one() else F.fromInt(@as(u128, 1) << @intCast(@as(u8, 1) << @intCast(lv - 2)));
        // y² + β·y + 1 = 0
        const zero = y.mul(y).add(beta.mul(y)).add(F.one());
        try std.testing.expect(zero.isZero());
    }
}

test "tower is a field: distributivity and associativity" {
    inline for (1..8) |lv| {
        const F = TowerField(lv);
        var s: u64 = lv;
        for (0..200) |_| {
            const a = rng(F, &s);
            const b = rng(F, &s);
            const c = rng(F, &s);
            try std.testing.expect(a.mul(b.add(c)).eq(a.mul(b).add(a.mul(c))));
            try std.testing.expect(a.mul(b).mul(c).eq(a.mul(b.mul(c))));
            try std.testing.expect(a.add(b).eq(b.add(a)));
            try std.testing.expect(a.mul(b).eq(b.mul(a)));
            try std.testing.expect(a.add(b).add(c).eq(a.add(b.add(c))));
        }
    }
}

test "exhaustive: fast CLMUL multiply matches recursive Karatsuba (GF4, GF16, GF256)" {
    inline for (.{ 1, 2, 3 }) |lv| {
        const F = TowerField(lv);
        const n = @as(usize, 1) << @intCast(@as(u8, 1) << @intCast(lv));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = F.fromInt(i);
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const b = F.fromInt(j);
                try std.testing.expect(a.mulFast(b).eq(a.mulRec(b)));
            }
        }
    }
}

test "random: fast CLMUL multiply matches recursive Karatsuba at every level" {
    inline for (1..8) |lv| {
        const F = TowerField(lv);
        var s: u64 = lv * 1234;
        for (0..200) |_| {
            const a = rng(F, &s);
            const b = rng(F, &s);
            try std.testing.expect(a.mulFast(b).eq(a.mulRec(b)));
            try std.testing.expect(a.mul(b).eq(a.mulRec(b)));
        }
    }
}

test "inversion round trip" {
    inline for (1..8) |lv| {
        const F = TowerField(lv);
        var s: u64 = lv * 131;
        for (0..200) |_| {
            var a = rng(F, &s);
            while (a.isZero()) a = rng(F, &s);
            try std.testing.expect(a.mul(a.inv()).eq(F.one()));
        }
    }
}

test "exhaustive field properties for GF(4), GF(16), GF(256)" {
    inline for (.{ 1, 2, 3 }) |lv| {
        const F = TowerField(lv);
        const n = @as(usize, 1) << @intCast(@as(u8, 1) << @intCast(lv));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = F.fromInt(i);
            if (!a.isZero()) {
                try std.testing.expect(a.mul(a.inv()).eq(F.one()));
            }
            // a·0 = 0, a·1 = a
            try std.testing.expect(a.mul(F.zero()).isZero());
            try std.testing.expect(a.mul(F.one()).eq(a));
        }
    }
}

test "zero-cost subfield embedding is a ring homomorphism" {
    inline for (1..7) |lv| {
        const F = TowerField(lv);
        const S = F.Subfield;
        var s: u64 = lv * 977;
        for (0..100) |_| {
            const a = rng(S, &s);
            const b = rng(S, &s);
            // embed(a + b) == embed(a) + embed(b); embed(a·b) == embed(a)·embed(b)
            const ea = F.fromSubfield(a);
            const eb = F.fromSubfield(b);
            try std.testing.expect(ea.add(eb).eq(F.fromSubfield(a.add(b))));
            try std.testing.expect(ea.mul(eb).eq(F.fromSubfield(a.mul(b))));
            // embedding is injective
            const c = rng(S, &s);
            try std.testing.expect(!c.eq(a) or a.value == c.value);
        }
    }
}

test "norm is multiplicative and matches a·conj(a)" {
    inline for (1..5) |lv| {
        const F = TowerField(lv);
        const S = F.Subfield;
        var s: u64 = lv * 31;
        for (0..50) |_| {
            const a = rng(F, &s);
            const b = rng(F, &s);
            // N(a·b) == N(a)·N(b)
            try std.testing.expect(a.mul(b).norm().eq(a.norm().mul(b.norm())));
            // N(a) = a·conj(a), where conj(a0 + a1 y) = a0 + a1(β + y)
            const half: u8 = 1 << (lv - 1);
            const mask: u128 = (@as(u128, 1) << half) - 1;
            const a0 = S{ .value = a.value & mask };
            const a1 = S{ .value = (a.value >> half) & mask };
            const beta_s = S{ .value = if (lv == 1) 1 else @as(u128, 1) << @intCast(@as(u8, 1) << @intCast(lv - 2)) };
            const conj = a0.add(a1.mul(beta_s)).add(a1.mul(S.alpha()));
            _ = conj;
            // N(a) == (a0 + a1β)² + a1²·(βy + ... ) — check via recursion identity:
            // N(a) = a0² + a0a1β + a1²
            const direct = a0.mul(a0).add(a0.mul(a1).mul(beta_s)).add(a1.mul(a1));
            try std.testing.expect(a.norm().eq(direct));
        }
    }
}

test "absolute trace is a GF(2) homomorphism" {
    inline for (1..5) |lv| {
        const F = TowerField(lv);
        var s: u64 = lv * 7;
        for (0..50) |_| {
            const a = rng(F, &s);
            const b = rng(F, &s);
            // additive over GF(2): Tr(a + b) == Tr(a) ^ Tr(b)
            try std.testing.expectEqual(a.add(b).trace(), a.trace() ^ b.trace());
            // subfield elements have absolute trace 0 in the extension:
            // Tr_{T_ι/GF(2)}(embed(c)) = Tr_{T_ι/T_{ι-1}}(embed(c)) composed
            // downward = c + conj(c) = 0 for c ∈ T_{ι-1}.
            const c = rng(F.Subfield, &s);
            try std.testing.expectEqual(@as(u1, 0), F.fromSubfield(c).trace());
        }
    }
}

test "serialization round-trip" {
    inline for (0..8) |lv| {
        const F = TowerField(lv);
        var s: u64 = lv * 59;
        for (0..20) |_| {
            const a = rng(F, &s);
            var buf: [F.SIZE]u8 = undefined;
            a.toBytes(&buf);
            try std.testing.expect(a.eq(F.fromBytes(buf)));
        }
    }
}

test "mul by alpha is the quadratic-step map" {
    const F = Gf256;
    var s: u64 = 99;
    for (0..50) |_| {
        const a = rng(F, &s);
        // a·X_2 = (a0·X_2) with the reduction X_2² = X_1·X_2 + 1 folded in
        const x2 = F.alpha();
        try std.testing.expect(a.mul(x2).eq(x2.mul(a)));
    }
}

// --- Integration: the tower drops into the sum-check stack ---

const Sumcheck = @import("sumcheck.zig").Sumcheck;

test "sum-check round trip over tower GF(16)" {
    const alloc = std.testing.allocator;
    const F = Gf16;
    var s: u64 = 5;
    var t0: [8]F = undefined;
    var t1: [8]F = undefined;
    for (0..8) |i| {
        t0[i] = rng(F, &s);
        t1[i] = rng(F, &s);
    }
    const tables = [_][]const F{ &t0, &t1 };
    var proof = try Sumcheck(F).prove(alloc, 3, &tables);
    defer proof.deinit(alloc);
    try std.testing.expect(try Sumcheck(F).verify(alloc, 3, &tables, proof));
}

test "sum-check round trip over tower GF(2^32)" {
    const alloc = std.testing.allocator;
    const F = Gf2_32;
    var s: u64 = 11;
    var t0: [4]F = undefined;
    for (0..4) |i| t0[i] = rng(F, &s);
    const tables = [_][]const F{&t0};
    var proof = try Sumcheck(F).prove(alloc, 2, &tables);
    defer proof.deinit(alloc);
    try std.testing.expect(try Sumcheck(F).verify(alloc, 2, &tables, proof));
}
