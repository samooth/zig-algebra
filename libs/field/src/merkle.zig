// SPDX-License-Identifier: MIT OR Apache-2.0

//! Merkle tree over finite field elements.
//!
//! Uses SHA-256 for hashing. Leaves are field elements serialized via `toBytes()`.
//! Supports inclusion proofs (path + sibling hashes) and batch verification.
//!
//! ## Usage
//! ```zig
//! var tree = try MerkleTree(F).init(allocator, &leaves);
//! defer tree.deinit();
//! const root = tree.rootHash();
//! const proof = try tree.proof(allocator, 3); // leaf index 3
//! try MerkleTree(F).verify(root, 3, &proof, leaf);
//! ```

const std = @import("std");

pub fn MerkleTree(comptime F: type) type {
    return struct {
        const Self = @This();
        const Hash = [32]u8;

        allocator: std.mem.Allocator,
        leaves: []const F,
        nodes: []Hash,
        num_leaves: usize,

        /// Build a Merkle tree from field elements.
        /// `leaves` is copied internally.
        pub fn init(allocator: std.mem.Allocator, leaves: []const F) !Self {
            if (leaves.len == 0) return error.EmptyLeaves;
            const num_leaves = std.math.ceilPowerOfTwo(usize, leaves.len) catch @as(usize, 0);
            const total_nodes = 2 * num_leaves - 1;
            const nodes = try allocator.alloc(Hash, total_nodes);
            errdefer allocator.free(nodes);

            // Copy leaves
            const leaf_copy = try allocator.alloc(F, leaves.len);
            errdefer allocator.free(leaf_copy);
            @memcpy(leaf_copy, leaves);

            // Build tree bottom-up
            var tree = Self{
                .allocator = allocator,
                .leaves = leaf_copy,
                .nodes = nodes,
                .num_leaves = num_leaves,
            };
            try tree.build();
            return tree;
        }

        fn build(self: *Self) !void {
            const n = self.num_leaves;
            // Hash leaves
            for (0..self.leaves.len) |i| {
                self.nodes[n - 1 + i] = hashLeaf(self.leaves[i]);
            }
            // Pad remaining leaves with zero
            for (self.leaves.len..n) |i| {
                self.nodes[n - 1 + i] = hashLeaf(F.zero());
            }
            // Build internal nodes
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                self.nodes[i] = hashPair(self.nodes[2 * i + 1], self.nodes[2 * i + 2]);
            }
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.nodes);
            self.allocator.free(@constCast(self.leaves));
        }

        /// Root hash of the tree.
        pub fn rootHash(self: Self) Hash {
            return self.nodes[0];
        }

        /// Inclusion proof for leaf at `index`.
        /// Returns the sibling hashes from leaf to root.
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

        /// Verify an inclusion proof.
        pub fn verify(root: Hash, index: usize, proof_path: []const Hash, leaf: F) bool {
            var current = hashLeaf(leaf);
            var idx = index;
            for (proof_path) |sibling| {
                if (idx % 2 == 0) {
                    current = hashPair(current, sibling);
                } else {
                    current = hashPair(sibling, current);
                }
                idx /= 2;
            }
            return std.mem.eql(u8, &current, &root);
        }

        /// Batch verify multiple proofs (more efficient than individual verify).
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

        // -- Helpers --------------------------------------------------------

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
    };
}
