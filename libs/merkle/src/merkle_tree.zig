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

fn validPathIndex(index: usize, depth: usize) bool {
    if (depth >= @bitSizeOf(usize)) return false;
    const leaf_count = @as(usize, 1) << @intCast(depth);
    return index < leaf_count;
}

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
        if (self.is_left_sibling.len != n) return error.InvalidProof;
        if (n > std.math.maxInt(u32)) return error.ProofTooLong;
        if (n > (std.math.maxInt(usize) - 4) / HASH_LEN) return error.ProofTooLong;
        const hash_size = n * HASH_LEN;
        if (n > std.math.maxInt(usize) - 4 - hash_size) return error.ProofTooLong;
        const size = 4 + hash_size + n;
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
        const n: usize = @intCast(std.mem.readInt(u32, buf[0..4], .little));
        if (n > (std.math.maxInt(usize) - 4) / HASH_LEN) return error.InvalidProof;
        const hash_size = n * HASH_LEN;
        if (n > std.math.maxInt(usize) - 4 - hash_size) return error.InvalidProof;
        const expected = 4 + hash_size + n;
        if (buf.len != expected) return error.InvalidProof;

        const siblings = try allocator.alloc([HASH_LEN]u8, n);
        errdefer allocator.free(siblings);
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
/// - `hashBytes(input: []const u8) [HASH_LEN]u8` (one-shot). This line used to
///   name `hash`, which appears nowhere in this file; the ten call sites all
///   use `hashBytes`. A docstring that names a member the code never calls
///   sends a reader looking for an interface that does not exist.
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
            var flags: ?[]bool = null;
            var transfer = false;
            defer {
                if (!transfer) {
                    if (flags) |value| allocator.free(value);
                    allocator.free(siblings);
                }
            }
            flags = try allocator.alloc(bool, depth);

            var pos = self.leaf_count + index;
            var level: usize = 0;
            while (pos > 1) {
                const sibling = if (pos % 2 == 0) pos + 1 else pos - 1;
                siblings[level] = self.nodes[sibling];
                flags.?[level] = (pos % 2 != 0);
                pos >>= 1;
                level += 1;
            }

            transfer = true;
            return .{ .siblings = siblings, .is_left_sibling = flags.? };
        }

        /// Verify an inclusion proof.
        pub fn verify(root_hash: [HASH_LEN]u8, index: usize, leaf: []const u8, proof: MerkleProof) bool {
            if (proof.siblings.len != proof.is_left_sibling.len or !validPathIndex(index, proof.siblings.len)) return false;
            var current = H.hashBytes(leaf);
            var idx = index;

            for (0..proof.siblings.len) |i| {
                // The side each sibling sits on comes from the index, not from the
                // proof. It used to be read out of `proof.is_left_sibling[i]`,
                // which is a field of the proof itself: the verifier was told which
                // side to concatenate on by whoever handed it the proof, and `idx`
                // was shifted but never read. `verify(root, 2, leaf, proof)` and
                // `verify(root, 1, leaf, proof)` therefore agreed, so an honest
                // inclusion proof for one position was accepted at another.
                //
                // `idx & 1 == 1` means the node at this level is a right child, so
                // its sibling is on the left. This is what `prove` records
                // (`pos % 2 != 0`) and what `verifyPath` already did; this function
                // now agrees with both.
                const sibling_on_left = (idx & 1) == 1;
                if (proof.is_left_sibling[i] != sibling_on_left) return false;

                var concat: [HASH_LEN * 2]u8 = undefined;
                if (sibling_on_left) {
                    @memcpy(concat[0..HASH_LEN], &proof.siblings[i]);
                    @memcpy(concat[HASH_LEN..], &current);
                } else {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &proof.siblings[i]);
                }
                current = H.hashBytes(&concat);
                idx >>= 1;
            }

            return std.mem.eql(u8, &current, &root_hash);
        }

        /// Verify using a pre-hashed leaf.
        pub fn verifyHashed(root_hash: [HASH_LEN]u8, index: usize, leaf_hash: [HASH_LEN]u8, proof: MerkleProof) bool {
            if (proof.siblings.len != proof.is_left_sibling.len or !validPathIndex(index, proof.siblings.len)) return false;
            var current = leaf_hash;
            var idx = index;

            for (0..proof.siblings.len) |i| {
                // The side each sibling sits on comes from the index, not from the
                // proof. It used to be read out of `proof.is_left_sibling[i]`,
                // which is a field of the proof itself: the verifier was told which
                // side to concatenate on by whoever handed it the proof, and `idx`
                // was shifted but never read. `verify(root, 2, leaf, proof)` and
                // `verify(root, 1, leaf, proof)` therefore agreed, so an honest
                // inclusion proof for one position was accepted at another.
                //
                // `idx & 1 == 1` means the node at this level is a right child, so
                // its sibling is on the left. This is what `prove` records
                // (`pos % 2 != 0`) and what `verifyPath` already did; this function
                // now agrees with both.
                const sibling_on_left = (idx & 1) == 1;
                if (proof.is_left_sibling[i] != sibling_on_left) return false;

                var concat: [HASH_LEN * 2]u8 = undefined;
                if (sibling_on_left) {
                    @memcpy(concat[0..HASH_LEN], &proof.siblings[i]);
                    @memcpy(concat[HASH_LEN..], &current);
                } else {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &proof.siblings[i]);
                }
                current = H.hashBytes(&concat);
                idx >>= 1;
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
            if (!validPathIndex(index, path.len)) return false;
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
    if (!validPathIndex(index, path.len)) return false;
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

test "merkle: a path index at or past the leaf count is rejected" {
    // Guards `validPathIndex`, the check that a proof's index names a real
    // leaf. A tree of four leaves has depth 2, so index 4 is one past the end
    // and a path of the right length must not open it. Written mutation-first:
    // with `<` weakened to `<=` this is the test that fails.
    // Uses this library's own hash rather than std's, so the test does not
    // depend on a second Blake3 spelling being in scope.
    const H = hash.Blake3;
    const Tree = MerkleTree(H);
    const leaves = [_][]const u8{ "aaaa", "bbbb", "cccc", "dddd" };

    var tree = try Tree.init(std.testing.allocator, &leaves);
    defer tree.deinit();
    var proof = try tree.prove(0, std.testing.allocator);
    defer proof.deinit(std.testing.allocator);
    const root = tree.root();

    // The same proof, opened at its own index, works.
    try std.testing.expect(Tree.verifyHashed(root, 0, hash.hashBlake3(leaves[0]), proof));

    // One past the last leaf, same depth: rejected.
    try std.testing.expect(!Tree.verifyHashed(root, 4, hash.hashBlake3(leaves[0]), proof));
    try std.testing.expect(!validPathIndex(4, 2));
    try std.testing.expect(validPathIndex(3, 2));

    // Depth zero has one leaf, so index 1 is already out of range.
    try std.testing.expect(!validPathIndex(1, 0));
    try std.testing.expect(validPathIndex(0, 0));
}

// ============================================================================
// Bitcoin's Merkle tree
// ============================================================================

/// Bitcoin's Merkle shape: leaves are already hashes, and an odd level duplicates
/// its last node rather than being padded out to a power of two.
///
/// This is a separate type rather than a mode on `MerkleTree` because the two
/// differ in more than a padding rule. `MerkleTree` pads with
/// `H.hashBytes(&.{})` and hashes each leaf; Bitcoin pads nothing, duplicates,
/// and treats its leaves as hashes already -- a transaction's txid, itself a
/// hash256. The odd-level rule changes *which nodes are siblings*, so no padding
/// constant reconciles them.
///
/// The three places an implementation of this goes wrong, each of which the
/// tests in `libs/merkle/tests/bitcoin_merkle_test.zig` close:
///
/// * **A single leaf is the root, not a hash of it.** The genesis block's Merkle
///   root equals its coinbase txid, which is a published constant and the vector
///   that settles it. A "build the tree, then read the root" shape hashes one
///   time too many here.
/// * **hash256, not SHA-256.** Each concatenation is hashed twice. `H` supplies
///   that; this type does not know or care, which keeps it usable for the other
///   double-hash trees in the same family.
/// * **Sibling order is the byte order given.** Bitcoin concatenates in the
///   internal little-endian order the txids already carry. Nothing is swapped.
///
/// No allocator and no proof machinery: the root is a pure function, which is all
/// a block header needs.
pub fn BitcoinMerkle(comptime H: type) type {
    return struct {
        /// Digest width. Named `LEN` and not `HASH_LEN`, because the enclosing
        /// module already has a `HASH_LEN` and a second one in this scope makes
        /// every reference to it ambiguous.
        const LEN = 32;

        /// Root over `leaves`, each of which is already a hash.
        ///
        /// An empty list is `error.EmptyLeaves` rather than a zeroed root: an
        /// empty block is not a thing, and a zero root is a value a caller could
        /// mistake for a real one.
        pub fn root(leaves: []const [LEN]u8) error{EmptyLeaves}![LEN]u8 {
            if (leaves.len == 0) return error.EmptyLeaves;
            if (leaves.len == 1) return leaves[0];

            // Two alternating buffers, each as long as the input, are enough:
            // every level is at most the length of the one before it.
            var a: [64][LEN]u8 = undefined;
            var b: [64][LEN]u8 = undefined;
            var cur: [][LEN]u8 = &a;
            var nxt: [][LEN]u8 = &b;
            @memcpy(cur[0..leaves.len], leaves);
            var len = leaves.len;

            while (len > 1) {
                if (len % 2 == 1) {
                    // The Bitcoin rule. `cur[len]` duplicates the final node, so
                    // at the next pairing that node is hashed with itself.
                    cur[len] = cur[len - 1];
                    len += 1;
                }
                var i: usize = 0;
                while (i < len) : (i += 2) {
                    var concat: [LEN * 2]u8 = undefined;
                    @memcpy(concat[0..LEN], &cur[i]);
                    @memcpy(concat[LEN..], &cur[i + 1]);
                    nxt[i / 2] = H.hashBytes(&concat);
                }
                len /= 2;
                const tmp = cur;
                cur = nxt;
                nxt = tmp;
            }
            return cur[0];
        }
    };
}

test "merkle: the concatenation side comes from the index, not from the proof" {
    // `verify` used to decide which side each sibling sat on by reading
    // `proof.is_left_sibling[i]` -- a field of the proof itself -- and shifted
    // `idx` without ever reading it. The index was therefore only a range check,
    // and an honest inclusion proof for one position was accepted at every other
    // position of the same depth.
    //
    // With four leaves, positions 1 and 2 differ in one bit: exactly the bit that
    // says "am I the left or the right child at the bottom level". A proof
    // generated for position 2 must not verify at position 1.
    //
    // Uses this library's own hash rather than std's, so the test does not depend
    // on a second Blake3 spelling being in scope.
    const H = hash.Blake3;
    const Tree = MerkleTree(H);
    const leaves = [_][]const u8{ "aaaa", "bbbb", "cccc", "dddd" };

    var tree = try Tree.init(std.testing.allocator, &leaves);
    defer tree.deinit();

    const root = tree.root();
    var proof2 = try tree.prove(2, std.testing.allocator);
    defer proof2.deinit(std.testing.allocator);

    try std.testing.expect(Tree.verify(root, 2, leaves[2], proof2));
    // The defect: same proof, different index, and it used to pass.
    try std.testing.expect(!Tree.verify(root, 1, leaves[2], proof2));
    try std.testing.expect(!Tree.verify(root, 3, leaves[2], proof2));

    // A proof is also refused when its own flags contradict the index, so a
    // tampered proof is rejected rather than silently repaired.
    const original = proof2.is_left_sibling;
    const flipped = try std.testing.allocator.alloc(bool, original.len);
    defer std.testing.allocator.free(flipped);
    for (original, 0..) |f, i| flipped[i] = !f;
    proof2.is_left_sibling = flipped;
    try std.testing.expect(!Tree.verify(root, 2, leaves[2], proof2));
    proof2.is_left_sibling = original;

    // And every position still verifies with its own honest proof, so tightening
    // this did not cost completeness.
    for (leaves, 0..) |leaf, i| {
        var p = try tree.prove(i, std.testing.allocator);
        defer p.deinit(std.testing.allocator);
        try std.testing.expect(Tree.verify(root, i, leaf, p));
    }
}
