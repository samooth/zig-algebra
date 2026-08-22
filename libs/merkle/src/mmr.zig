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

/// Peak entry: position and height
const Peak = struct {
    pos: u64,
    height: u7,
};

/// Merkle Mountain Range.
pub fn MMR(comptime H: type) type {
    return struct {
        const Self = @This();

        /// All node hashes indexed by their MMR position.
        nodes: std.AutoHashMap(u64, [HASH_LEN]u8),
        /// Peak positions with their heights
        peaks: std.ArrayList(Peak),
        /// Number of leaves appended so far.
        leaf_count: u64,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .nodes = std.AutoHashMap(u64, [HASH_LEN]u8).init(allocator),
                .peaks = std.ArrayList(Peak){},
                .leaf_count = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
            self.peaks.deinit(self.allocator);
        }

        /// Append a new leaf.
        pub fn append(self: *Self, leaf: []const u8) !void {
            const leaf_hash = H.hashBytes(leaf);
            try self.appendHash(leaf_hash);
        }

        /// Append a pre-hashed leaf.
        pub fn appendHash(self: *Self, leaf_hash: [HASH_LEN]u8) !void {
            // Standard MMR bag-of-peaks algorithm with explicit peak tracking
            // New leaf at position 2 * leaf_count, height 0
            const leaf_pos = 2 * self.leaf_count;
            try self.nodes.put(leaf_pos, leaf_hash);
            try self.peaks.append(self.allocator, .{ .pos = leaf_pos, .height = 0 });

            // Merge peaks while the last two have the same height
            while (self.peaks.items.len >= 2) {
                const last_idx = self.peaks.items.len - 1;
                const right_peak = self.peaks.items[last_idx];
                const left_peak = self.peaks.items[last_idx - 1];

                if (right_peak.height != left_peak.height) break;

                // Remove the two peaks
                _ = self.peaks.pop();
                _ = self.peaks.pop();

                // Create parent at position after right_peak
                // Parent position = right_peak.pos + 1
                const left_hash = self.nodes.get(left_peak.pos).?;
                const right_hash = self.nodes.get(right_peak.pos).?;
                var concat: [HASH_LEN * 2]u8 = undefined;
                @memcpy(concat[0..HASH_LEN], &left_hash);
                @memcpy(concat[HASH_LEN..], &right_hash);
                const parent_hash = H.hashBytes(&concat);
                const parent_pos = right_peak.pos + 1;
                try self.nodes.put(parent_pos, parent_hash);

                // Add new peak with height + 1
                try self.peaks.append(self.allocator, .{
                    .pos = parent_pos,
                    .height = left_peak.height + 1,
                });
            }

            self.leaf_count += 1;
        }

        /// Compute the bag-of-peaks root.
        pub fn root(self: Self) ![HASH_LEN]u8 {
            if (self.peaks.items.len == 0) return error.EmptyMMR;

            // Hash peaks from right to left (newest to oldest)
            var current = self.nodes.get(self.peaks.items[self.peaks.items.len - 1].pos).?;
            for (0..self.peaks.items.len - 1) |i| {
                const peak_idx = self.peaks.items.len - 2 - i;
                const peak = self.nodes.get(self.peaks.items[peak_idx].pos).?;
                var concat: [HASH_LEN * 2]u8 = undefined;
                @memcpy(concat[0..HASH_LEN], &peak);
                @memcpy(concat[HASH_LEN..], &current);
                current = H.hashBytes(&concat);
            }
            return current;
        }

        /// Generate an inclusion proof for leaf at `index`.
        pub fn prove(self: Self, index: usize, allocator: std.mem.Allocator) !MerkleProof {
            if (index >= @as(usize, @intCast(self.leaf_count))) return error.IndexOutOfBounds;

            const leaf_pos: u64 = 2 * @as(u64, @intCast(index));

            // Walk up from leaf to root, collecting siblings
            var siblings = std.ArrayList([HASH_LEN]u8){};
            var flags = std.ArrayList(bool){};
            defer siblings.deinit(allocator);
            defer flags.deinit(allocator);

            var pos = leaf_pos;
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

        /// Verify an inclusion proof for leaf at `index`.
        pub fn verify(self: Self, root_hash: [HASH_LEN]u8, index: usize, leaf: []const u8, proof: MerkleProof) bool {
            if (index >= @as(usize, @intCast(self.leaf_count))) return false;

            const leaf_hash = H.hashBytes(leaf);
            var current = leaf_hash;

            for (0..proof.siblings.len) |j| {
                var concat: [HASH_LEN * 2]u8 = undefined;
                if (proof.is_left_sibling[j]) {
                    @memcpy(concat[0..HASH_LEN], &proof.siblings[j]);
                    @memcpy(concat[HASH_LEN..], &current);
                } else {
                    @memcpy(concat[0..HASH_LEN], &current);
                    @memcpy(concat[HASH_LEN..], &proof.siblings[j]);
                }
                current = H.hashBytes(&concat);
            }

            return std.mem.eql(u8, &current, &root_hash);
        }
    };
}

/// MMR proof structure (reuses MerkleProof from merkle_tree.zig).
const MerkleProof = @import("merkle_tree.zig").MerkleProof;