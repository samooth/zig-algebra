//! zig-merkle example: demonstrates MerkleTree, MMR, and SparseMerkleTree.

const std = @import("std");
const merkle = @import("root.zig");
const Blake3 = @import("zig-hash").Blake3;

fn printHex(name: []const u8, bytes: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}: ", .{name});
    for (bytes) |b| try stdout.print("{x:0>2}", .{b});
    try stdout.print("\n", .{});
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== zig-merkle example ===\n\n", .{});

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- Classic Merkle Tree ---
    try stdout.print("--- Classic Merkle Tree ---\n", .{});
    const Tree = merkle.MerkleTree(Blake3);
    const leaves = [_][]const u8{ "tx1", "tx2", "tx3", "tx4" };
    var tree = try Tree.init(allocator, &leaves);
    defer tree.deinit();

    const root = tree.root();
    try printHex("Merkle root", &root);

    // Prove inclusion for tx3
    const proof = try tree.prove(2, allocator);
    defer proof.deinit(allocator);
    try stdout.print("Proof for tx3 has {} siblings\n", .{proof.siblings.len});
    const ok = Tree.verify(root, 2, "tx3", proof);
    try stdout.print("Verification: {}\n", .{ok});

    // Serialize proof
    const serialized = try proof.serialize(allocator);
    defer allocator.free(serialized);
    try stdout.print("Serialized proof size: {} bytes\n", .{serialized.len});

    // --- Merkle Mountain Range ---
    try stdout.print("\n--- Merkle Mountain Range ---\n", .{});
    const M = merkle.MMR(Blake3);
    var mmr = try M.init(allocator);
    defer mmr.deinit();

    try mmr.append("block1");
    try mmr.append("block2");
    try mmr.append("block3");

    const mmr_root = try mmr.root();
    try printHex("MMR root (3 leaves)", &mmr_root);

    try mmr.append("block4");
    const mmr_root2 = try mmr.root();
    try printHex("MMR root (4 leaves)", &mmr_root2);

    // Prove block1
    const mmr_proof = try mmr.prove(0, allocator);
    defer mmr_proof.deinit(allocator);
    try stdout.print("MMR proof for block1 has {} siblings\n", .{mmr_proof.siblings.len});

    // --- Sparse Merkle Tree ---
    try stdout.print("\n--- Sparse Merkle Tree ---\n", .{});
    const SMT = merkle.SparseMerkleTree(Blake3, 8);
    var smt = try SMT.init(allocator);
    defer smt.deinit();

    try smt.update(42, "account_A_balance");
    try smt.update(100, "account_B_balance");
    try smt.update(255, "account_C_balance");

    const smt_root = smt.root();
    try printHex("SMT root", &smt_root);

    // Prove account A
    const smt_proof = try smt.prove(42, allocator);
    defer smt_proof.deinit(allocator);
    const smt_ok = SMT.verify(smt_root, 42, "account_A_balance", smt_proof);
    try stdout.print("SMT verify account A: {}\n", .{smt_ok});

    // Non-membership for index 50
    const non_proof = try smt.prove(50, allocator);
    defer non_proof.deinit(allocator);
    const non_ok = SMT.verifyNonMembership(smt_root, 50, non_proof);
    try stdout.print("SMT non-membership for 50: {}\n", .{non_ok});

    try stdout.print("\nAll Merkle operations completed successfully!\n", .{});
}
