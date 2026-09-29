// SPDX-License-Identifier: MIT OR Apache-2.0

//! zig-field: generic prime-field arithmetic for Zig.
//!
//! See `field.zig` for the generic `Field()` factory, `extension.zig` for
//! tower extensions, and `predef/` for the predefined STARK/SNARK fields.

pub const montgomery = @import("montgomery.zig");
pub const roots = @import("roots.zig");
pub const field = @import("field.zig");
pub const extension = @import("extension.zig");
pub const predef = @import("predef/predef.zig");

const ipa_ = @import("ipa.zig");

pub const Field = field.Field;
pub const QuadraticExtension = extension.QuadraticExtension;
pub const CubicExtension = extension.CubicExtension;

// Base fields.
pub const M31 = predef.M31;
pub const BabyBear = predef.BabyBear;
pub const KoalaBear = predef.KoalaBear;
pub const Goldilocks = predef.Goldilocks;
pub const M61 = predef.M61;
pub const StarkNet_Fp = predef.StarkNet_Fp;
pub const Pallas_Fp = predef.Pallas_Fp;
pub const Vesta_Fp = predef.Vesta_Fp;
pub const BN254_Fp = predef.BN254_Fp;
pub const BLS12_381_Fp = predef.BLS12_381_Fp;
pub const BLS12_381_Fp2 = predef.BLS12_381_Fp2;

// Extension towers.
pub const CM31 = extension.CM31;
pub const QM31 = extension.QM31;
pub const BN254_Fp2 = extension.BN254_Fp2;

// M31-specific Vec8 SIMD NTT (stays in zig-field)
pub const Vec8NttM31 = struct {
    const std = @import("std");

    // Forward NTT using 8-lane SIMD for M31.
    //
    // `data.len` must be exactly `8 * 2^log_n`. The legacy `void` entry point
    // leaves `data` untouched when it does not match (the old assert was
    // compiled out in ReleaseFast, where the butterflies then read and wrote
    // out of bounds); use `nttVec8M31Checked` to detect the mismatch.
    pub fn nttVec8M31(data: []M31, log_n: usize, root: M31) void {
        Vec8NttM31.nttVec8M31Checked(data, log_n, root) catch {};
    }

    pub fn nttVec8M31Checked(data: []M31, log_n: usize, root: M31) !void {
        const n = try transformSize(log_n);
        const expected = std.math.mul(usize, 8, n) catch return error.InvalidLength;
        if (data.len != expected) return error.InvalidLength;

        // Bit-reversal per lane
        var lane: usize = 0;
        while (lane < 8) : (lane += 1) {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var j: usize = 0;
                var k: usize = 0;
                while (k < log_n) : (k += 1) {
                    j = (j << 1) | ((i >> @intCast(k)) & 1);
                }
                if (j > i) {
                    const tmp = data[i * 8 + lane];
                    data[i * 8 + lane] = data[j * 8 + lane];
                    data[j * 8 + lane] = tmp;
                }
            }
        }

        // Cooley-Tukey with Vec8 butterflies
        var s: usize = 1;
        while (s <= log_n) : (s += 1) {
            const m = std.math.pow(usize, 2, s);
            const half_m = m >> 1;
            const wm = root.pow(@as(u64, 1) << @intCast(log_n - s));

            var k: usize = 0;
            while (k < n) : (k += m) {
                var w = M31.one();
                var j: usize = 0;
                while (j < half_m) : (j += 1) {
                    var u_vec: M31.Vec8 = undefined;
                    var t_vec: M31.Vec8 = undefined;
                    inline for (0..8) |l| {
                        u_vec[l] = data[(k + j) * 8 + l].value;
                        t_vec[l] = w.mul(data[(k + j + half_m) * 8 + l]).value;
                    }

                    const sum = M31.reduceVec8(M31.addVec8(u_vec, t_vec));
                    const diff = M31.reduceVec8(M31.subVec8(u_vec, t_vec));

                    inline for (0..8) |l| {
                        data[(k + j) * 8 + l] = .{ .value = sum[l] };
                        data[(k + j + half_m) * 8 + l] = .{ .value = diff[l] };
                    }

                    w = w.mul(wm);
                }
            }
        }
    }

    // Inverse NTT: forward transform with inverted twiddles, then scale by 1/n.
    // Same length contract as `nttVec8M31`.
    pub fn inttVec8M31(data: []M31, log_n: usize, root: M31) void {
        Vec8NttM31.inttVec8M31Checked(data, log_n, root) catch {};
    }

    pub fn inttVec8M31Checked(data: []M31, log_n: usize, root: M31) !void {
        const n = try transformSize(log_n);
        const expected = std.math.mul(usize, 8, n) catch return error.InvalidLength;
        if (data.len != expected) return error.InvalidLength;

        // `n >= 1`, so `n` is invertible; a zero `root` has no inverse and
        // yields a zero transform (see `M31.inv`) instead of hanging.
        const root_inv = root.inv();
        try Vec8NttM31.nttVec8M31Checked(data, log_n, root_inv);

        const n_inv = M31.fromInt(n).inv();
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            data[i] = data[i].mul(n_inv);
        }
    }

    /// `2^log_n`, rejecting sizes whose `8 * 2^log_n` would not fit in a
    /// `usize` (and hence whose length check could not be trusted).
    fn transformSize(log_n: usize) !usize {
        if (log_n >= @bitSizeOf(usize) - 3) return error.InvalidLength;
        return @as(usize, 1) << @intCast(log_n);
    }
};

// Merkle tree over field elements (wrapper around zig-merkle with SHA-256)
pub fn MerkleTree(comptime F: type) type {
    const std = @import("std");
    const Hash = [32]u8;

    const MerkleTreeImpl = struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        leaves: []const F,
        nodes: []Hash,
        num_leaves: usize,

        fn hashLeaf(leaf: F) Hash {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            const bytes = leaf.toBytes();
            hasher.update(&bytes);
            var out: Hash = undefined;
            hasher.final(&out);
            return out;
        }

        fn hashPair(left: Hash, right: Hash) Hash {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&left);
            hasher.update(&right);
            var out: Hash = undefined;
            hasher.final(&out);
            return out;
        }

        pub fn init(allocator: std.mem.Allocator, leaves: []const F) !Self {
            if (leaves.len == 0) return error.EmptyLeaves;
            const num_leaves = std.math.ceilPowerOfTwo(usize, leaves.len) catch @as(usize, 0);
            const total_nodes = 2 * num_leaves - 1;
            const nodes = try allocator.alloc(Hash, total_nodes);
            errdefer allocator.free(nodes);

            const leaf_copy = try allocator.alloc(F, leaves.len);
            errdefer allocator.free(leaf_copy);
            @memcpy(leaf_copy, leaves);

            var tree = Self{
                .allocator = allocator,
                .leaves = leaf_copy,
                .nodes = nodes,
                .num_leaves = num_leaves,
            };
            tree.build();
            return tree;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.nodes);
            self.allocator.free(@constCast(self.leaves));
        }

        pub fn rootHash(self: Self) Hash {
            return self.nodes[0];
        }

        pub fn proof(self: Self, allocator: std.mem.Allocator, index: usize) ![]Hash {
            if (index >= self.leaves.len) return error.IndexOutOfBounds;
            const depth = @ctz(self.num_leaves) + 1;
            var path = try allocator.alloc(Hash, depth - 1);
            errdefer allocator.free(path);

            var idx = index;
            var level_size = self.num_leaves;
            var node_offset = level_size - 1;
            var i: usize = 0;
            while (level_size > 1) {
                const sibling = if (idx % 2 == 0) idx + 1 else idx - 1;
                path[i] = self.nodes[node_offset + sibling];
                idx /= 2;
                level_size /= 2;
                node_offset -= level_size;
                i += 1;
            }
            return path;
        }

        pub fn verify(root: Hash, index: usize, proof_path: []const Hash, leaf: F) bool {
            var current = Self.hashLeaf(leaf);
            var idx = index;
            for (proof_path) |sibling| {
                if (idx % 2 == 0) {
                    current = Self.hashPair(current, sibling);
                } else {
                    current = Self.hashPair(sibling, current);
                }
                idx /= 2;
            }
            return std.mem.eql(u8, &current, &root);
        }

        /// Batch verification of Merkle openings.
        ///
        /// Fail-closed on a length mismatch: the old `std.debug.assert` was
        /// compiled out in ReleaseFast, where the multi-slice `for` then
        /// verified only the first `min(len)` entries and still returned `true`.
        pub fn verifyBatch(
            root: Hash,
            indices: []const usize,
            proofs: []const []const Hash,
            leaves: []const F,
        ) bool {
            if (indices.len != proofs.len or proofs.len != leaves.len) return false;
            for (indices, proofs, leaves) |idx, prf, leaf| {
                if (!verify(root, idx, prf, leaf)) return false;
            }
            return true;
        }

        fn build(self: *Self) void {
            const n = self.num_leaves;
            for (0..self.leaves.len) |i| {
                self.nodes[n - 1 + i] = Self.hashLeaf(self.leaves[i]);
            }
            for (self.leaves.len..n) |i| {
                self.nodes[n - 1 + i] = Self.hashLeaf(F.zero());
            }
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                self.nodes[i] = Self.hashPair(self.nodes[2 * i + 1], self.nodes[2 * i + 2]);
            }
        }
    };

    return MerkleTreeImpl;
}

// IPA (Inner Product Argument)
pub const Ipa = ipa_.Ipa;

// M31 Vec8 SIMD NTT
pub const nttVec8M31 = Vec8NttM31.nttVec8M31;
pub const inttVec8M31 = Vec8NttM31.inttVec8M31;
pub const nttVec8M31Checked = Vec8NttM31.nttVec8M31Checked;
pub const inttVec8M31Checked = Vec8NttM31.inttVec8M31Checked;

// ============================================================================
// Property-based tests: ring/field axioms over random elements
// ============================================================================

const stdx = @import("std");
const testing = stdx.testing;

pub fn checkFieldAxioms(comptime F: type, iterations: usize, seed: u64) !void {
    var prng = stdx.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (0..iterations) |_| {
        const a = F.random(rand);
        const b = F.random(rand);
        const c = F.random(rand);

        // Additive associativity: (a+b)+c == a+(b+c)
        try testing.expect(a.add(b).add(c).eql(a.add(b.add(c))));

        // Additive commutativity: a+b == b+a
        try testing.expect(a.add(b).eql(b.add(a)));

        // Additive identity: a+0 == a
        try testing.expect(a.add(F.zero()).eql(a));

        // Additive inverse: a+(-a) == 0
        try testing.expect(a.add(a.neg()).isZero());

        // Multiplicative associativity: (a*b)*c == a*(b*c)
        try testing.expect(a.mul(b).mul(c).eql(a.mul(b.mul(c))));

        // Multiplicative commutativity: a*b == b*a
        try testing.expect(a.mul(b).eql(b.mul(a)));

        // Multiplicative identity: a*1 == a
        try testing.expect(a.mul(F.one()).eql(a));

        // Distributivity: a*(b+c) == a*b + a*c
        try testing.expect(a.mul(b.add(c)).eql(a.mul(b).add(a.mul(c))));

        // Squaring consistency: a^2 == a*a
        if (@hasDecl(F, "sqr")) {
            try testing.expect(a.sqr().eql(a.mul(a)));
        }

        // Inversion round-trip: a * a^-1 == 1 (for nonzero a)
        if (!a.isZero()) {
            if (@hasDecl(F, "inv")) {
                const inv_a = a.inv();
                try testing.expect(a.mul(inv_a).eql(F.one()));
                try testing.expect(inv_a.mul(a).eql(F.one()));
            }
        }

        // Byte round-trip: toBytes(fromBytes(x)) == x
        const bytes = a.toBytes();
        const recovered = try F.fromBytes(&bytes);
        try testing.expect(recovered.eql(a));
    }
}

test "property: SmallField M31 axioms" {
    try checkFieldAxioms(predef.M31, 200, 0xC0FFEE);
}

test "property: BN254_Fp axioms" {
    try checkFieldAxioms(predef.BN254_Fp, 20, 0xBEEF);
}

test "property: BLS12_381_Fp axioms" {
    try checkFieldAxioms(predef.BLS12_381_Fp, 5, 0xDEAD);
}

// Vectors generated in Python: `a+b`, `a*b`, `pow(a, -1, p)` and `-b` mod p
// over five predefined fields, from a fixed LCG, so the inputs are
// reproducible and obviously not chosen to suit the implementation. Nothing in
// this repository produced them, and one test covers both backends: M31,
// BabyBear and Goldilocks take the small-field path (u64, with a Mersenne
// fast path for the first two), StarkNet_Fp and BLS12_381_Fp the Montgomery
// CIOS path over u64 limbs.
test "field arithmetic matches Python's integers modulo the same prime" {
    const Vec = struct {
        a: comptime_int,
        b: comptime_int,
        sum: comptime_int,
        prod: comptime_int,
        inv_a: comptime_int,
        neg_b: comptime_int,
    };
    const vectors = [_]Vec{
        // M31 (31 bits)
        .{ .a = 0x7ffffffe, .b = 0x1, .sum = 0x0, .prod = 0x7ffffffe, .inv_a = 0x7ffffffe, .neg_b = 0x7ffffffe },
        .{ .a = 0x7ffffffe, .b = 0x2, .sum = 0x1, .prod = 0x7ffffffd, .inv_a = 0x7ffffffe, .neg_b = 0x7ffffffd },
        .{ .a = 0x7ffffffd, .b = 0x3, .sum = 0x1, .prod = 0x7ffffff9, .inv_a = 0x3fffffff, .neg_b = 0x7ffffffc },
        .{ .a = 0x7ffffffe, .b = 0x7ffffffe, .sum = 0x7ffffffd, .prod = 0x1, .inv_a = 0x7ffffffe, .neg_b = 0x1 },
        .{ .a = 0x7ffffffe, .b = 0x7ffffffd, .sum = 0x7ffffffc, .prod = 0x2, .inv_a = 0x7ffffffe, .neg_b = 0x2 },
        .{ .a = 0x7ffffffe, .b = 0x3fffffff, .sum = 0x3ffffffe, .prod = 0x40000000, .inv_a = 0x7ffffffe, .neg_b = 0x40000000 },
        .{ .a = 0x191c9844, .b = 0x6f1b77eb, .sum = 0x8381030, .prod = 0x78ff9205, .inv_a = 0x69540e33, .neg_b = 0x10e48814 },
        .{ .a = 0x54b0a9c9, .b = 0x6f580ba0, .sum = 0x4408b56a, .prod = 0x53793502, .inv_a = 0x50f3f840, .neg_b = 0x10a7f45f },
        .{ .a = 0x5951755f, .b = 0x34a2c9b2, .sum = 0xdf43f12, .prod = 0x46a3e293, .inv_a = 0x733df0cc, .neg_b = 0x4b5d364d },
        // BabyBear (31 bits)
        .{ .a = 0x78000000, .b = 0x1, .sum = 0x0, .prod = 0x78000000, .inv_a = 0x78000000, .neg_b = 0x78000000 },
        .{ .a = 0x78000000, .b = 0x2, .sum = 0x1, .prod = 0x77ffffff, .inv_a = 0x78000000, .neg_b = 0x77ffffff },
        .{ .a = 0x77ffffff, .b = 0x3, .sum = 0x1, .prod = 0x77fffffb, .inv_a = 0x3c000000, .neg_b = 0x77fffffe },
        .{ .a = 0x78000000, .b = 0x78000000, .sum = 0x77ffffff, .prod = 0x1, .inv_a = 0x78000000, .neg_b = 0x1 },
        .{ .a = 0x78000000, .b = 0x77ffffff, .sum = 0x77fffffe, .prod = 0x2, .inv_a = 0x78000000, .neg_b = 0x2 },
        .{ .a = 0x78000000, .b = 0x3c000000, .sum = 0x3bffffff, .prod = 0x3c000001, .inv_a = 0x78000000, .neg_b = 0x3c000001 },
        .{ .a = 0x7773aeed, .b = 0x5e5dd759, .sum = 0x5dd18645, .prod = 0x634a5bf5, .inv_a = 0x748c4416, .neg_b = 0x19a228a8 },
        .{ .a = 0x5da65564, .b = 0xc91a1e4, .sum = 0x6a37f748, .prod = 0x27acdacc, .inv_a = 0x4ff81e57, .neg_b = 0x6b6e5e1d },
        .{ .a = 0x23fef3ee, .b = 0x53d04d2b, .sum = 0x77cf4119, .prod = 0x356d6643, .inv_a = 0x4f08d3bf, .neg_b = 0x242fb2d6 },
        // Goldilocks (64 bits)
        .{ .a = 0xffffffff00000000, .b = 0x1, .sum = 0x0, .prod = 0xffffffff00000000, .inv_a = 0xffffffff00000000, .neg_b = 0xffffffff00000000 },
        .{ .a = 0xffffffff00000000, .b = 0x2, .sum = 0x1, .prod = 0xfffffffeffffffff, .inv_a = 0xffffffff00000000, .neg_b = 0xfffffffeffffffff },
        .{ .a = 0xfffffffeffffffff, .b = 0x3, .sum = 0x1, .prod = 0xfffffffefffffffb, .inv_a = 0x7fffffff80000000, .neg_b = 0xfffffffefffffffe },
        .{ .a = 0xffffffff00000000, .b = 0xffffffff00000000, .sum = 0xfffffffeffffffff, .prod = 0x1, .inv_a = 0xffffffff00000000, .neg_b = 0x1 },
        .{ .a = 0xffffffff00000000, .b = 0xfffffffeffffffff, .sum = 0xfffffffefffffffe, .prod = 0x2, .inv_a = 0xffffffff00000000, .neg_b = 0x2 },
        .{ .a = 0xffffffff00000000, .b = 0x80000000, .sum = 0x7fffffff, .prod = 0xfffffffe80000001, .inv_a = 0xffffffff00000000, .neg_b = 0xfffffffe80000001 },
        .{ .a = 0x2ceaee21bf46bc00, .b = 0xaa80754d1a1a8d4f, .sum = 0xd76b636ed961494f, .prod = 0x1aad68a9967d4a33, .inv_a = 0xe9ff10367cf72671, .neg_b = 0x557f8ab1e5e572b2 },
        .{ .a = 0xb3c4904a6d278932, .b = 0xbc69cf4276846d19, .sum = 0x702e5f8de3abf64a, .prod = 0x8137de25507d40de, .inv_a = 0x2512512fe7c16db8, .neg_b = 0x439630bc897b92e8 },
        .{ .a = 0x377b2fd56a5b15b4, .b = 0x64d815deeaf29df3, .sum = 0x9c5345b4554db3a7, .prod = 0xf927285da2c98df8, .inv_a = 0x7e02144ec7aea3a5, .neg_b = 0x9b27ea20150d620e },
        // StarkNet_Fp (252 bits)
        .{ .a = 0x800000000000011000000000000000000000000000000000000000000000000, .b = 0x1, .sum = 0x0, .prod = 0x800000000000011000000000000000000000000000000000000000000000000, .inv_a = 0x800000000000011000000000000000000000000000000000000000000000000, .neg_b = 0x800000000000011000000000000000000000000000000000000000000000000 },
        .{ .a = 0x800000000000011000000000000000000000000000000000000000000000000, .b = 0x2, .sum = 0x1, .prod = 0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff, .inv_a = 0x800000000000011000000000000000000000000000000000000000000000000, .neg_b = 0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff },
        .{ .a = 0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff, .b = 0x3, .sum = 0x1, .prod = 0x800000000000010fffffffffffffffffffffffffffffffffffffffffffffffb, .inv_a = 0x400000000000008800000000000000000000000000000000000000000000000, .neg_b = 0x800000000000010fffffffffffffffffffffffffffffffffffffffffffffffe },
        .{ .a = 0x800000000000011000000000000000000000000000000000000000000000000, .b = 0x800000000000011000000000000000000000000000000000000000000000000, .sum = 0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff, .prod = 0x1, .inv_a = 0x800000000000011000000000000000000000000000000000000000000000000, .neg_b = 0x1 },
        .{ .a = 0x800000000000011000000000000000000000000000000000000000000000000, .b = 0x800000000000010ffffffffffffffffffffffffffffffffffffffffffffffff, .sum = 0x800000000000010fffffffffffffffffffffffffffffffffffffffffffffffe, .prod = 0x2, .inv_a = 0x800000000000011000000000000000000000000000000000000000000000000, .neg_b = 0x2 },
        .{ .a = 0x800000000000011000000000000000000000000000000000000000000000000, .b = 0x80000000, .sum = 0x7fffffff, .prod = 0x800000000000010ffffffffffffffffffffffffffffffffffffffff80000001, .inv_a = 0x800000000000011000000000000000000000000000000000000000000000000, .neg_b = 0x800000000000010ffffffffffffffffffffffffffffffffffffffff80000001 },
        .{ .a = 0x2ceaee21bf46bc00, .b = 0xaa80754d1a1a8d4f, .sum = 0xd76b636ed961494f, .prod = 0x1dea8c2e5ff82d9ebab53b0b14600400, .inv_a = 0x1d2bd0b65546f5f06ef3fd4e052f43e6cf086cac9571b6fabd505c4564575d8, .neg_b = 0x800000000000010ffffffffffffffffffffffffffffffff557f8ab2e5e572b2 },
        .{ .a = 0xb3c4904a6d278932, .b = 0xbc69cf4276846d19, .sum = 0x1702e5f8ce3abf64b, .prod = 0x844ea7207342c7e40df51642480eafe2, .inv_a = 0x5cec8ad4b40783eb2e9c3bc6ba87ca275123d9993b9aa26e2019e30904c40bf, .neg_b = 0x800000000000010ffffffffffffffffffffffffffffffff439630bd897b92e8 },
        .{ .a = 0x377b2fd56a5b15b4, .b = 0x64d815deeaf29df3, .sum = 0x9c5345b4554db3a7, .prod = 0x15daf35d24487c87d4deabd6dcecfddc, .inv_a = 0x3269b813e839e8a8e3674084af41861986dbff208011bf26c05abef6e525f1b, .neg_b = 0x800000000000010ffffffffffffffffffffffffffffffff9b27ea21150d620e },
        // BLS12_381_Fp (381 bits)
        .{ .a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .b = 0x1, .sum = 0x0, .prod = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .inv_a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa },
        .{ .a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .b = 0x2, .sum = 0x1, .prod = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9, .inv_a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9 },
        .{ .a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9, .b = 0x3, .sum = 0x1, .prod = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa5, .inv_a = 0xd0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa8 },
        .{ .a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .sum = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9, .prod = 0x1, .inv_a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .neg_b = 0x1 },
        .{ .a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa9, .sum = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaa8, .prod = 0x2, .inv_a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .neg_b = 0x2 },
        .{ .a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .b = 0x80000000, .sum = 0x7fffffff, .prod = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffff7fffaaab, .inv_a = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaaa, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffff7fffaaab },
        .{ .a = 0x2ceaee21bf46bc00, .b = 0xaa80754d1a1a8d4f, .sum = 0xd76b636ed961494f, .prod = 0x1dea8c2e5ff82d9ebab53b0b14600400, .inv_a = 0x1d219de41da12f6edefa6feceb7267223d704161e45067a757b3fbbb460515b5b08156320cf74f86e534c23f4ae1391, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffff0f7e8ab2e5e51d5c },
        .{ .a = 0xb3c4904a6d278932, .b = 0xbc69cf4276846d19, .sum = 0x1702e5f8ce3abf64b, .prod = 0x844ea7207342c7e40df51642480eafe2, .inv_a = 0xffc292a89be4ba04c4f20a825c1949df935f96bf7b423711c20d518d441201bce7764166ebfb4fd005c614deb58f33b, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153fffefd9530bd897b3d92 },
        .{ .a = 0x377b2fd56a5b15b4, .b = 0x64d815deeaf29df3, .sum = 0x9c5345b4554db3a7, .prod = 0x15daf35d24487c87d4deabd6dcecfddc, .inv_a = 0x4cc7ad643e7c5e328cf5b3bc3e563133b20cd2bebffcfa47f4f2958cb6f7b653f59096fcbf98a85679e5456e49c394, .neg_b = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffff5526ea21150d0cb8 },
    };

    const Check = struct {
        fn run(comptime F: type, comptime from: usize, comptime to: usize) !void {
            comptime var k: usize = from;
            inline while (k < to) : (k += 1) {
                const v = vectors[k];
                const a = F.fromInt(v.a);
                const b = F.fromInt(v.b);
                try testing.expect(a.add(b).eql(F.fromInt(v.sum)));
                try testing.expect(a.mul(b).eql(F.fromInt(v.prod)));
                try testing.expect((try a.invChecked()).eql(F.fromInt(v.inv_a)));
                try testing.expect(b.neg().eql(F.fromInt(v.neg_b)));
            }
        }
    };

    // Comptime bounds, so the grouping cannot drift from the fixture.
    try Check.run(predef.M31, 0, 9);
    try Check.run(predef.BabyBear, 9, 18);
    try Check.run(predef.Goldilocks, 18, 27);
    try Check.run(predef.StarkNet_Fp, 27, 36);
    try Check.run(predef.BLS12_381_Fp, 36, 45);
}

test "M31 canonical arithmetic and encoding vectors" {
    const three = predef.M31.fromInt(3);
    try testing.expectEqual(@as(u64, 1431655765), three.inv().toU64());
    try testing.expectEqual(@as(u64, 1), predef.M31.fromInt(0xffffffff).toU64());

    const canonical = [_]u8{ 0xfe, 0xff, 0xff, 0x7f };
    try testing.expectEqualSlices(u8, &canonical, &predef.M31.fromInt(0x7ffffffe).toBytes());
    try testing.expectError(error.ValueOutOfRange, predef.M31.fromBytes(&[_]u8{ 0xff, 0xff, 0xff, 0x7f }));
}
