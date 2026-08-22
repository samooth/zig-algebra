//! Classic binary Merkle tree.
//!
//! A Merkle tree is a binary tree of hashes where each leaf is the hash of a
//! data element and each internal node is the hash of the concatenation of its
//! two children.  The root hash commits to the entire dataset.
//!
//! # Usage
//! ```zig
//! var tree = try MerkleTree(Blake3).init(allocator, &leaves);
//! defer tree.deinit();
//! const root = tree.root();
//! const proof = try tree.prove(3, allocator);
//! defer proof.deinit(allocator);
//! const ok = MerkleTree(Blake3).verify(root, 3, &leaf, proof);
//! ```

const std = @import("std");
const hash = @import("zig-hash");

/// Hash output length in bytes (assumes all hash functions produce 32-byte digests).
const HASH_LEN = 32;

/// A Merkle proof: sibling hashes from leaf to root.
pub const MerkleProof = struct {
    /// Sibling hashes, from leaf level up to just below root.
    siblings: []const [HASH_LEN]u8,
    /// `true` means the sibling is on the left (current node is right child).
    is_left_sibling: []const bool,

    pub fn deinit(self: MerkleProof, allocator: std.mem.Allocator) void {
        allocator.free(self.siblings);
        allocator.free(self.is_left_sibling);
    }

    /// Serialize proof into a flat byte slice.
    /// Format: [4 bytes: num_siblings] [32 bytes * num_siblings: hashes] [num_siblings bytes: flags]
    pub fn serialize(self: MerkleProof, allocator: std.mem.Allocator) ![]u8 {
        const n = self.siblings.len;
        const size = 4 + n * HASH_LEN + n;
        const buf = try allocator.alloc(u8, size);
        std.mem.writeInt(u32, buf[0..4], @intCast(n), .little);
        for (0..n) |i| {
            @memcpy(buf[4 + i * HASH_LEN ..][0..HASH_LEN], &self.siblings[i]);
        }
        for (0..n) |i| {
            buf[4 + n * HASH_LEN + i] = if (self.is_left_sibling[i]) 1 else 0;
        }
        return buf;
    }

    /// Deserialize proof from a flat byte slice.
    pub fn deserialize(buf: []const u8, allocator: std.mem.Allocator) !MerkleProof {
        if (buf.len < 4) return error.InvalidProof;
        const n = std.mem.readInt(u32, buf[0..4], .little);
        const expected = 4 + n * HASH_LEN + n;
        if (buf.len != expected) return error.InvalidProof;

        const siblings = try allocator.alloc([HASH_LEN]u8, n);
        const flags = try allocator.alloc(bool, n);
        for (0..n) |i| {
            @memcpy(&siblings[i], buf[4 + i * HASH_LEN ..][0..HASH_LEN]);
            flags[i] = buf[4 + n * HASH_LEN + i] != 0;
        }
        return .{ .siblings = siblings, .is_left_sibling = flags };
    }
};

/// Classic binary Merkle tree backed by a contiguous array of nodes.
///
/// The tree is stored in array-heap order: nodes[1] = root,
/// nodes[2*i] = left child, nodes[2*i+1] = right child.
///
/// `H` must be a hash function type with:
/// - `hash(input: []const u8) [HASH_LEN]u8` (one-shot)
pub fn MerkleTree(comptime H: type) type {
    return struct {
        const Self = @This();

        /// All nodes, indexed from 1 (index 0 is unused).
        nodes: [][HASH_LEN]u8,
        /// Number of leaf nodes.
        leaf_count: usize,
        allocator: std.mem.Allocator,

        /// Build a Merkle tree from a slice of leaf data.
        /// Each leaf element is hashed individually.
        pub fn init(allocator: std.mem.Allocator, leaves: []const []const u8) !Self {
            if (leaves.len == 0) return error.EmptyLeaves;

            const leaf_count = std.math.ceilPowerOfTwo(usize, leaves.len) catch @as(usize, 0);
            const total_nodes = 2 * leaf_count; // nodes[0] unused

            const nodes = try allocator.alloc([HASH_LEN]u8, total_nodes);
            @memset(std.mem.sliceAsBytes(nodes), 0);

            // Hash leaves into the second half of the array
            const leaf_start = leaf_count;
            for (0..leaves.len) |i| {
                nodes[leaf_start + i] = H.hashBytes(leaves[i]);
            }
            // Pad remaining leaves with hash of empty string
            for (leaves.len..leaf_count) |i| {
                nodes[leaf_start + i] = H.hashBytes(&[_]u8{});
            }

            // Build internal nodes bottom-up
            var level_start = leaf_start;
            while (level_start > 1) {
                level_start >>= 1;
                for (0..level_start) |i| {
                    const left = nodes[2 * (level_start + i)];
                    const right = nodes[2 * (level_start + i) + 1];
                    var concat: [HASH_LEN * 2]u8 = undefined;
                    @memcpy(concat[0..HASH_LEN], &left);
                    @memcpy(concat[HASH_LEN..], &right);
                    nodes[level_start + i] = H.hashBytes(&concat);
                }
            }

            return .{
                .nodes = nodes,
                .leaf_count = leaf_count,
                .allocator = allocator,
            };
        }

        /// Build from pre-hashed leaves (each leaf is already a 32-byte hash).
        pub fn initFromHashes(allocator: std.mem.Allocator, leaf_hashes: []const [HASH_LEN]u8) !Self {
            if (leaf_hashes.len == 0) return error.EmptyLeaves;

            const leaf_count = try std.math.ceilPowerOfTwo(usize, leaf_hashes.len);
            const total_nodes = 2 * leaf_count;

            const nodes = try allocator.alloc([HASH_LEN]u8, total_nodes);
            @memset(std.mem.sliceAsBytes(nodes), 0);

            const leaf_start = leaf_count;
            for (0..leaf_hashes.len) |i| {
                nodes[leaf_start + i] = leaf_hashes[i];
            }
            for (leaf_hashes.len..leaf_count) |i| {
                nodes[leaf_start + i] = H.hashBytes(&[_]u8{});
            }

            var level_start = leaf_start;
            while (level_start > 1) {
                level_start >>= 1;
                for (0..level_start) |i| {
                    const left = nodes[2 * (level_start + i)];
                    const right = nodes[2 * (level_start + i) + 1];
                    var concat: [HASH_LEN * 2]u8 = undefined;
                    @memcpy(concat[0..HASH_LEN], &left);
                    @memcpy(concat[HASH_LEN..], &right);
                    nodes[level_start + i] = H.hashBytes(&concat);
                }
            }

            return .{
                .nodes = nodes,
                .leaf_count = leaf_count,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.nodes);
        }

        /// Return the Merkle root.
        pub fn root(self: Self) [HASH_LEN]u8 {
            return self.nodes[1];
        }

        /// Number of leaves (including padding).
        pub fn capacity(self: Self) usize {
            return self.leaf_count;
        }

        /// Number of actual data leaves (excluding padding).
        pub fn actualLeafCount(self: Self) usize {
            // We don't store this; caller should track it.
            // Return capacity as conservative estimate.
            return self.leaf_count;
        }

        /// Generate an inclusion proof for leaf at `index`.
        pub fn prove(self: Self, index: usize, allocator: std.mem.Allocator) !MerkleProof {
            if (index >= self.leaf_count) return error.IndexOutOfBounds;

            const depth = std.math.log2(self.leaf_count);
            const siblings = try allocator.alloc([HASH_LEN]u8, depth);
            const flags = try allocator.alloc(bool, depth);
            errdefer allocator.free(siblings);
            errdefer allocator.free(flags);

            var pos = self.leaf_count + index;
            var level: usize = 0;
            while (pos > 1) {
                const sibling = if (pos % 2 == 0) pos + 1 else pos - 1;
                siblings[level] = self.nodes[sibling];
                flags[level] = (pos % 2 != 0); // true if sibling is on the left
                pos >>= 1;
                level += 1;
            }

            return .{ .siblings = siblings, .is_left_sibling = flags };
        }

        /// Verify an inclusion proof.
        pub fn verify(root_hash: [HASH_LEN]u8, index: usize, leaf: []const u8, proof: MerkleProof) bool {
            var current = H.hashBytes(leaf);
            var pos = index;

            for (0..proof.siblings.len) |i| {
                var concat: [HASH_LEN * 2]u8 = undefined;
                if (proof.is_left_sibling[i]) {
                    @memcpy(concat[0..HASH_LEN], &proof.siblings[i]);
                    @memcpy(concat[HASH_LEN..], &current);
                } else {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &proof.siblings[i]);
                }
                current = H.hashBytes(&concat);
                pos >>= 1;
            }

            return std.mem.eql(u8, &current, &root_hash);
        }

        /// Verify using a pre-hashed leaf.
        pub fn verifyHashed(root_hash: [HASH_LEN]u8, index: usize, leaf_hash: [HASH_LEN]u8, proof: MerkleProof) bool {
            var current = leaf_hash;
            var pos = index;

            for (0..proof.siblings.len) |i| {
                var concat: [HASH_LEN * 2]u8 = undefined;
                if (proof.is_left_sibling[i]) {
                    @memcpy(concat[0..HASH_LEN], &proof.siblings[i]);
                    @memcpy(concat[HASH_LEN..], &current);
                } else {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &proof.siblings[i]);
                }
                current = H.hashBytes(&concat);
                pos >>= 1;
            }

            return std.mem.eql(u8, &current, &root_hash);
        }

        /// Standalone verification of a Merkle opening (matches zig-stark's core/merkle/merkle.zig interface).
        /// Takes a raw path slice instead of a MerkleProof struct.
        pub fn verifyPath(
            root_hash: [HASH_LEN]u8,
            index: usize,
            leaf: [HASH_LEN]u8,
            path: []const [HASH_LEN]u8,
        ) bool {
            var current = leaf;
            var idx = index;
            for (path) |sibling| {
                var concat: [HASH_LEN * 2]u8 = undefined;
                if (idx & 1 == 0) {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &sibling);
                } else {
                    @memcpy(concat[0..HASH_LEN], &sibling);
                    @memcpy(concat[HASH_LEN..], &current);
                }
                current = H.hashBytes(&concat);
                idx >>= 1;
            }
            return std.mem.eql(u8, &current, &root_hash);
        }
    };
}

/// Standalone verification of a Merkle opening (matches zig-stark's core/merkle/merkle.zig interface).
/// Takes a raw path slice instead of a MerkleProof struct.
pub fn verifyPath(
    comptime H: type,
    root_hash: [HASH_LEN]u8,
    index: usize,
    leaf: [HASH_LEN]u8,
    path: []const [HASH_LEN]u8,
) bool {
    var current = leaf;
    var idx = index;
    for (path) |sibling| {
        var concat: [HASH_LEN * 2]u8 = undefined;
        if (idx & 1 == 0) {
            @memcpy(concat[0..HASH_LEN], &current);
            @memcpy(concat[HASH_LEN..], &sibling);
        } else {
            @memcpy(concat[0..HASH_LEN], &sibling);
            @memcpy(concat[HASH_LEN..], &current);
        }
        current = H.hashBytes(&concat);
        idx >>= 1;
    }
    return std.mem.eql(u8, &current, &root_hash);
}
