const std = @import("std");
const zf = @import("zig-field");

test "MerkleTree basic build and verify" {
    const F = zf.M31;
    var leaves = [_]F{
        F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4),
        F.fromInt(5), F.fromInt(6), F.fromInt(7), F.fromInt(8),
    };

    var tree = try zf.MerkleTree(F).init(std.testing.allocator, &leaves);
    defer tree.deinit();

    const root = tree.rootHash();
    try std.testing.expect(root.len == 32);

    // Verify all leaves
    for (0..leaves.len) |i| {
        const proof = try tree.proof(std.testing.allocator, i);
        defer std.testing.allocator.free(proof);
        try std.testing.expect(zf.MerkleTree(F).verify(root, i, proof, leaves[i]));
    }
}

test "MerkleTree verify fails with wrong leaf" {
    const F = zf.M31;
    var leaves = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3), F.fromInt(4) };

    var tree = try zf.MerkleTree(F).init(std.testing.allocator, &leaves);
    defer tree.deinit();

    const root = tree.rootHash();
    const proof = try tree.proof(std.testing.allocator, 0);
    defer std.testing.allocator.free(proof);

    const wrong_leaf = F.fromInt(999);
    try std.testing.expect(!zf.MerkleTree(F).verify(root, 0, proof, wrong_leaf));
}

test "MerkleTree batch verify" {
    const F = zf.M31;
    var leaves = [_]F{
        F.fromInt(10), F.fromInt(20), F.fromInt(30), F.fromInt(40),
        F.fromInt(50), F.fromInt(60), F.fromInt(70), F.fromInt(80),
    };

    var tree = try zf.MerkleTree(F).init(std.testing.allocator, &leaves);
    defer tree.deinit();

    const root = tree.rootHash();

    var indices = [_]usize{ 0, 3, 7 };
    var proof_slices: [3][]const [32]u8 = undefined;
    var selected_leaves: [3]F = undefined;

    for (0..3) |i| {
        proof_slices[i] = try tree.proof(std.testing.allocator, indices[i]);
        selected_leaves[i] = leaves[indices[i]];
    }
    defer for (proof_slices) |p| std.testing.allocator.free(p);

    try std.testing.expect(zf.MerkleTree(F).verifyBatch(root, &indices, &proof_slices, &selected_leaves));
}

test "MerkleTree with non-power-of-two leaves" {
    const F = zf.M31;
    var leaves = [_]F{ F.fromInt(1), F.fromInt(2), F.fromInt(3) };

    var tree = try zf.MerkleTree(F).init(std.testing.allocator, &leaves);
    defer tree.deinit();

    const root = tree.rootHash();
    for (0..leaves.len) |i| {
        const proof = try tree.proof(std.testing.allocator, i);
        defer std.testing.allocator.free(proof);
        try std.testing.expect(zf.MerkleTree(F).verify(root, i, proof, leaves[i]));
    }
}
