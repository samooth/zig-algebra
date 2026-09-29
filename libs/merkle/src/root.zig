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

// SHA3-256 is the same standard hash `hashlib.sha3_256` computes, so what this
// test pins is the tree, not the digest: the leaf hashing, the padding rule
// (an unused leaf is the hash of the empty byte string), the internal-node
// hashing, the proof order and the serialized proof layout. The oracle below
// is a from-scratch implementation in Python: it rebuilds every level of the
// tree and derives each proof by walking that structure.
const Sha3 = struct {
    pub fn hashBytes(input: []const u8) [32]u8 {
        return @import("zig-hash").hashSha3_256(input);
    }
};

test "MerkleTree roots, proofs and wire format match a from-scratch Python tree" {
    const Tree = MerkleTree(Sha3);
    const allocator = std.testing.allocator;

    const Proof = struct { index: usize, serialized: []const u8 };
    const Case = struct {
        leaves: []const []const u8,
        root: []const u8,
        proofs: []const Proof,
    };
    const cases = [_]Case{
        .{
            .leaves = &.{ "a", "b", "c", "d" },
            .root = "5267fec4a5327f9d287233f95213afa39d3aad2fee1fa1384b032b79fb3441e8",
            .proofs = &.{
                .{ .index = 0, .serialized = "02000000b039179a8a4ce2c252aa6f2f25798251c19b75fc1508d9d511a191e0487d64a719a84217e939015aaa26d5da6b9ca673eae0df32877593df597cd3e5157982b10000" },
                .{ .index = 1, .serialized = "0200000080084bf2fba02475726feb2cab2d8215eab14bc6bdd8bfb2c8151257032ecd8b19a84217e939015aaa26d5da6b9ca673eae0df32877593df597cd3e5157982b10100" },
                .{ .index = 2, .serialized = "020000004ce8765e720c576f6f5a34ca380b3de5f0912e6e3cc5355542c363891e54594b29df505440ebe180c00857e92b0694c56a33762b08944472492b0cbf6ec607e30001" },
                .{ .index = 3, .serialized = "02000000263ab762270d3b73d3e2cddf9acc893bb6bd41110347e5d5e4bd1d3c128ea90a29df505440ebe180c00857e92b0694c56a33762b08944472492b0cbf6ec607e30101" },
            },
        },
        .{
            .leaves = &.{ "x", "y", "z" },
            .root = "09e82249e463dc8531df6a868dc709f2e01ccfa34bbdacc0d0085720858bfbfb",
            .proofs = &.{
                .{ .index = 0, .serialized = "020000009d0f3db671f9fb22104b984763616732d383154a7a0dcdbb9ec17ab647b64961c078ad03345a356291e705d085869fe2541de899d9d584eff7b6674ad013a24b0000" },
                .{ .index = 1, .serialized = "02000000741efa311f97686956946758e0d95f70f11ff2da4f2feb7c54314f44134ac49fc078ad03345a356291e705d085869fe2541de899d9d584eff7b6674ad013a24b0100" },
                .{ .index = 2, .serialized = "02000000a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a1236b289e36e7661bd41ab615d73d263bbf4fd44e4625c967c09439e5b89543d0001" },
                .{ .index = 3, .serialized = "020000003b4aed1c401f71809c93e713f4b86fb6d56c5b668f4ad8b474cb8884756aac461236b289e36e7661bd41ab615d73d263bbf4fd44e4625c967c09439e5b89543d0101" },
            },
        },
        .{
            .leaves = &.{ "ledger-entry-0", "ledger-entry-1", "ledger-entry-2", "ledger-entry-3", "ledger-entry-4" },
            .root = "d5e76e1f354b63ad607b846dd84d103ea36820c5feb38a7a9bc7929042b2ac62",
            .proofs = &.{
                .{ .index = 0, .serialized = "03000000ec767399029e47c1c806fc89eee0743ceaa04f3c460599be85582cd72811548078ef2a57871b4565e8c2d4b118fdb7308704de8cf07927297ac6bb62d746d51440859d069fe5fee3bafbf606e9c54cf57b279242d8f48fb2ba06c7b6f0394043000000" },
                .{ .index = 1, .serialized = "030000002d19094749d474b4a74ede1b6d9212a1c285c188b6ceaf3d8ec1d972d9c815b178ef2a57871b4565e8c2d4b118fdb7308704de8cf07927297ac6bb62d746d51440859d069fe5fee3bafbf606e9c54cf57b279242d8f48fb2ba06c7b6f0394043010000" },
                .{ .index = 2, .serialized = "03000000d0983d4edaf1a3222c720a0c8160daa096b838b400b05bc1dab882a9c4dd8b0e58e0e66b56c5eab27fc3474266dbe1ff377cfb52365dbc1c2858ff25d2c4b7ba40859d069fe5fee3bafbf606e9c54cf57b279242d8f48fb2ba06c7b6f0394043000100" },
                .{ .index = 3, .serialized = "03000000938cc4900f262dcb6daf587386329ecd2c3f86cf48109a6e1a48f5efe0525c3d58e0e66b56c5eab27fc3474266dbe1ff377cfb52365dbc1c2858ff25d2c4b7ba40859d069fe5fee3bafbf606e9c54cf57b279242d8f48fb2ba06c7b6f0394043010100" },
                .{ .index = 4, .serialized = "03000000a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a634320e1828ffb11dac51a7adee6a739278fbe7f82879d764433fba0a5f9b25e863f070afc7c703a1ed386ea39aed3f9f50a2901dd464640928287dd34049519000001" },
                .{ .index = 5, .serialized = "03000000d0445af3f60f4b4bbeb373a24143fd5d229de71fd1905d7a1a18117640e25622634320e1828ffb11dac51a7adee6a739278fbe7f82879d764433fba0a5f9b25e863f070afc7c703a1ed386ea39aed3f9f50a2901dd464640928287dd34049519010001" },
            },
        },
        .{
            .leaves = &.{"only"},
            .root = "f700e2a653f95b2ca16ed7b524a2ae831c23d10d8acd24409379c5b49e288df6",
            .proofs = &.{
                .{ .index = 0, .serialized = "00000000" },
            },
        },
        .{
            .leaves = &.{ "leaf-00", "leaf-01", "leaf-02", "leaf-03", "leaf-04", "leaf-05", "leaf-06", "leaf-07" },
            .root = "a811b3417d88957e5b97288b30ba8b1b0ea5028685155a5409abbd08e419f34c",
            .proofs = &.{
                .{ .index = 0, .serialized = "03000000b6d506d650ac7c15df1e0bf9fb5876ceff6b7c57e8d548ccf8e75c5701ba40653f1cf5ae3d40aa612f48fc2543b7d11accfc9b9409bc6437a0e3e3373bfc16bab9be6e247ba6f4650c54e00fc553e689a6dadf647f4d474526f158e0a5b2d56c000000" },
                .{ .index = 1, .serialized = "030000003842e8232a7b967d085c6443224ee3cd9e9893b5a475a7647e7491732df38ee23f1cf5ae3d40aa612f48fc2543b7d11accfc9b9409bc6437a0e3e3373bfc16bab9be6e247ba6f4650c54e00fc553e689a6dadf647f4d474526f158e0a5b2d56c010000" },
                .{ .index = 2, .serialized = "03000000e18a51118dcdef04b420961f68f53dcab1a530196b5694cc1038a46963834a516c7cf0cdddf37d0ba114fc645b777b4dde227f880ab042b83832df5e1b263d51b9be6e247ba6f4650c54e00fc553e689a6dadf647f4d474526f158e0a5b2d56c000100" },
                .{ .index = 3, .serialized = "03000000129d3f6964f76336470d5fb6e572a029ef37b2c3746691491c2255366d8911106c7cf0cdddf37d0ba114fc645b777b4dde227f880ab042b83832df5e1b263d51b9be6e247ba6f4650c54e00fc553e689a6dadf647f4d474526f158e0a5b2d56c010100" },
                .{ .index = 4, .serialized = "03000000a227534a54d008bfb9d526f7372b2fc5c5d3ab34337b9ac0c8206b7010d626a5b757d73b96f6c9d6dd54b9d2e7417babd4c6ee6210b74a6bd5d0a1c916bb1b6979fa4ec108e02742f0e3ae6dcaedeb71aa56e99dea0a89f9a19c2472c9133835000001" },
                .{ .index = 5, .serialized = "030000003cd8ebf75157d42c09c3bac2ab5cc3c556b3d4b65321efd1f25800167e850fbcb757d73b96f6c9d6dd54b9d2e7417babd4c6ee6210b74a6bd5d0a1c916bb1b6979fa4ec108e02742f0e3ae6dcaedeb71aa56e99dea0a89f9a19c2472c9133835010001" },
                .{ .index = 6, .serialized = "03000000e90e8b784bdd555ccb6cead7356fa75322416bffbdb11521ba57f50ae129de24f8d71ee758dc7b182306326763f8da850760699f787a072b8d8dbbb50ed9174a79fa4ec108e02742f0e3ae6dcaedeb71aa56e99dea0a89f9a19c2472c9133835000101" },
                .{ .index = 7, .serialized = "03000000c2459328bd3abf7deadffb52ec4a3dc5aa6e41bf0c4389c27812ca5970d20ec2f8d71ee758dc7b182306326763f8da850760699f787a072b8d8dbbb50ed9174a79fa4ec108e02742f0e3ae6dcaedeb71aa56e99dea0a89f9a19c2472c9133835010101" },
            },
        },
    };

    for (cases) |c| {
        var tree = try Tree.init(allocator, c.leaves);
        defer tree.deinit();

        var expected_root: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_root, c.root);
        try std.testing.expectEqualSlices(u8, &expected_root, &tree.root());

        for (c.proofs) |p| {
            const oracle_bytes = try allocator.alloc(u8, p.serialized.len / 2);
            defer allocator.free(oracle_bytes);
            _ = try std.fmt.hexToBytes(oracle_bytes, p.serialized);

            // Our proof must serialize to the same bytes the oracle produced.
            const proof = try tree.prove(p.index, allocator);
            defer proof.deinit(allocator);
            const mine = try proof.serialize(allocator);
            defer allocator.free(mine);
            try std.testing.expectEqualSlices(u8, oracle_bytes, mine);

            // The oracle's proof must verify here. The leaf data of a padded
            // index is the empty string, which is what makes the padding rule
            // part of the pin rather than a silent convention.
            const leaf: []const u8 = if (p.index < c.leaves.len) c.leaves[p.index] else "";
            const oracle_proof = try MerkleProof.deserialize(oracle_bytes, allocator);
            defer oracle_proof.deinit(allocator);
            try std.testing.expect(Tree.verify(expected_root, p.index, leaf, oracle_proof));

            // And a proof with one flipped byte must not. The single-leaf
            // tree has an empty proof, so there is no payload byte to flip
            // there; that case checks the index guard instead.
            if (oracle_bytes.len > 4) {
                const tampered = try allocator.dupe(u8, oracle_bytes);
                defer allocator.free(tampered);
                tampered[tampered.len - 1] ^= 0x01;
                const bad = try MerkleProof.deserialize(tampered, allocator);
                defer bad.deinit(allocator);
                try std.testing.expect(!Tree.verify(expected_root, p.index, leaf, bad));
            } else {
                try std.testing.expect(!Tree.verify(expected_root, p.index + 1, leaf, oracle_proof));
            }
        }
    }
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
