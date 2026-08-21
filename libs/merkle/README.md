# zig-merkle

Merkle tree implementations for data commitments. Three tree structures for different use cases: classic binary trees, append-only logs, and sparse key-value sets.

## Features

- **MerkleTree** — classic binary Merkle tree with inclusion proofs
- **MMR (Merkle Mountain Range)** — append-only log structure for blockchains
- **SparseMerkleTree** — perfect binary tree for sparse key-value sets
- **Inclusion/exclusion proofs** — prove membership or non-membership
- **Proof serialization** — compact binary proof format
- **Incremental building** — add leaves one at a time
- **One-shot and streaming verification**

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_merkle = .{
        .path = "path/to/zig-algebra-core/zig-merkle",
    },
},
```

Then in your `build.zig`:

```zig
const zm = b.dependency("zig_merkle", .{});
exe.root_module.addImport("zig-merkle", zm.module("zig-merkle"));
```

## Quick Start

### Merkle Tree

```zig
const zm = @import("zig-merkle");

// Build tree from leaves
const leaves = [_][]const u8{ "a", "b", "c", "d" };
var tree = try zm.MerkleTree.init(allocator, &leaves);
defer tree.deinit();

// Get root and proof
const root = tree.rootHash();
const proof = try tree.proof(allocator, 2); // proof for leaf at index 2

// Verify
try zm.MerkleTree.verify(root, 2, proof, "c");
```

### Sparse Merkle Tree

```zig
var smt = try zm.SparseMerkleTree.init(allocator);
defer smt.deinit();

// Insert key-value pairs
try smt.insert(key1, value1);
try smt.insert(key2, value2);

// Prove membership
const proof = try smt.prove(allocator, key1);
try zm.SparseMerkleTree.verify(smt.root(), key1, value1, proof);

// Prove non-membership
const non_proof = try smt.proveNonMembership(allocator, key3);
```

### Merkle Mountain Range

```zig
var mmr = try zm.MMR.init(allocator);
defer mmr.deinit();

// Append leaves
try mmr.append(leaf1);
try mmr.append(leaf2);

// Get root and proof
const root = mmr.root();
const proof = try mmr.prove(allocator, 0);
```

## Running Tests

```bash
zig build test
```

## Design Notes

- MerkleTree uses SHA-256 as the default hash function (configurable)
- SparseMerkleTree uses empty-node hashing for default values
- MMR is append-only (no deletions) — ideal for blockchain transaction logs
- All trees support incremental building and proof generation without storing the full tree
- Proof format is compact and serializable

## License

MIT OR Apache-2.0
