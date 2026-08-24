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

const ntt_ = @import("zig-ntt");
const merkle_ = @import("zig-merkle");
const commitment_ = @import("zig-commitment");

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

// NTT / INTT (from zig-ntt)
pub const bitReverse = ntt_.bitReverse;
pub const ntt = ntt_.ntt;
pub const intt = ntt_.intt;
pub const precomputeTwiddles = ntt_.precomputeTwiddles;
pub const freeTwiddles = ntt_.freeTwiddles;
pub const nttWithTwiddles = ntt_.nttWithTwiddles;
pub const inttWithTwiddles = ntt_.inttWithTwiddles;

// M31-specific Vec8 SIMD NTT (stays in zig-field)
pub const Vec8NttM31 = struct {
    // Forward NTT using 8-lane SIMD for M31
    pub fn nttVec8M31(data: []M31, log_n: usize, root: M31) void {
        const std = @import("std");
        const n = std.math.pow(usize, 2, log_n);
        std.debug.assert(data.len == 8 * n);

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

    pub fn inttVec8M31(data: []M31, log_n: usize, root: M31) void {
        const std = @import("std");
        const n = std.math.pow(usize, 2, log_n);
        std.debug.assert(data.len == 8 * n);

        const root_inv = root.inv();
        Vec8NttM31.nttVec8M31(data, log_n, root_inv);

        const n_inv = M31.fromInt(n).inv();
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            data[i] = data[i].mul(n_inv);
        }
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

        pub fn verifyBatch(
            root: Hash,
            indices: []const usize,
            proofs: []const []const Hash,
            leaves: []const F,
        ) bool {
            std.debug.assert(indices.len == proofs.len and proofs.len == leaves.len);
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

// IPA (Inner Product Argument) from zig-commitment
pub const Ipa = commitment_.Ipa;

// M31 Vec8 SIMD NTT
pub const nttVec8M31 = Vec8NttM31.nttVec8M31;
pub const inttVec8M31 = Vec8NttM31.inttVec8M31;

// ============================================================================
// Property-based tests: ring/field axioms over random elements
// ============================================================================

const stdx = @import("std");
const testing = stdx.testing;

fn checkFieldAxioms(comptime F: type, iterations: usize, seed: u64) !void {
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
