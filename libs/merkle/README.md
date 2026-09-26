# zig-merkle

Merkle tree implementations for data commitments. Three tree structures for different use cases: classic binary trees, append-only logs, and sparse key-value sets.

Library version: **0.1.2** (`libs/merkle/build.zig.zon`); the workspace version
lives in the root `build.zig.zon`.

## Features

- **MerkleTree** — classic binary Merkle tree with inclusion proofs
- **MMR (Merkle Mountain Range)** — append-only log structure for blockchains, with shape-checked `verify`
- **SparseMerkleTree** — perfect binary tree for sparse key-value sets
- **Inclusion/exclusion proofs** — prove membership or non-membership
- **Proof serialization** — compact binary proof format (`MerkleProof.serialize` / `MerkleProof.deserialize`)
- **Pre-hashed leaves** — `initFromHashes` skips the leaf hashing step
- **Standalone verification** — verify an opening without the tree, via `zm.verify` / `Tree.verifyPath`

Every tree is generic over the hash function `H`, which must expose a one-shot
`hashBytes([]const u8) [32]u8` returning a 32-byte digest. Among the
`zig-hash` types only `zh.Blake3` provides `hashBytes` — `zh.Keccak256`,
`zh.Sha3_256`, `zh.Blake2b256` and `zh.Blake2s256` only have
`init`/`update`/`finalize`, so they cannot be passed as `H` without a thin
adapter. There is no built-in default: `H` is a required comptime parameter.
`zig-field` separately ships a SHA-256 `MerkleTree(F)` over field elements.

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_merkle = .{
        .path = "../zig-algebra/libs/merkle",
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
const std = @import("std");
const zm = @import("zig-merkle");
const zh = @import("zig-hash");

const Tree = zm.MerkleTree(zh.Blake3);

// Build tree from leaves
const leaves = [_][]const u8{ "a", "b", "c", "d" };
var tree = try Tree.init(allocator, &leaves);
defer tree.deinit();

// Get root and proof
const root = tree.root();
const proof = try tree.prove(2, allocator); // proof for leaf at index 2
defer proof.deinit(allocator);

// Verify (returns bool, not an error union)
std.debug.assert(Tree.verify(root, 2, leaves[2], proof));
std.debug.assert(!Tree.verify(root, 2, "wrong", proof));

// Serialize / deserialize the proof
const serialized = try proof.serialize(allocator);
defer allocator.free(serialized);
const deserialized = try zm.MerkleProof.deserialize(serialized, allocator);
defer deserialized.deinit(allocator);

// Skip leaf hashing when you already have digests
var hashes: [4][32]u8 = undefined;
for (&hashes) |*h| h.* = zh.hashBlake3("leaf");
var hashed = try Tree.initFromHashes(allocator, &hashes);
defer hashed.deinit();
const hp = try hashed.prove(1, allocator);
defer hp.deinit(allocator);
std.debug.assert(Tree.verifyHashed(hashed.root(), 1, hashes[1], hp));

// Standalone path verification (works on a pre-hashed leaf + raw path)
std.debug.assert(zm.verify(
    zh.Blake3,
    root,
    2,
    zh.hashBlake3("c"),
    proof.siblings,
));
```

### Sparse Merkle Tree

Indexed by `u256` key, fixed `DEPTH` (max 256).

```zig
const SMT = zm.SparseMerkleTree(zh.Blake3, 8);
var smt = try SMT.init(allocator);
defer smt.deinit();

// Insert key-value pairs
try smt.update(5, "value_at_5");
try smt.update(10, "value_at_10");
const root = smt.root();

// Prove membership
const proof = try smt.prove(5, allocator);
defer proof.deinit(allocator);
std.debug.assert(SMT.verify(root, 5, "value_at_5", proof));

// Prove non-membership
const non_proof = try smt.prove(7, allocator);
defer non_proof.deinit(allocator);
std.debug.assert(SMT.verifyNonMembership(root, 7, non_proof));
```

### Merkle Mountain Range

```zig
const M = zm.MMR(zh.Blake3);
var mmr = try M.init(allocator);
defer mmr.deinit();

// Append leaves
try mmr.append("leaf1");
try mmr.append("leaf2");
try mmr.append("leaf3");
try mmr.append("leaf4");

// Get root (fallible) and proof
const root = try mmr.root();
const proof = try mmr.prove(0, allocator);
defer proof.deinit(allocator);

// `verify` is a method here, unlike the other two trees
std.debug.assert(mmr.verify(root, 0, "leaf1", proof));
```

`MMR.verify` is **fail-closed on a malformed proof** — it returns `false`
rather than indexing anything it has not validated:

- `siblings.len` must equal `is_left_sibling.len`. A `MerkleProof` whose two
  halves disagree used to be walked by `siblings.len` while indexing the flags,
  i.e. an out-of-bounds read (a trap in Debug/ReleaseSafe, silent undefined
  behaviour in `ReleaseFast`).
- The proof depth must match the zero-padded tree that `prove` / `root` build:
  `2^depth` is the smallest power of two covering `leaf_count`, so a well-formed
  proof carries exactly `depth` siblings, `index < 2^depth`, `leaf_count` does
  not exceed `2^depth`, and `depth` is the smallest such one. A truncated or
  over-long path is rejected.
- The leaf index must be below `leaf_count`.

## Running Tests

```bash
# From the monorepo root
zig build test

# Just this library (18 tests, all inline in src/root.zig)
cd libs/merkle && zig build test
```

## Design Notes

- `MerkleTree(H)` pads to the next power of two and pads the remaining leaves
  with `H.hashBytes(&.{})`
- All three trees hash internal nodes as `H.hashBytes(left || right)` over
  64-byte concatenations
- `SparseMerkleTree(H, DEPTH)` precomputes a chain of `DEPTH + 1` default
  hashes (`hash("")` at the leaf level, folded upwards) and falls back to them
  for any untouched subtree. Membership and non-membership share one proof
  shape: `verifyNonMembership` is `verify` against the empty value
- MMR is append-only (no deletions) — ideal for blockchain transaction logs.
  `MMR.root()` is an error union because it must collapse the peak list
- Proofs are `MerkleProof` structs carrying `siblings` plus
  `is_left_sibling` flags, so a verifier never needs the tree. The two slices
  are parallel arrays: `MMR.verify` requires equal lengths and a depth matching
  the padded tree before it hashes anything, so a malformed proof is rejected
  rather than walked out of bounds.
- Proof format is compact and serializable:
  `[u32 num_siblings][32*n sibling hashes][n direction flags]`

## License

MIT OR Apache-2.0
