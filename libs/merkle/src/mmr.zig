//! Merkle Mountain Range (MMR).
//!
//! An MMR is an append-only Merkle tree structure optimized for
//! incremental updates.  Instead of rebuilding the whole tree when
//! adding a leaf, it maintains a "bag of peaks" — the roots of perfect
//! binary subtrees that cover the current number of leaves.
//!
//! MMRs are used in:
//! - Blockchain light clients (e.g. Grin, Mina)
//! - Append-only logs with efficient inclusion proofs
//!
//! # Usage
//! ```zig
//! var mmr = try MMR(Blake3).init(allocator);
//! defer mmr.deinit();
//! try mmr.append("leaf1");
//! try mmr.append("leaf2");
//! const root = mmr.root();
//! const proof = try mmr.prove(0, allocator);
//! ```

const std = @import("std");

const HASH_LEN = 32;

/// MMR node index in a 1-based implicit binary tree.
/// Leaves are at positions 1, 3, 5, 7, ... (odd numbers).
/// Internal nodes are at even positions.
fn leftChild(pos: u64) u64 {
    const h = @ctz(pos + 1);
    return pos - (@as(u64, 1) << h);
}

fn rightChild(pos: u64) u64 {
    _ = @ctz(pos + 1); // used in other similar functions
    return pos - 1;
}

fn sibling(pos: u64) u64 {
    const h = @ctz(pos + 1);
    const dist = @as(u64, 1) << @intCast(h);
    if ((pos + 1) & (dist << 1) != 0) {
        return pos - dist; // sibling is left
    } else {
        return pos + dist; // sibling is right
    }
}

fn parent(pos: u64) u64 {
    const h = @ctz(pos + 1);
    const dist = @as(u64, 1) << @intCast(h);
    return pos + dist;
}

fn isRightSibling(pos: u64) bool {
    const h = @ctz(pos + 1);
    return (pos + 1) & (@as(u64, 1) << @intCast(h + 1)) == 0;
}

/// Merkle Mountain Range.
pub fn MMR(comptime H: type) type {
    return struct {
        const Self = @This();

        /// All node hashes indexed by their MMR position.
        nodes: std.AutoHashMap(u64, [HASH_LEN]u8),
        /// Number of leaves appended so far.
        leaf_count: u64,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .nodes = std.AutoHashMap(u64, [HASH_LEN]u8).init(allocator),
                .leaf_count = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
        }

        /// Append a new leaf.
        pub fn append(self: *Self, leaf: []const u8) !void {
            const leaf_pos = 2 * self.leaf_count; // MMR leaf positions: 0, 2, 4, ...
            const leaf_hash = H.hashBytes(leaf);
            try self.nodes.put(leaf_pos, leaf_hash);

            // Merge peaks while possible
            var pos = leaf_pos;
            while (pos > 0 and self.nodes.contains(pos - 1)) {
                const left = pos - 1;
                const left_hash = self.nodes.get(left).?;
                const right_hash = self.nodes.get(pos).?;
                var concat: [HASH_LEN * 2]u8 = undefined;
                @memcpy(concat[0..HASH_LEN], &left_hash);
                @memcpy(concat[HASH_LEN..], &right_hash);
                const parent_hash = H.hashBytes(&concat);
                const parent_pos = pos + 1;
                try self.nodes.put(parent_pos, parent_hash);
                pos = parent_pos;
            }

            self.leaf_count += 1;
        }

        /// Append a pre-hashed leaf.
        pub fn appendHash(self: *Self, leaf_hash: [HASH_LEN]u8) !void {
            const leaf_pos = 2 * self.leaf_count;
            try self.nodes.put(leaf_pos, leaf_hash);

            var pos = leaf_pos;
            while (pos > 0 and self.nodes.contains(pos - 1)) {
                const left = pos - 1;
                const left_hash = self.nodes.get(left).?;
                const right_hash = self.nodes.get(pos).?;
                var concat: [HASH_LEN * 2]u8 = undefined;
                @memcpy(concat[0..HASH_LEN], &left_hash);
                @memcpy(concat[HASH_LEN..], &right_hash);
                const parent_hash = H.hashBytes(&concat);
                const parent_pos = pos + 1;
                try self.nodes.put(parent_pos, parent_hash);
                pos = parent_pos;
            }

            self.leaf_count += 1;
        }

        /// Compute the bag-of-peaks root.
        pub fn root(self: Self) ![HASH_LEN]u8 {
            if (self.leaf_count == 0) return error.EmptyMMR;

            // Find all peaks
            var peaks = std.ArrayList(u64){};
            defer peaks.deinit(self.allocator);

            var pos: u64 = 2 * self.leaf_count - 1;
            while (pos > 0) {
                const height = @as(u7, @ctz(pos + 1));
                const size = (@as(u64, 1) << @intCast(height + 1)) - 1;
                if (pos + 1 >= size) {
                    try peaks.append(self.allocator, pos);
                    pos -= size;
                } else {
                    pos -= 1;
                }
            }

            // Hash peaks together from right to left
            var current = self.nodes.get(peaks.items[0]).?;
            for (1..peaks.items.len) |i| {
                const peak = self.nodes.get(peaks.items[i]).?;
                var concat: [HASH_LEN * 2]u8 = undefined;
                @memcpy(concat[0..HASH_LEN], &peak);
                @memcpy(concat[HASH_LEN..], &current);
                current = H.hashBytes(&concat);
            }
            return current;
        }

        /// Generate an inclusion proof for leaf at `index`.
        pub fn prove(self: Self, index: usize, allocator: std.mem.Allocator) !MerkleProof {
            if (index >= self.leaf_count) return error.IndexOutOfBounds;

            const leaf_pos: u64 = 2 * @as(u64, @intCast(index));
            var pos = leaf_pos;
            var siblings = std.ArrayList([HASH_LEN]u8){};
            var flags = std.ArrayList(bool){};
            defer siblings.deinit(allocator);
            defer flags.deinit(allocator);

            while (pos > 0) {
                const sib = sibling(pos);
                if (self.nodes.contains(sib)) {
                    try siblings.append(self.allocator, self.nodes.get(sib).?);
                    try flags.append(allocator, isRightSibling(pos));
                }
                pos = parent(pos);
            }

            const sib_slice = try allocator.dupe([HASH_LEN]u8, siblings.items);
            const flag_slice = try allocator.dupe(bool, flags.items);
            return .{ .siblings = sib_slice, .is_left_sibling = flag_slice };
        }
    };
}

/// MMR proof structure (reuses MerkleProof from merkle_tree.zig).
const MerkleProof = @import("merkle_tree.zig").MerkleProof;
