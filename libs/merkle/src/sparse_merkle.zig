//! Sparse Merkle Tree (SMT).
//!
//! A Sparse Merkle Tree is a perfect binary tree of fixed depth (typically 256)
//! where most leaves are empty (zero).  Only non-empty leaves are stored.
//! Empty subtrees are represented by a single "default" hash at each level.
//!
//! SMTs are used in:
//! - Ethereum state tries
//! - Zcash shielded pools
//! - Key-value commitments with non-membership proofs
//!
//! # Usage
//! ```zig
//! var smt = try SparseMerkleTree(Blake3, 256).init(allocator);
//! defer smt.deinit();
//! try smt.update(key, value);
//! const root = smt.root();
//! const proof = try smt.prove(key, allocator);
//! const ok = smt.verify(root, key, value, proof);
//! ```

const std = @import("std");

const HASH_LEN = 32;

/// Sparse Merkle Tree with configurable depth.
///
/// `H`: hash function type with `hash(input: []const u8) [HASH_LEN]u8`
/// `DEPTH`: tree depth in bits (e.g. 256 for 2^256 leaves)
pub fn SparseMerkleTree(comptime H: type, comptime DEPTH: usize) type {
    if (DEPTH > 256) @compileError("SparseMerkleTree: DEPTH must be <= 256");

    return struct {
        const Self = @This();

        /// Default hashes for each level: default_hash[level] = hash(default_hash[level+1], default_hash[level+1]).
        default_hashes: [DEPTH + 1][HASH_LEN]u8,
        /// Map from leaf index (u256) to leaf hash.
        leaves: std.AutoHashMap(u256, [HASH_LEN]u8),
        /// Map from (level, node_index) to cached hash.
        cache: std.AutoHashMap(struct { level: u8, index: u256 }, [HASH_LEN]u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var default_hashes: [DEPTH + 1][HASH_LEN]u8 = undefined;
            // Leaf level default = hash of empty string
            default_hashes[DEPTH] = H.hashBytes(&[_]u8{});
            // Build defaults bottom-up
            var level = DEPTH;
            while (level > 0) {
                level -= 1;
                var concat: [HASH_LEN * 2]u8 = undefined;
                @memcpy(concat[0..HASH_LEN], &default_hashes[level + 1]);
                @memcpy(concat[HASH_LEN..], &default_hashes[level + 1]);
                default_hashes[level] = H.hashBytes(&concat);
            }

            return .{
                .default_hashes = default_hashes,
                .leaves = std.AutoHashMap(u256, [HASH_LEN]u8).init(allocator),
                .cache = std.AutoHashMap(struct { level: u8, index: u256 }, [HASH_LEN]u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.leaves.deinit();
            self.cache.deinit();
        }

        /// Update a leaf at `index` with `value`.
        pub fn update(self: *Self, index: u256, value: []const u8) !void {
            const leaf_hash = H.hash(value);
            try self.leaves.put(index, leaf_hash);

            // Recompute path from leaf to root
            var current_hash = leaf_hash;
            var current_index = index;
            var level: u8 = @intCast(DEPTH);

            while (level > 0) {
                level -= 1;
                const sibling_index = current_index ^ 1;
                const sibling_hash = self.getNodeHash(level + 1, sibling_index);

                var concat: [HASH_LEN * 2]u8 = undefined;
                if (current_index & 1 == 0) {
                    @memcpy(concat[0..HASH_LEN], &current_hash);
                    @memcpy(concat[HASH_LEN..], &sibling_hash);
                } else {
                    @memcpy(concat[0..HASH_LEN], &sibling_hash);
                    @memcpy(concat[HASH_LEN..], &current_hash);
                }
                current_hash = H.hash(&concat);
                current_index >>= 1;

                try self.cache.put(.{ .level = level, .index = current_index }, current_hash);
            }
        }

        /// Get the hash of a node at (level, index), using defaults for empty subtrees.
        fn getNodeHash(self: Self, level: u8, index: u256) [HASH_LEN]u8 {
            if (level == DEPTH) {
                // Leaf level
                return self.leaves.get(index) orelse self.default_hashes[DEPTH];
            }
            return self.cache.get(.{ .level = level, .index = index }) orelse self.default_hashes[level];
        }

        /// Return the Merkle root.
        pub fn root(self: Self) [HASH_LEN]u8 {
            return self.getNodeHash(0, 0);
        }

        /// Generate a proof of inclusion (or non-membership) for `index`.
        /// Returns the sibling hashes along the path from leaf to root.
        pub fn prove(self: Self, index: u256, allocator: std.mem.Allocator) !MerkleProof {
            var siblings = try allocator.alloc([HASH_LEN]u8, DEPTH);
            var flags = try allocator.alloc(bool, DEPTH);
            errdefer allocator.free(siblings);
            errdefer allocator.free(flags);

            var current_index = index;
            for (0..DEPTH) |i| {
                const sibling_index = current_index ^ 1;
                siblings[i] = self.getNodeHash(@intCast(DEPTH - i), sibling_index);
                flags[i] = (current_index & 1 != 0); // true if current is right child
                current_index >>= 1;
            }

            return .{ .siblings = siblings, .is_left_sibling = flags };
        }

        /// Verify a proof against a root.
        pub fn verify(root_hash: [HASH_LEN]u8, index: u256, value: []const u8, proof: MerkleProof) bool {
            var current = H.hash(value);
            var current_index = index;

            for (0..DEPTH) |i| {
                var concat: [HASH_LEN * 2]u8 = undefined;
                if (proof.is_left_sibling[i]) {
                    @memcpy(concat[0..HASH_LEN], &proof.siblings[i]);
                    @memcpy(concat[HASH_LEN..], &current);
                } else {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &proof.siblings[i]);
                }
                current = H.hash(&concat);
                current_index >>= 1;
            }

            return std.mem.eql(u8, &current, &root_hash);
        }

        /// Verify non-membership: prove that `index` has the default value.
        pub fn verifyNonMembership(root_hash: [HASH_LEN]u8, index: u256, proof: MerkleProof) bool {
            return verify(root_hash, index, &[_]u8{}, proof);
        }
    };
}

const MerkleProof = @import("merkle_tree.zig").MerkleProof;
