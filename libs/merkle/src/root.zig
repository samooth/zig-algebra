//! zig-merkle: Merkle tree implementations for data commitments.
//!
//! Provides three complementary tree structures:
//! - **MerkleTree**: Classic binary tree for fixed-size datasets.
//! - **MMR**: Merkle Mountain Range for append-only logs.
//! - **SparseMerkleTree**: Perfect binary tree for sparse key-value sets.
//!
//! All trees support:
//! - Incremental building
//! - Inclusion proofs (MerkleProof)
//! - Proof serialization
//! - One-shot and streaming verification

const std = @import("std");

pub const merkle_tree = @import("merkle_tree.zig");
pub const mmr = @import("mmr.zig");
pub const sparse_merkle = @import("sparse_merkle.zig");

pub const MerkleTree = merkle_tree.MerkleTree;
pub const MerkleProof = merkle_tree.MerkleProof;
pub const MMR = mmr.MMR;
pub const SparseMerkleTree = sparse_merkle.SparseMerkleTree;

// Standalone verification function (matches zig-stark's core/merkle/merkle.zig interface)
pub const verify = merkle_tree.verifyPath;

// ============================================================================
// Tests
// ============================================================================

const Blake3 = @import("zig-hash").Blake3;

test "MerkleTree build and root" {
    const Tree = MerkleTree(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const leaves = [_][]const u8{ "a", "b", "c", "d" };
    var tree = try Tree.init(allocator, &leaves);
    defer tree.deinit();

    const root1 = tree.root();
    const root2 = tree.root();
    try std.testing.expectEqualSlices(u8, &root1, &root2);
}

test "MerkleTree prove and verify" {
    const Tree = MerkleTree(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const leaves = [_][]const u8{ "a", "b", "c", "d" };
    var tree = try Tree.init(allocator, &leaves);
    defer tree.deinit();

    const root = tree.root();

    for (0..leaves.len) |i| {
        const proof = try tree.prove(i, allocator);
        defer proof.deinit(allocator);
        try std.testing.expect(Tree.verify(root, i, leaves[i], proof));
    }
}

test "MerkleTree verify fails for wrong leaf" {
    const Tree = MerkleTree(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const leaves = [_][]const u8{ "a", "b", "c", "d" };
    var tree = try Tree.init(allocator, &leaves);
    defer tree.deinit();

    const root = tree.root();
    const proof = try tree.prove(0, allocator);
    defer proof.deinit(allocator);

    try std.testing.expect(!Tree.verify(root, 0, "wrong", proof));
}

test "MerkleTree proof serialization" {
    const Tree = MerkleTree(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const leaves = [_][]const u8{ "a", "b", "c", "d", "e" };
    var tree = try Tree.init(allocator, &leaves);
    defer tree.deinit();

    const proof = try tree.prove(2, allocator);
    defer proof.deinit(allocator);

    const serialized = try proof.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized = try MerkleProof.deserialize(serialized, allocator);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(proof.siblings.len, deserialized.siblings.len);
    for (0..proof.siblings.len) |i| {
        try std.testing.expectEqualSlices(u8, &proof.siblings[i], &deserialized.siblings[i]);
        try std.testing.expectEqual(proof.is_left_sibling[i], deserialized.is_left_sibling[i]);
    }
}

test "MerkleTree proof deserialization rejects oversized count" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidProof, MerkleProof.deserialize(&buf, std.testing.allocator));
}

test "MerkleTree with non-power-of-2 leaves" {
    const Tree = MerkleTree(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const leaves = [_][]const u8{ "a", "b", "c" };
    var tree = try Tree.init(allocator, &leaves);
    defer tree.deinit();

    const root = tree.root();
    for (0..leaves.len) |i| {
        const proof = try tree.prove(i, allocator);
        defer proof.deinit(allocator);
        try std.testing.expect(Tree.verify(root, i, leaves[i], proof));
    }
}

test "MMR append and root" {
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try M.init(allocator);
    defer m.deinit();

    try m.append("leaf1");
    const root1 = try m.root();

    try m.append("leaf2");
    const root2 = try m.root();

    try std.testing.expect(!std.mem.eql(u8, &root1, &root2));
}

test "MMR prove and verify" {
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try M.init(allocator);
    defer m.deinit();

    try m.append("a");
    try m.append("b");
    try m.append("c");
    try m.append("d");

    const root = try m.root();

    // Verify all leaves using standard Merkle proof verification
    for (0..4) |i| {
        const proof = try m.prove(i, allocator);
        defer proof.deinit(allocator);

        const leaf = switch (i) {
            0 => "a",
            1 => "b",
            2 => "c",
            3 => "d",
            else => unreachable,
        };
        var current = Blake3.hashBytes(leaf);
        for (0..proof.siblings.len) |j| {
            var concat: [64]u8 = undefined;
            if (proof.is_left_sibling[j]) {
                @memcpy(concat[0..32], &proof.siblings[j]);
                @memcpy(concat[32..], &current);
            } else {
                @memcpy(concat[0..32], &current);
                @memcpy(concat[32..], &proof.siblings[j]);
            }
            current = Blake3.hashBytes(&concat);
        }
        try std.testing.expectEqualSlices(u8, &root, &current);
    }
}

test "MMR proof matches root for a non-power-of-two leaf count" {
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try M.init(allocator);
    defer m.deinit();
    try m.append("a");
    try m.append("b");
    try m.append("c");

    const root = try m.root();
    const proof = try m.prove(1, allocator);
    defer proof.deinit(allocator);

    var current = Blake3.hashBytes("b");
    for (proof.siblings, proof.is_left_sibling) |sibling, is_left| {
        var concat: [64]u8 = undefined;
        if (is_left) {
            @memcpy(concat[0..32], &sibling);
            @memcpy(concat[32..], &current);
        } else {
            @memcpy(concat[0..32], &current);
            @memcpy(concat[32..], &sibling);
        }
        current = Blake3.hashBytes(&concat);
    }
    try std.testing.expectEqualSlices(u8, &root, &current);
}

test "MMR verify accepts its own proofs" {
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const leaves = [_][]const u8{ "a", "b", "c", "d", "e" };
    var m = try M.init(allocator);
    defer m.deinit();
    for (leaves) |leaf| try m.append(leaf);

    const root = try m.root();
    for (leaves, 0..) |leaf, i| {
        const proof = try m.prove(i, allocator);
        defer proof.deinit(allocator);
        try std.testing.expect(m.verify(root, i, leaf, proof));
        // Wrong leaf and out-of-range index must be rejected.
        try std.testing.expect(!m.verify(root, i, "not-a-leaf", proof));
        try std.testing.expect(!m.verify(root, leaves.len, leaf, proof));
    }
}

test "MMR verify accepts the single-leaf empty proof" {
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try M.init(allocator);
    defer m.deinit();
    try m.append("only");

    const root = try m.root();
    const proof = try m.prove(0, allocator);
    defer proof.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), proof.siblings.len);
    try std.testing.expect(m.verify(root, 0, "only", proof));
}

test "MMR verify rejects malformed proofs before indexing" {
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try M.init(allocator);
    defer m.deinit();
    try m.append("a");
    try m.append("b");
    try m.append("c");
    try m.append("d");

    const root = try m.root();
    const good = try m.prove(0, allocator);
    defer good.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), good.siblings.len);

    // Fewer flags than siblings: walking `siblings` and indexing
    // `is_left_sibling` used to read out of bounds.
    const short_flags = try allocator.dupe(bool, good.is_left_sibling[0..1]);
    defer allocator.free(short_flags);
    try std.testing.expect(!m.verify(root, 0, "a", .{
        .siblings = good.siblings,
        .is_left_sibling = short_flags,
    }));

    // More flags than siblings.
    const long_flags = try allocator.alloc(bool, good.siblings.len + 1);
    defer allocator.free(long_flags);
    @memset(long_flags, false);
    try std.testing.expect(!m.verify(root, 0, "a", .{
        .siblings = good.siblings,
        .is_left_sibling = long_flags,
    }));

    // Both halves empty (well-formed, but not a proof for this tree).
    const empty = [_][32]u8{};
    try std.testing.expect(!m.verify(root, 0, "a", .{
        .siblings = &empty,
        .is_left_sibling = &[_]bool{},
    }));

    // Depth that does not match the padded tree (4 leaves => depth 2).
    const one_level = good.siblings[0..1];
    const one_flag = good.is_left_sibling[0..1];
    try std.testing.expect(!m.verify(root, 0, "a", .{
        .siblings = one_level,
        .is_left_sibling = one_flag,
    }));

    // Sanity: the unmodified proof still verifies, so the rejections above
    // come from the shape checks and not from a broken root.
    try std.testing.expect(m.verify(root, 0, "a", good));
}

test "MMR verify does not index past the leaf index with a truncated flag array" {
    // Regression: sibling/flag arrays of different lengths, checked with a
    // proof whose sibling index is at the end of the loop.
    const M = MMR(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var m = try M.init(allocator);
    defer m.deinit();
    try m.append("a");
    try m.append("b");

    const root = try m.root();
    const good = try m.prove(1, allocator);
    defer good.deinit(allocator);

    const no_flags = try allocator.alloc(bool, good.siblings.len);
    defer allocator.free(no_flags);
    @memset(no_flags, false);
    try std.testing.expect(!m.verify(root, 1, "b", .{
        .siblings = good.siblings,
        .is_left_sibling = no_flags[0..0],
    }));
}

test "SparseMerkleTree update and prove" {
    const SMT = SparseMerkleTree(Blake3, 8);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var smt = try SMT.init(allocator);
    defer smt.deinit();

    try smt.update(5, "value_at_5");
    try smt.update(10, "value_at_10");
    try std.testing.expectError(error.IndexOutOfRange, smt.update(@as(u256, 1) << 8, "out_of_range"));

    const root = smt.root();

    const proof5 = try smt.prove(5, allocator);
    defer proof5.deinit(allocator);
    try std.testing.expect(SMT.verify(root, 5, "value_at_5", proof5));

    const proof10 = try smt.prove(10, allocator);
    defer proof10.deinit(allocator);
    try std.testing.expect(SMT.verify(root, 10, "value_at_10", proof10));
}

test "SparseMerkleTree supports depth 256" {
    const SMT = SparseMerkleTree(Blake3, 256);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var smt = try SMT.init(allocator);
    defer smt.deinit();
    try smt.update(42, "value");
    const root = smt.root();
    const proof = try smt.prove(42, allocator);
    defer proof.deinit(allocator);
    try std.testing.expect(SMT.verify(root, 42, "value", proof));
}

test "SparseMerkleTree non-membership" {
    const SMT = SparseMerkleTree(Blake3, 8);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var smt = try SMT.init(allocator);
    defer smt.deinit();

    try smt.update(5, "value_at_5");
    const root = smt.root();

    // Prove that index 7 is empty
    const proof7 = try smt.prove(7, allocator);
    defer proof7.deinit(allocator);
    try std.testing.expect(SMT.verifyNonMembership(root, 7, proof7));
}

test "SparseMerkleTree verify fails for wrong value" {
    const SMT = SparseMerkleTree(Blake3, 8);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var smt = try SMT.init(allocator);
    defer smt.deinit();

    try smt.update(5, "correct");
    const root = smt.root();

    const proof = try smt.prove(5, allocator);
    defer proof.deinit(allocator);

    try std.testing.expect(!SMT.verify(root, 5, "wrong", proof));
}

test "MerkleTree initFromHashes" {
    const Tree = MerkleTree(Blake3);
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hashes: [4][32]u8 = undefined;
    for (0..4) |i| {
        var buf: [32]u8 = undefined;
        @memset(&buf, @intCast(i));
        hashes[i] = Blake3.hashBytes(&buf);
    }

    var tree = try Tree.initFromHashes(allocator, &hashes);
    defer tree.deinit();

    const root = tree.root();
    const proof = try tree.prove(1, allocator);
    defer proof.deinit(allocator);

    try std.testing.expect(Tree.verifyHashed(root, 1, hashes[1], proof));
}
