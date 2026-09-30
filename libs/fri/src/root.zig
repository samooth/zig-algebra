//! zig-fri v2: Fast Reed-Solomon Interactive Oracle Proof of Proximity.
//!
//! FRI lets a prover convince a verifier that a committed function is
//! close to a low-degree polynomial, without revealing it. Core of STARKs.
//!
//! # Protocol (canonical FRI over a 2-adic multiplicative subgroup)
//!
//! The committed evaluations live on the order-`n = 2^k` subgroup
//! `H_k = <g^(2^(adicity-k))>` of the base field (natural exponent order:
//! `domain[i] = g_k^i`). Antipodal pairs `x / -x` sit at positions
//! `(j, j + n/2)`, and squaring maps `H_k -> H_{k-1}` two-to-one — exactly
//! the FRI fold structure. Requires a field with `two_adicity >= k` (Goldilocks:
//! 32; M31's base field has two-adicity 1).
//!
//! **M31 is usable, over the torus.** The sentence that used to stand here --
//! "M31 has two-adicity 1 and cannot be used here" -- was true of the base
//! field and false of the package. `proveOn`/`verifyOn` take the domain as a
//! parameter, and `torus.TorusDomain` supplies one built from the norm-1 torus
//! of `F[p^2]`, whose order is `p + 1` rather than `p - 1`. For a Mersenne prime
//! that is the whole ballgame: `2^31 - 1 + 1 = 2^31`, so a field whose base
//! two-adicity is 1 gets a domain of size `2^31` from the torus. M61 gets 61 the
//! same way. Two qualifications, because the obvious summary is wrong in both
//! directions: the torus is *not* an improvement in general -- for Goldilocks
//! `p + 1` has 2-adicity 1 while the base field has 32, which is why FRI keeps
//! using the multiplicative subgroup there -- and for `F[p^2]` the extension's
//! own `two_adicity` (`v2(p-1) + v2(p+1)`, 32 for M31) is also large enough, so
//! the torus is the domain you want for its structure, not the only one that
//! runs.
//!
//! ## Commit phase (Fiat-Shamir made non-interactive)
//!
//! ```text
//! layer[0] = input evaluations (length n, natural domain order)
//! for i in 0..R:
//!     root[i] = merkle( leaves[j] = H(f_i[j], f_i[j + n_i/2]) )
//!     absorb(root[i]); alpha[i] = challenge()
//!     f_{i+1}[j] = (f_i[j] + f_i[j+n_i/2])/2
//!               + alpha[i] * (f_i[j] - f_i[j+n_i/2]) / (2 * x_j)
//! residual = f_R interpolated to COEFFICIENTS, truncated to the
//!            degree bound d (the degree anchor)
//! absorb(residual coefficients...)
//! ```
//!
//! The residual is the degree anchor: the final domain has size
//! `2^log_final > d` (rate < 1), so a degree-`>= d` imposter disagrees
//! with the truncated residual's evaluations almost everywhere.
//!
//! ## Query phase
//!
//! For each of `num_queries` random starting positions: walk down the
//! antipodal-pair chain, verifying Merkle inclusion and — with exact
//! positional equality, no even/odd slack — that each fold lands on the
//! next layer's value, ending at the residual's evaluation on the final
//! domain.
//!
//! # Soundness
//!
//! Textbook FRI: each query tests the codeword distance of the committed
//! layers; the residual pins the degree. With blowup `B = 2^log_final / d`
//! and `q` queries the rejection of far-from-low-degree data is
//! overwhelming (per-query pass ≈ 1/B for maximally-far data). See
//! SECURITY.md for the v1 failure this v2 replaces.
//!
//! # Requirements on `F`
//!
//! Any `zig-field` `Field(modulus)` with `two_adicity >= log_domain`:
//! exposes `add/sub/mul/div/inv/pow`, `primitiveRootOfUnity`,
//! `fromInt`, `random`, `toBytes`. Goldilocks is the reference field.

const std = @import("std");

const zfield = @import("zig-field");
const Blake3 = std.crypto.hash.Blake3;
const HASH_LEN = 32;

pub const FriError = error{
    InvalidParameters,
    InvalidProof,
    /// `Domain.init` was asked for a domain larger than the field's
    /// two-adicity (the shift `two_adicity - log_n` would underflow).
    DomainTooLarge,
    /// `F.primitiveRootOfUnity` was asked for an order above the field's
    /// two-adicity.
    OrderTooLarge,
    OutOfMemory,
};

/// Blake3 adapter for zig-merkle's `hashBytes` interface.
const Blake3Hash = struct {
    pub fn hashBytes(input: []const u8) [HASH_LEN]u8 {
        var out: [HASH_LEN]u8 = undefined;
        Blake3.hash(input, &out, .{});
        return out;
    }
};

/// Binary Merkle tree over fixed-size hashes (shared zig-merkle impl).
const MerkleTree = @import("zig-merkle").MerkleTree(Blake3Hash);

// ============================================================================
// Domain
// ============================================================================

/// The order-2^log_n subgroup of F*, in natural exponent order.
///
/// `at(i) = g_k^i` where `g_k = omega^(2^(two_adicity - log_n))` and
/// `omega` is F's primitive `2^two_adicity`-th root of unity. Squaring
/// maps this domain onto `Domain(F)` of size n/2 two-to-one:
/// `x_j^2 = g_{k-1}^j`, so the fold child of the antipodal pair
/// `(j, j + n/2)` lands at position `j` of the half-size domain — the
/// natural layout is preserved at every layer.
/// FRI domains on the norm-1 torus of `F[p^2]`. See `torus.zig` for why
/// `p + 1` rather than `p - 1` is the modulus that matters, and for the
/// generator derivation.
pub const torus = @import("torus.zig");

pub fn Domain(comptime F: type) type {
    return struct {
        log_n: u6,
        step_gen: F,

        const Self = @This();

        /// # Errors
        /// `error.DomainTooLarge` when `log_n > Field.two_adicity` (the shift
        /// `two_adicity - log_n` would underflow), and `error.OrderTooLarge` when
        /// the field itself has no root of that order. The old
        /// `std.debug.assert` is compiled out in `ReleaseFast`, where
        /// `two_adicity - log_n` then underflowed and `1 << shift` with a
        /// shift >= 64 is undefined behaviour. `log_n` reaches this function
        /// from the prover config and from `proof.log_final`, so it is
        /// caller-controlled in the verifier.
        pub fn init(comptime Field: type, log_n: u6) error{ DomainTooLarge, OrderTooLarge }!Self {
            if (log_n > Field.two_adicity) return error.DomainTooLarge;
            const omega = try Field.primitiveRootOfUnity(Field.two_adicity);
            const shift: u6 = @intCast(Field.two_adicity - log_n);
            return .{ .log_n = log_n, .step_gen = omega.pow(@as(u64, 1) << shift) };
        }

        pub fn size(self: Self) usize {
            return @as(usize, 1) << self.log_n;
        }

        /// The i-th domain element (natural order): g_k^i.
        pub fn at(self: Self, i: usize) F {
            return self.step_gen.pow(@as(u64, @intCast(i)));
        }

        /// Fill `buf` (len == size) with the domain elements.
        ///
        /// # Errors
        /// `error.LengthMismatch` when `buf.len != self.size()`; the old
        /// `std.debug.assert` vanished in `ReleaseFast` and the loop then
        /// wrote past the end of `buf`.
        pub fn fill(self: Self, buf: []F) error{LengthMismatch}!void {
            if (buf.len != self.size()) return error.LengthMismatch;
            var x = F.one();
            const g = self.step_gen;
            for (buf) |*slot| {
                slot.* = x;
                x = x.mul(g);
            }
        }
    };
}

// ============================================================================
// Configuration
// ============================================================================

pub const Config = struct {
    /// log2 of the initial domain size (order of H_k). The committed
    /// evaluations are the polynomial on the full domain.
    log_domain: u6,
    /// log2 of the degree bound of the committed polynomial.
    log_initial_degree: u6,
    /// log2 of the LAST FRI layer's domain size. The residual polynomial
    /// is evaluated on this domain.
    log_final: u6,
    /// log2 of the residual degree bound (d). The residual is sent as
    /// exactly `2^log_residual_degree` coefficients; the final domain
    /// must be strictly larger (rate < 1) so queries catch cheaters.
    log_residual_degree: u6,
    /// Number of random positions checked.
    num_queries: usize,

    /// Derived: number of folding rounds.
    pub fn rounds(self: Config) FriError!usize {
        if (self.log_domain == 0 or self.log_domain > 63) return FriError.InvalidParameters;
        if (self.log_final >= self.log_domain) return FriError.InvalidParameters;
        if (self.log_residual_degree >= self.log_final) return FriError.InvalidParameters;
        if (self.log_final > 12 or self.log_residual_degree > 12) return FriError.InvalidParameters;
        if (self.num_queries == 0) return FriError.InvalidParameters;
        return self.log_domain - self.log_final;
    }

    pub fn validate(self: Config) FriError!void {
        const round_count = try self.rounds();
        if (self.log_initial_degree > self.log_domain) return FriError.InvalidParameters;
        if (self.log_initial_degree < round_count) return FriError.InvalidParameters;
        if (self.log_initial_degree - round_count != self.log_residual_degree) return FriError.InvalidParameters;
    }
};

// ============================================================================
// Proof structures
// ============================================================================

/// One committed layer (verifier view).
pub const LayerInfo = struct {
    merkle_root: [HASH_LEN]u8,
    log_size: u6,
};

/// Per-query opening: values at one antipodal pair per layer + Merkle
/// paths for those pair-leaves.
pub const QueryProof = struct {
    /// Initial pair index (leaf index in layer 0): the pair covers
    /// positions (j, j + n/2).
    pair_index: usize,
    /// Per layer r: the antipodal pair (f(x), f(-x)) at the queried spot.
    values: [][]u8, // serialized 2*NUM_BYTES per round; parse per F
    paths: [][]const [HASH_LEN]u8,
};

/// Full FRI proof.
pub const Proof = struct {
    layers: []LayerInfo,
    /// The residual polynomial, coefficients, degree < 2^log_residual_degree.
    residual: []const []const u8,
    queries: []QueryProof,
    log_domain: u6,
    log_final: u6,
    log_residual_degree: u6,

    pub fn deinit(self: *Proof, allocator: std.mem.Allocator) void {
        for (self.queries) |q| {
            for (q.values) |v| allocator.free(@constCast(v));
            allocator.free(@constCast(q.values));
            for (q.paths) |p| allocator.free(@constCast(p));
            allocator.free(@constCast(q.paths));
        }
        allocator.free(self.queries);
        allocator.free(self.layers);
        for (self.residual) |c| allocator.free(@constCast(c));
        allocator.free(@constCast(self.residual));
    }
};

// ============================================================================
// Serialization helpers
// ============================================================================

fn serializeElem(comptime F: type, allocator: std.mem.Allocator, elem: F) FriError![]u8 {
    const buf = allocator.alloc(u8, F.NUM_BYTES) catch return FriError.OutOfMemory;
    const bytes = elem.toBytes();
    @memcpy(buf, &bytes);
    return buf;
}

fn serializePair(comptime F: type, allocator: std.mem.Allocator, a: F, b: F) FriError![]u8 {
    const N = F.NUM_BYTES;
    const buf = allocator.alloc(u8, 2 * N) catch return FriError.OutOfMemory;
    const ab = a.toBytes();
    const bb = b.toBytes();
    @memcpy(buf[0..N], &ab);
    @memcpy(buf[N .. 2 * N], &bb);
    return buf;
}

fn deserializeElem(comptime F: type, bytes: []const u8) FriError!F {
    if (bytes.len != F.NUM_BYTES) return FriError.InvalidProof;
    return F.fromBytes(bytes) catch return FriError.InvalidProof;
}

fn deserializePair(comptime F: type, bytes: []const u8) FriError![2]F {
    const N = F.NUM_BYTES;
    if (bytes.len != 2 * N) return FriError.InvalidProof;
    const a = F.fromBytes(bytes[0..N]) catch return FriError.InvalidProof;
    const b = F.fromBytes(bytes[N .. 2 * N]) catch return FriError.InvalidProof;
    return .{ a, b };
}

/// Two-to-one leaf hashing for the commitment layer: leaf_j commits to
/// the antipodal pair (f(x), f(-x)) at positions (j, j + n/2).
fn hashPair(comptime F: type, x: F, neg_x: F) [HASH_LEN]u8 {
    const ab = x.toBytes();
    const bb = neg_x.toBytes();
    var h = Blake3.init(.{});
    h.update(&ab);
    h.update(&bb);
    var out: [HASH_LEN]u8 = undefined;
    h.final(&out);
    return out;
}

// ============================================================================
// Prover
// ============================================================================

/// Prove that `evals` (length 2^log_domain; the polynomial evaluated on
/// the natural-order subgroup domain) has degree < 2^log_residual_degree.
///
/// For an honest prover the residual's high coefficients are exactly
/// zero (each fold halves the degree of a true polynomial), so
/// truncating the coefficient vector is lossless; for a cheater the
/// truncation drops real energy and the re-evaluated residual disagrees
/// with the last committed layer almost everywhere — queries catch it.
/// Prove over `Domain(F)`, the multiplicative 2-subgroup of the base field.
/// The wrapper every existing caller uses; see `proveOn` for the general form.
pub fn prove(
    comptime F: type,
    allocator: std.mem.Allocator,
    transcript: anytype,
    evals: []const F,
    config: Config,
) FriError!Proof {
    return proveOn(F, Domain(F), allocator, transcript, evals, config);
}

/// Prove over an arbitrary FRI domain.
///
/// `Dom` is any type with the `Domain(F)` shape -- `init`, `size`, `at`,
/// `fill`. That is the whole point: `Domain(F)` builds its subgroup from
/// `F.two_adicity`, so a field with 2-adicity 1 (`M31`) had no usable domain
/// at all, and nothing in the signature could express "some other subgroup of
/// order `2^k`". `torus.TorusDomain` supplies one, built from the norm-1 torus
/// of `F[p^2]`, whose order is `p + 1`.
///
/// The prover/verifier pair must agree on `Dom`: they derive the fold's `x_j`
/// and the queries' positions from it, and nothing in a proof records which
/// domain was used.
pub fn proveOn(
    comptime F: type,
    comptime Dom: type,
    allocator: std.mem.Allocator,
    transcript: anytype,
    evals: []const F,
    config: Config,
) FriError!Proof {
    try config.validate();
    const rounds = try config.rounds();
    const n: usize = @as(usize, 1) << config.log_domain;
    if (evals.len != n) return FriError.InvalidParameters;
    if (config.log_domain > F.two_adicity) return FriError.InvalidParameters;
    const residual_len: usize = @as(usize, 1) << config.log_residual_degree;

    const half_inv = F.fromInt(1).div(F.fromInt(2));

    // Layer buffers 0..R (the last becomes the residual basis).
    var layer_evals = allocator.alloc([]F, rounds + 1) catch return FriError.OutOfMemory;
    const empty_evals: []F = &[_]F{};
    for (layer_evals) |*le| le.* = empty_evals;
    defer {
        for (layer_evals) |le| {
            if (le.len != 0) allocator.free(le);
        }
        allocator.free(layer_evals);
    }
    layer_evals[0] = allocator.dupe(F, evals) catch return FriError.OutOfMemory;

    var roots = allocator.alloc([HASH_LEN]u8, rounds) catch return FriError.OutOfMemory;
    defer allocator.free(roots);
    // Layer 0 must survive into the proof's query extraction; take it out
    // of the defer-managed set by aliasing (freed via layer_evals too, but
    // we only free once — see ownership note below).
    const layers_meta = allocator.alloc(LayerInfo, rounds) catch return FriError.OutOfMemory;
    errdefer allocator.free(layers_meta);
    // NOTE: layers_meta freed by caller via Proof.deinit; roots is a copy.

    var alphas: [64]F = undefined;
    var log_cur: u6 = config.log_domain;

    for (0..rounds) |r| {
        const cur = layer_evals[r];
        const half = cur.len / 2;

        // Commit: one leaf per antipodal pair (positions j, j + half).
        const leaves = allocator.alloc([HASH_LEN]u8, half) catch return FriError.OutOfMemory;
        defer allocator.free(leaves);
        for (0..half) |j| leaves[j] = hashPair(F, cur[j], cur[j + half]);

        var tree = MerkleTree.initFromHashes(allocator, leaves) catch return FriError.OutOfMemory;
        defer tree.deinit();
        roots[r] = tree.root();
        layers_meta[r] = .{ .merkle_root = tree.root(), .log_size = log_cur };

        // Absorb the root, then squeeze the fold challenge.
        transcript.absorbBytes(&roots[r]);
        alphas[r] = transcript.challengeFieldChecked(F);

        // Fold with the antipodal pair (j, j + half): the child lands at
        // position j of the half-size natural domain (x_j^2 = g_{k-1}^j).
        const dom = try Dom.init(F, log_cur);
        const next = allocator.alloc(F, half) catch return FriError.OutOfMemory;
        for (0..half) |j| {
            const x = dom.at(j);
            const fx = cur[j];
            const fnegx = cur[j + half];
            const even = fx.add(fnegx).mul(half_inv);
            const odd = fx.sub(fnegx).div(x).mul(half_inv);
            next[j] = even.add(alphas[r].mul(odd));
        }
        layer_evals[r + 1] = next;
        log_cur -= 1;
    }

    // ---------- residual ----------
    // Interpolate the final layer (length 2^log_final, natural order) to
    // coefficients and truncate to the degree bound.
    const full_coeffs = interpolateToCoeffs(F, Dom, allocator, layer_evals[rounds], config.log_final) catch return FriError.OutOfMemory;
    defer allocator.free(full_coeffs);

    const residual_bytes = allocator.alloc([]const u8, residual_len) catch return FriError.OutOfMemory;
    for (residual_bytes) |*cb| cb.* = &[_]u8{};
    errdefer {
        for (residual_bytes) |cb| {
            if (cb.len != 0) allocator.free(@constCast(cb));
        }
        allocator.free(@constCast(residual_bytes));
    }
    for (0..residual_len) |i| {
        residual_bytes[i] = try serializeElem(F, allocator, full_coeffs[i]);
    }
    for (residual_bytes) |cb| {
        const c = try deserializeElem(F, cb);
        transcript.absorbField(F, c);
    }

    // ---------- queries ----------
    const queries = try buildQueries(F, allocator, transcript, layer_evals[0 .. rounds + 1], roots, config);

    return .{
        .layers = layers_meta,
        .residual = residual_bytes,
        .queries = queries,
        .log_domain = config.log_domain,
        .log_final = config.log_final,
        .log_residual_degree = config.log_residual_degree,
    };
}

/// Naive O(m^2) interpolation on the final (tiny) domain: returns
/// coefficients c_0..c_{m-1} of the unique poly of degree < m matching
/// the values at the natural points H_{log_final}[i]. Small final sizes
/// keep this cheap.
fn interpolateToCoeffs(
    comptime F: type,
    comptime Dom: type,
    allocator: std.mem.Allocator,
    values: []const F,
    log_final: u6,
) FriError![]F {
    const m = values.len; // == 2^log_final
    const dom = try Dom.init(F, log_final);
    // Solve the Vandermonde system V·c = v with V[i][j] = x_i^j.
    const mat = allocator.alloc(F, m * (m + 1)) catch return FriError.OutOfMemory;
    defer allocator.free(mat);
    for (0..m) |i| {
        const xi = dom.at(i);
        var xp = F.one();
        for (0..m) |j| {
            mat[i * (m + 1) + j] = xp;
            xp = xp.mul(xi);
        }
        mat[i * (m + 1) + m] = values[i];
    }
    const coeffs = allocator.alloc(F, m) catch return FriError.OutOfMemory;
    errdefer allocator.free(coeffs);
    for (0..m) |col| {
        // pivot
        var pivot: ?usize = null;
        for (col..m) |r| {
            if (!mat[r * (m + 1) + col].isZero()) {
                pivot = r;
                break;
            }
        }
        const p = pivot orelse return FriError.InvalidParameters;
        if (p != col) {
            for (0..(m + 1)) |c| {
                const tmp = mat[col * (m + 1) + c];
                mat[col * (m + 1) + c] = mat[p * (m + 1) + c];
                mat[p * (m + 1) + c] = tmp;
            }
        }
        // normalize row col
        const inv = mat[col * (m + 1) + col].inv();
        for (0..(m + 1)) |c| mat[col * (m + 1) + c] = mat[col * (m + 1) + c].mul(inv);
        // eliminate other rows
        for (0..m) |r| {
            if (r == col) continue;
            const f = mat[r * (m + 1) + col];
            if (f.isZero()) continue;
            for (0..(m + 1)) |c| {
                const sub_v = mat[col * (m + 1) + c].mul(f);
                mat[r * (m + 1) + c] = mat[r * (m + 1) + c].sub(sub_v);
            }
        }
    }
    for (0..m) |i| coeffs[i] = mat[i * (m + 1) + m];
    return coeffs;
}

fn buildQueries(
    comptime F: type,
    allocator: std.mem.Allocator,
    transcript: anytype,
    layers: []const []F,
    roots: []const [HASH_LEN]u8,
    config: Config,
) FriError![]QueryProof {
    _ = roots;
    const round_count = config.rounds() catch return FriError.InvalidParameters;

    var trees_buf: [64]?MerkleTree = @splat(null);
    defer for (&trees_buf) |*maybe_tree| {
        if (maybe_tree.*) |*t| t.deinit();
    };
    for (0..round_count) |r| {
        const cur = layers[r];
        const half = cur.len / 2;
        const leaves = allocator.alloc([HASH_LEN]u8, half) catch return FriError.OutOfMemory;
        defer allocator.free(leaves);
        for (0..half) |j| leaves[j] = hashPair(F, cur[j], cur[j + half]);
        trees_buf[r] = MerkleTree.initFromHashes(allocator, leaves) catch return FriError.OutOfMemory;
    }

    const queries = allocator.alloc(QueryProof, config.num_queries) catch return FriError.OutOfMemory;
    for (queries) |*q| {
        q.* = .{
            .pair_index = 0,
            .values = &[_][]u8{},
            .paths = &[_][]const [HASH_LEN]u8{},
        };
    }
    errdefer {
        for (queries) |q| {
            for (q.values) |v| {
                if (v.len != 0) allocator.free(v);
            }
            if (q.values.len != 0) allocator.free(q.values);
            for (q.paths) |p| {
                if (p.len != 0) allocator.free(@constCast(p));
            }
            if (q.paths.len != 0) allocator.free(@constCast(q.paths));
        }
        allocator.free(queries);
    }

    for (queries) |*q| {
        const seed = transcript.challengeU64();
        const e0: usize = @intCast(seed % @as(u64, @intCast(layers[0].len)));
        q.pair_index = e0;
        q.values = allocator.alloc([]u8, round_count) catch return FriError.OutOfMemory;
        for (q.values) |*v| v.* = &[_]u8{};
        q.paths = allocator.alloc([]const [HASH_LEN]u8, round_count) catch return FriError.OutOfMemory;
        for (q.paths) |*p| p.* = &[_][HASH_LEN]u8{};

        var e: usize = e0;
        for (0..round_count) |r| {
            const half = layers[r].len / 2;
            const j = e % half;
            q.values[r] = try serializePair(F, allocator, layers[r][j], layers[r][j + half]);

            const mp = trees_buf[r].?.prove(j, allocator) catch return FriError.OutOfMemory;
            allocator.free(mp.is_left_sibling);
            q.paths[r] = mp.siblings;

            e = j;
        }
    }
    return queries;
}

// ============================================================================
// Verifier
// ============================================================================

/// Verify a FRI proof.
///
/// Checks (in order):
///   1. Structural validity (sizes, lengths, config match).
///   2. Query indices match transcript-derived challenges.
///   3. Every antipodal pair authenticates against its layer's Merkle root.
///   4. Folding consistency across all rounds (exact positional equality).
///   5. The last fold matches the residual's evaluation on the final
///      domain — the degree anchor.
/// Verify against `Domain(F)`. See `proveOn` for why the domain is a parameter
/// at all, and `verifyOn`.
pub fn verify(
    comptime F: type,
    transcript: anytype,
    proof: *const Proof,
    config: Config,
) FriError!bool {
    return verifyOn(F, Domain(F), transcript, proof, config);
}

/// Verify against the same `Dom` the proof was produced on. `Dom` must match
/// the prover's: a proof carries no record of its domain, so a mismatch is a
/// caller error that surfaces as a failed proof, not a typed one.
pub fn verifyOn(
    comptime F: type,
    comptime Dom: type,
    transcript: anytype,
    proof: *const Proof,
    config: Config,
) FriError!bool {
    try config.validate();
    const rounds = try config.rounds();
    if (proof.log_domain != config.log_domain) return FriError.InvalidProof;
    if (proof.log_final != config.log_final) return FriError.InvalidProof;
    if (proof.log_residual_degree != config.log_residual_degree) return FriError.InvalidProof;
    if (config.log_domain > F.two_adicity) return false;
    // `log_final` drives its own `Domain.init`; before this check only
    // `log_domain` was compared against the two-adicity, so a config with a
    // small two-adicity field and `log_final > two_adicity` underflowed the
    // shift inside `Domain.init`.
    if (config.log_final > F.two_adicity) return false;
    if (proof.layers.len != rounds) return FriError.InvalidProof;
    const residual_len: usize = @as(usize, 1) << config.log_residual_degree;
    if (proof.residual.len != residual_len) return FriError.InvalidProof;
    if (proof.queries.len != config.num_queries) return FriError.InvalidProof;

    const n: usize = @as(usize, 1) << config.log_domain;
    const final_len: usize = @as(usize, 1) << config.log_final;
    const half_inv = F.fromInt(1).div(F.fromInt(2));

    // ---------- replay challenges ----------
    var alphas: [64]F = undefined;
    if (rounds > 64) return FriError.InvalidProof;
    for (0..rounds) |r| {
        if (proof.layers[r].log_size != config.log_domain - @as(u6, @intCast(r))) {
            return FriError.InvalidProof;
        }
        transcript.absorbBytes(&proof.layers[r].merkle_root);
        alphas[r] = transcript.challengeFieldChecked(F);
    }

    // ---------- residual: coefficients + evaluations on final domain ----------
    var residual: [4096]F = undefined;
    if (residual_len > 4096) return FriError.InvalidProof;
    for (proof.residual, 0..) |cb, i| {
        residual[i] = try deserializeElem(F, cb);
        transcript.absorbField(F, residual[i]);
    }

    // The residual is evaluated on the FULL final domain (size
    // 2^log_final > degree bound): rate < 1 gives the soundness distance.
    var final_evals_buf: [4096]F = undefined;
    if (final_len > 4096) return FriError.InvalidProof;
    const dom_final = try Dom.init(F, proof.log_final);
    for (0..final_len) |i| {
        const xi = dom_final.at(i);
        var acc = F.zero();
        var xp = F.one();
        for (proof.residual) |cb| {
            const c = try deserializeElem(F, cb);
            acc = acc.add(c.mul(xp));
            xp = xp.mul(xi);
        }
        final_evals_buf[i] = acc;
    }

    // ---------- queries ----------
    for (proof.queries) |q| {
        const seed = transcript.challengeU64();
        const expected_idx: usize = @intCast(seed % @as(u64, @intCast(n)));
        if (q.pair_index != expected_idx) return false;
        if (q.values.len != rounds or q.paths.len != rounds) return false;

        var e: usize = q.pair_index;
        for (0..rounds) |r| {
            const layer_log: u6 = config.log_domain - @as(u6, @intCast(r));
            const half_r: usize = (@as(usize, 1) << layer_log) / 2;
            const j = e % half_r; // pair slot in layer r

            const pair = try deserializePair(F, q.values[r]);
            const x = pair[0]; // f(x)  at position j
            const negx = pair[1]; // f(-x) at position j + half_r

            // Merkle inclusion of this pair-leaf.
            const leaf = hashPair(F, x, negx);
            const expected_depth: usize = @as(usize, layer_log) - 1;
            if (q.paths[r].len != expected_depth) return false;
            if (!MerkleTree.verifyPath(proof.layers[r].merkle_root, j, leaf, q.paths[r])) {
                return false;
            }

            // Fold: child at layer r+1, position j.
            const dom_r = try Dom.init(F, layer_log);
            const xv = dom_r.at(j);
            const even = x.add(negx).mul(half_inv);
            const odd = x.sub(negx).div(xv).mul(half_inv);
            const expected = even.add(alphas[r].mul(odd));

            if (r + 1 < rounds) {
                // Exact positional equality: the child value is slot 0 of
                // the next round's pair if j is in the lower half of the
                // next layer, slot 1 otherwise (antipodal pair of j in
                // layer r+1 is (j mod half', j mod half' + half')).
                const half_next = half_r / 2;
                const child_slot: usize = if (j < half_next) 0 else 1;
                const child_pair = try deserializePair(F, q.values[r + 1]);
                const child = child_pair[child_slot];
                if (!expected.eql(child)) return false;
            } else {
                // Last round: compare against the residual's evaluation at
                // final-domain position j — the degree anchor.
                if (!expected.eql(final_evals_buf[j])) return false;
            }
            e = j; // next layer's element position
        }
    }

    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Transcript = @import("zig-transcript").Transcript;
const Goldilocks = zfield.Goldilocks;

/// log2 of the residual degree bound used across the suite: rate 1/8 at
/// the final domain (log_final=6 => 64-point domain, degree bound 8).
fn testConfig(log_n: u6, queries: usize) Config {
    return .{
        .log_domain = log_n,
        .log_initial_degree = @intCast(log_n - 3),
        .log_final = 6,
        .log_residual_degree = 3,
        .num_queries = queries,
    };
}

/// Evaluate `coeffs` (degree < len) at `x`.
fn evalPoly(comptime F: type, coeffs: []const F, x: F) F {
    var acc = F.zero();
    var xp = F.one();
    for (coeffs) |c| {
        acc = acc.add(c.mul(xp));
        xp = xp.mul(x);
    }
    return acc;
}

test "fri v2: degree-2 poly verifies" {
    const a = testing.allocator;
    const log_n: u6 = 8; // 256
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    const c1 = Goldilocks.fromInt(3);
    const c2 = Goldilocks.fromInt(7);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(x.mul(c1)).add(c2);
    }

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var vt = Transcript.init("fri-v2-test");
    try testing.expect(try verify(Goldilocks, &vt, &proof, cfg));
}

test "fri v2: RANDOM data must be rejected (regression: ZA-2026-001)" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();

    var accepted: usize = 0;
    const trials = 16;
    for (0..trials) |t| {
        for (0..n) |i| evals[i] = Goldilocks.random(rng);
        // vary data across trials
        evals[0] = evals[0].add(Goldilocks.fromInt(t));

        var pt = Transcript.init("fri-v2-test");
        var proof = try prove(Goldilocks, a, &pt, evals, cfg);
        defer proof.deinit(a);
        var vt = Transcript.init("fri-v2-test");
        if (try verify(Goldilocks, &vt, &proof, cfg)) accepted += 1;
    }
    // Random data is maximally far from degree < 8: every trial must
    // reject. (v1 accepted 16/16 of these — ZA-2026-001.)
    try testing.expectEqual(@as(usize, 0), accepted);
}

test "fri v2: over-degree poly must be rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);

    var accepted: usize = 0;
    const trials = 8;
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rng = prng.random();
    for (0..trials) |t| {
        // degree-128 polynomial (degree bound is 8).
        var coeffs: [129]Goldilocks = undefined;
        for (&coeffs, 0..) |*c, k| c.* = Goldilocks.fromInt(k *% 2654435761 +% t);
        coeffs[128] = Goldilocks.random(rng);
        for (0..n) |i| evals[i] = evalPoly(Goldilocks, &coeffs, dom.at(i));

        var pt = Transcript.init("fri-v2-test");
        var proof = try prove(Goldilocks, a, &pt, evals, cfg);
        defer proof.deinit(a);
        var vt = Transcript.init("fri-v2-test");
        if (try verify(Goldilocks, &vt, &proof, cfg)) accepted += 1;
    }
    try testing.expectEqual(@as(usize, 0), accepted);
}

test "fri v2: tampered query value rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(Goldilocks.fromInt(5));
    }

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    // Corrupt one value of the first query's first pair.
    @constCast(&proof.queries[0].values[0][0]).* ^= 1;

    var vt = Transcript.init("fri-v2-test");
    try testing.expect(!(try verify(Goldilocks, &vt, &proof, cfg)));
}

test "fri v2: truncated Merkle path rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    for (0..n) |i| evals[i] = dom.at(i).sqr();

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    const original_path = proof.queries[0].paths[0];
    try testing.expect(original_path.len > 0);
    @constCast(&proof.queries[0].paths[0]).* = original_path[0 .. original_path.len - 1];
    defer @constCast(&proof.queries[0].paths[0]).* = original_path;

    var vt = Transcript.init("fri-v2-test");
    try testing.expect(!(try verify(Goldilocks, &vt, &proof, cfg)));
}

test "fri v2: wrong transcript (statement binding) rejected" {
    const a = testing.allocator;
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    for (0..n) |i| evals[i] = dom.at(i).sqr();

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var vt = Transcript.init("different-statement"); // different label
    const ok = verify(Goldilocks, &vt, &proof, cfg) catch false;
    try testing.expect(!ok);
}

test "fri v2: interpolateToCoeffs recovers a degree-1 polynomial" {
    const a = testing.allocator;
    const log_f: u6 = 6;
    const m: usize = @as(usize, 1) << log_f;
    const dom = try Domain(Goldilocks).init(Goldilocks, log_f);

    var values = try a.alloc(Goldilocks, m);
    defer a.free(values);
    const c0 = Goldilocks.fromInt(5);
    const c1 = Goldilocks.fromInt(3);
    for (0..m) |i| {
        const x = dom.at(i);
        values[i] = c0.add(c1.mul(x));
    }
    const coeffs = try interpolateToCoeffs(Goldilocks, Domain(Goldilocks), a, values, log_f);
    defer a.free(coeffs);
    try testing.expectEqual(@as(usize, 64), coeffs.len);
    try testing.expect(coeffs[0].eql(c0));
    try testing.expect(coeffs[1].eql(c1));
    for (coeffs[2..]) |c| try testing.expect(c.isZero());
}

test "fri v2: domain structure — antipodal pairs and squaring" {
    const t = std.testing;
    const log_n: u6 = 6;
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);
    const n = dom.size();

    var buf: [64]Goldilocks = undefined;
    try dom.fill(buf[0..n]);

    // x and x + n/2 are negatives (exponent differs by 2^(k-1)).
    for (0..n / 2) |i| {
        try t.expect(buf[i].add(buf[i + n / 2]).isZero());
    }

    // Squaring collapses {x, -x} pairs: element j of H_k squares to
    // element j of H_{k-1} (natural layout fold).
    const dom2 = try Domain(Goldilocks).init(Goldilocks, log_n - 1);
    for (0..n / 2) |i| {
        try t.expect(buf[i].sqr().eql(dom2.at(i)));
    }

    // All distinct, none zero.
    for (buf[0..n], 0..) |x, i| {
        try t.expect(!x.isZero());
        for (buf[0..i]) |y| try t.expect(!x.eql(y));
    }
}

test "fri v2: config validation" {
    // log_final >= log_domain
    try testing.expectError(FriError.InvalidParameters, (Config{
        .log_domain = 6,
        .log_initial_degree = 3,
        .log_final = 6,
        .log_residual_degree = 2,
        .num_queries = 4,
    }).rounds());
    // rate 1 (degree bound == final domain size): no distance
    try testing.expectError(FriError.InvalidParameters, (Config{
        .log_domain = 8,
        .log_initial_degree = 5,
        .log_final = 6,
        .log_residual_degree = 6,
        .num_queries = 4,
    }).rounds());
    // zero queries
    try testing.expectError(FriError.InvalidParameters, (Config{
        .log_domain = 8,
        .log_initial_degree = 5,
        .log_final = 6,
        .log_residual_degree = 3,
        .num_queries = 0,
    }).rounds());
}

test "fri v2: larger domain, honest degree-bounded poly verifies" {
    const a = testing.allocator;
    const log_n: u6 = 10; // 1024
    const n: usize = @as(usize, 1) << log_n;
    // degree bound 32 (log_final=8 => 256-point final domain, rate 1/8)
    const cfg = Config{ .log_domain = log_n, .log_initial_degree = 7, .log_final = 8, .log_residual_degree = 5, .num_queries = 20 };
    const dom = try Domain(Goldilocks).init(Goldilocks, log_n);

    var evals = try a.alloc(Goldilocks, n);
    defer a.free(evals);
    // degree-31 polynomial: max degree under the bound.
    var coeffs: [32]Goldilocks = undefined;
    var prng = std.Random.DefaultPrng.init(1234);
    const rng = prng.random();
    for (&coeffs) |*c| c.* = Goldilocks.random(rng);
    for (0..n) |i| evals[i] = evalPoly(Goldilocks, &coeffs, dom.at(i));

    var pt = Transcript.init("fri-v2-test");
    var proof = try prove(Goldilocks, a, &pt, evals, cfg);
    defer proof.deinit(a);
    var vt = Transcript.init("fri-v2-test");
    try testing.expect(try verify(Goldilocks, &vt, &proof, cfg));
}

test "Domain.init rejects a domain beyond the field two-adicity" {
    // Goldilocks has two_adicity == 32, so 33 is out of range and the shift
    // `two_adicity - log_n` would underflow.
    try testing.expectError(error.DomainTooLarge, Domain(Goldilocks).init(Goldilocks, 33));
    try testing.expect((try Domain(Goldilocks).init(Goldilocks, 32)).size() == @as(usize, 1) << 32);
}

test "Domain.fill rejects a buffer of the wrong length" {
    const dom = try Domain(Goldilocks).init(Goldilocks, 4);
    var ok: [16]Goldilocks = undefined;
    try dom.fill(&ok);
    var short: [15]Goldilocks = undefined;
    try testing.expectError(error.LengthMismatch, dom.fill(&short));
    var long: [17]Goldilocks = undefined;
    try testing.expectError(error.LengthMismatch, dom.fill(&long));
}

// ============================================================================
// FRI over the norm-1 torus (M31, M61)
// ============================================================================

/// The premise of every test below, asserted rather than assumed: the base
/// 31-bit field has 2-adicity **1**, so it has no 2-subgroup of order 4 and
/// `Domain(M31)` cannot produce a FRI domain of any useful size. That is the
/// reason the base field was documented as unusable here.
fn assertBaseFieldCannotHostFRI() !void {
    try testing.expectEqual(@as(usize, 1), zfield.M31.two_adicity);
    try testing.expectError(error.DomainTooLarge, Domain(zfield.M31).init(zfield.M31, 2));
}

test "torus FRI: the base M31 field cannot host a domain, and the torus can" {
    try assertBaseFieldCannotHostFRI();

    // The torus's order is p + 1, and 2^31 - 1 + 1 = 2^31.
    try testing.expectEqual(@as(comptime_int, 31), torus.torusAdicity(zfield.M31));
    const F = torus.Torus31;
    const Dom = torus.TorusDomain(F, zfield.M31);
    const dom = try Dom.init(F, 8);
    try testing.expectEqual(@as(usize, 256), dom.size());

    // And it is a genuinely different domain from the ambient 2-adic subgroup
    // of the same field: the extension's own two_adicity is 32, so
    // `Domain(F)` also happens to work, but on a split group whose elements
    // need not have norm 1. The torus is the one that does.
    try testing.expectEqual(@as(usize, 32), F.two_adicity);
    for (0..dom.size()) |i| {
        try testing.expectEqual(@as(u64, 1), Dom.norm(dom.at(i)));
    }
}

test "torus FRI: an honest proof verifies over the torus in M31" {
    // **The capability, not the absence of breakage.** Every other FRI test in
    // this file runs on Goldilocks, whose 2-adicity is 32, so "nothing broke"
    // says nothing about a domain none of them touches. This asserts the new
    // thing works: a degree-32 polynomial committed on the torus domain of
    // F_M31[i], proved and verified.
    try assertBaseFieldCannotHostFRI();

    const a = testing.allocator;
    const F = torus.Torus31;
    const Dom = torus.TorusDomain(F, zfield.M31);
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    const dom = try Dom.init(F, log_n);
    var evals = try a.alloc(F, n);
    defer a.free(evals);
    // f(x) = x^2 + 3x + 7, degree 2, well inside the degree-32 bound.
    const c1 = F.fromInt(3);
    const c2 = F.fromInt(7);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(x.mul(c1)).add(c2);
    }

    var pt = Transcript.init("torus-m31");
    var proof = try proveOn(F, Dom, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var vt = Transcript.init("torus-m31");
    try testing.expect(try verifyOn(F, Dom, &vt, &proof, cfg));
}

test "torus FRI: the same proof is rejected when the data is not low degree" {
    // The negative, on the new field. Without it the positive above would also
    // pass against a verifier that accepts everything.
    const a = testing.allocator;
    const F = torus.Torus31;
    const Dom = torus.TorusDomain(F, zfield.M31);
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    var prng = std.Random.DefaultPrng.init(0x7025);
    const rng = prng.random();
    const evals = try a.alloc(F, n);
    defer a.free(evals);
    for (evals) |*x| x.* = F.random(rng);

    var pt = Transcript.init("torus-m31-neg");
    var proof = try proveOn(F, Dom, a, &pt, evals, cfg);
    defer proof.deinit(a);
    var vt = Transcript.init("torus-m31-neg");
    try testing.expect(!(try verifyOn(F, Dom, &vt, &proof, cfg)));
}

test "torus FRI: a tampered proof is rejected" {
    const a = testing.allocator;
    const F = torus.Torus31;
    const Dom = torus.TorusDomain(F, zfield.M31);
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);
    const dom = try Dom.init(F, log_n);

    var evals = try a.alloc(F, n);
    defer a.free(evals);
    const c1 = F.fromInt(3);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(x.mul(c1));
    }
    var pt = Transcript.init("torus-m31-tamper");
    var proof = try proveOn(F, Dom, a, &pt, evals, cfg);
    defer proof.deinit(a);

    // Honest first, so a `false` below is about the tampering.
    var vt0 = Transcript.init("torus-m31-tamper");
    try testing.expect(try verifyOn(F, Dom, &vt0, &proof, cfg));

    // `residual` is serialized bytes, so this is what tampering actually looks
    // like: flip a bit in a coefficient the verifier will re-expand.
    @constCast(proof.residual[0])[F.NUM_BYTES - 1] ^= 0x01;
    var vt = Transcript.init("torus-m31-tamper");
    try testing.expect(!(try verifyOn(F, Dom, &vt, &proof, cfg)));
}

test "torus FRI: the same proof verifies over the torus in M61" {
    const a = testing.allocator;
    const F = torus.Torus61;
    const Dom = torus.TorusDomain(F, zfield.M61);
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    // M61 is a different modulus, a different extension and a different
    // torus, so the generator search and the order check both run again.
    try testing.expectEqual(@as(comptime_int, 61), torus.torusAdicity(zfield.M61));

    const dom = try Dom.init(F, log_n);
    var evals = try a.alloc(F, n);
    defer a.free(evals);
    const c1 = F.fromInt(5);
    const c2 = F.fromInt(11);
    for (0..n) |i| {
        const x = dom.at(i);
        evals[i] = x.sqr().add(x.mul(c1)).add(c2);
    }
    var pt = Transcript.init("torus-m61");
    var proof = try proveOn(F, Dom, a, &pt, evals, cfg);
    defer proof.deinit(a);
    var vt = Transcript.init("torus-m61");
    try testing.expect(try verifyOn(F, Dom, &vt, &proof, cfg));
}

test "torus FRI: log_n above the torus 2-adicity is a typed error" {
    const F = torus.Torus31;
    const Dom = torus.TorusDomain(F, zfield.M31);
    // 32 is one past M31's torus 2-adicity of 31. Typed, not an assert: the
    // prover reaches `log_domain` from config and the verifier from
    // `proof.log_domain`, so both are caller-controlled.
    try testing.expectError(error.DomainTooLarge, Dom.init(F, 32));
    try testing.expectError(error.DomainTooLarge, Dom.init(F, 63));
    // 31 is the largest that works, and it is reachable without materialising
    // it: `size()` is arithmetic, and building the elements is the caller's
    // memory decision, not the domain's.
    const dom = try Dom.init(F, 31);
    try testing.expectEqual(@as(u64, @as(u64, 1) << 31), @as(u64, dom.size()));
}

test "fri: the transcript switch preserved the challenge sequence" {
    // Both call sites moved from `challengeField` to `challengeFieldChecked`
    // in 4551fd8. Those are different entry points through different
    // decoders: had any field FRI instantiates reduced in one half and
    // rejected in the other, every proof from v0.5.2 would stop verifying
    // under v0.5.3 -- and the API sketch of a renamed call site would not
    // have shown it. `Prime128` is the field where the halves do differ
    // (its `fromBytes` reduces), and at v0.5.2 it could not compile against
    // `challengeField` at all, so no proof of that shape exists to break.
    //
    // Two assertions, and they are not redundant:
    //
    // - the two entry points agree draw by draw, so a one-sided edit to
    //   either decoder is caught with the divergent round named;
    // - the sequence equals a KAT generated by building the **v0.5.2 tag**
    //   (a22dbd9), which is the release a consumer's proofs came from.
    //   The KAT is what catches the mutation the equality check cannot:
    //   both paths read `fromBytesCT`, so an edit to that shared decoder
    //   moves them together, the equality stays green, and only the KAT --
    //   an anchor outside this tree -- says the wire moved.
    //
    // Provenance of the expected values: a throwaway print test appended to
    // `libs/fri/src/root.zig` at a checkout of `v0.5.2`, domain
    // "wire-compat", four `challengeField` draws per field, `toBytes()`
    // concatenated and lower-cased. Not produced by this tree.
    inline for (.{ Goldilocks, torus.Torus31 }) |F| {
        const expected: []const u8 = if (F == Goldilocks)
            "30813cbd29a4ab9a0d4266c6f9b660224339bfebcb15d22f42a87045c4a36a40"
        else
            "42a87045c4a36a40402a0102347ff43be7c5061f8d8dff263d5e490e19185007";

        var old_t = Transcript.init("wire-compat");
        var new_t = Transcript.init("wire-compat");
        var seq: [4 * F.NUM_BYTES]u8 = undefined;
        for (0..4) |i| {
            const a = old_t.challengeField(F);
            const b = new_t.challengeFieldChecked(F);
            try testing.expectEqualSlices(u8, &a.toBytes(), &b.toBytes());
            @memcpy(seq[i * F.NUM_BYTES ..][0..F.NUM_BYTES], &a.toBytes());
        }
        try testing.expectEqualStrings(expected, &std.fmt.bytesToHex(seq, .lower));
    }
}

// ---------------------------------------------------------------------------
// Differential against rules written out in the module's documentation
// ---------------------------------------------------------------------------
//
// The generator and the domain are the two places where `fri` had no external
// witness at all, and both are specified rather than arbitrary: the generator
// is "the first t >= 1 whose Cayley image has order exactly 2^A", and the
// domain is `omega^2^(adicity - log_n)` with `at(i) = step_gen^i`, where both
// root-of-unity rules are spelled out in `zig-field`. The values below come
// from a Python implementation of those sentences, with its own checks run
// first: that the generator's order is exactly 2^A, that every smaller t is
// rejected, and that each domain is a set of distinct elements satisfying
// x^(2^log_n) == 1 with a primitive step.
//
// The fold arithmetic along a real proof's transcript is *not* compared here.
// It depends on the transcript and the Merkle library, and each of those is
// anchored in its own row of docs/requirements.md; a second copy of a Blake3
// sponge and a Merkle tree would be a second place for them to be wrong, not
// a second witness.

const FriTorus = struct {
    name: []const u8,
    a: u64,
    b: u64,
};

const fri_torus_generators = [_]FriTorus{
    .{ .name = "M31", .a = 1717986917, .b = 1288490189 },
    .{ .name = "M61", .a = 1627653888856725141, .b = 1898929536999512666 },
};

const FriDomainCase = struct {
    name: []const u8,
    kind: enum { base, torus },
    /// Which torus, read only when `kind == .torus`: the two extensions are
    /// different types, so it has to be selected at compile time rather than
    /// through a runtime `if`.
    base: enum { m31, m61 },
    log_n: u6,
    hex: []const []const u8,
};

const fri_domains = [_]FriDomainCase{
    .{ .name = "the Goldilocks base-field domain", .kind = .base, .base = .m31, .log_n = 8, .hex = &.{ "0000000000000000000000000000000000000000000000000000000000000001", "000000000000000000000000000000000000000000000000bf79143ce60ca966", "000000000000000000000000000000000000000000000000f80007ff08000001", "00000000000000000000000000000000000000000000000003e8dfd24e8e781f", "0000000000000000000000000000000000000000000000000000008000000000", "000000000000000000000000000000000000000000000000c2ded1724375e12e", "00000000000000000000000000000000000000000000000000040003fffc0000", "0000000000000000000000000000000000000000000000003babf8a70b9016d7", "00000000000000000000000000000000000000000000000000003fffffffc000", "0000000000000000000000000000000000000000000000002a5950219097467d", "000000000000000000000000000000000000000000000000000001fffdfffe00", "0000000000000000000000000000000000000000000000009e07bf052a03ac5d", "000000000000000000000000000000000000000000000000fffffffeffe00001", "000000000000000000000000000000000000000000000000784b4f47d357ef23", "000000000000000000000000000000000000000000000000fffffffdffff0002", "00000000000000000000000000000000000000000000000005b5b114fc207d1c", "000000000000000000000000000000000000000000000000efffffff00000001", "000000000000000000000000000000000000000000000000d19f3568da585bdb", "000000000000000000000000000000000000000000000000ff7fffff00000081", "000000000000000000000000000000000000000000000000eb17187d25277580", "0000000000000000000000000000000000000000000000000000000000000008", "000000000000000000000000000000000000000000000000fbc8a1ec30654b2b", "000000000000000000000000000000000000000000000000c0003fff40000001", "0000000000000000000000000000000000000000000000001f46fe927473c0f8", "0000000000000000000000000000000000000000000000000000040000000000", "00000000000000000000000000000000000000000000000016f68b981baf096a", "0000000000000000000000000000000000000000000000000020001fffe00000", "000000000000000000000000000000000000000000000000dd5fc5395c80b6b7", "0000000000000000000000000000000000000000000000000001fffffffe0000", "00000000000000000000000000000000000000000000000052ca810d84ba33e7", "00000000000000000000000000000000000000000000000000000fffeffff000", "000000000000000000000000000000000000000000000000f03df82d501d62e4", "000000000000000000000000000000000000000000000000fffffffeff000001", "000000000000000000000000000000000000000000000000c25a7a419abf7915", "000000000000000000000000000000000000000000000000fffffff6fff80009", "0000000000000000000000000000000000000000000000002dad88a7e103e8e0", "0000000000000000000000000000000000000000000000007fffffff00000001", "0000000000000000000000000000000000000000000000008cf9ab4cd2c2ded2", "000000000000000000000000000000000000000000000000fbffffff00000401", "00000000000000000000000000000000000000000000000058b8c3f0293babf9", "0000000000000000000000000000000000000000000000000000000000000040", "000000000000000000000000000000000000000000000000de450f68832a5951", "0000000000000000000000000000000000000000000000000002000000000002", "000000000000000000000000000000000000000000000000fa37f493a39e07c0", "0000000000000000000000000000000000000000000000000000200000000000", "000000000000000000000000000000000000000000000000b7b45cc0dd784b50", "000000000000000000000000000000000000000000000000010000ffff000000", "000000000000000000000000000000000000000000000000eafe29d0e405b5b2", "000000000000000000000000000000000000000000000000000ffffffff00000", "0000000000000000000000000000000000000000000000009654086e25d19f36", "00000000000000000000000000000000000000000000000000007fff7fff8000", "00000000000000000000000000000000000000000000000081efc17180eb1719", "000000000000000000000000000000000000000000000000fffffffef8000001", "00000000000000000000000000000000000000000000000012d3d212d5fbc8a2", "000000000000000000000000000000000000000000000000ffffffbeffc00041", "0000000000000000000000000000000000000000000000006d6c4540081f46ff", "000000000000000000000000000000000000000000000000fffffffb00000005", "00000000000000000000000000000000000000000000000067cd5a6a9616f68c", "000000000000000000000000000000000000000000000000dfffffff00002001", "000000000000000000000000000000000000000000000000c5c61f8349dd5fc6", "0000000000000000000000000000000000000000000000000000000000000200", "000000000000000000000000000000000000000000000000f2287b4a1952ca82", "0000000000000000000000000000000000000000000000000010000000000010", "000000000000000000000000000000000000000000000000d1bfa4a41cf03df9", "0000000000000000000000000000000000000000000000000001000000000000", "000000000000000000000000000000000000000000000000bda2e60bebc25a7b", "000000000000000000000000000000000000000000000000080007fff8000000", "00000000000000000000000000000000000000000000000057f14e8e202dad89", "000000000000000000000000000000000000000000000000007fffffff800000", "000000000000000000000000000000000000000000000000b2a043752e8cf9ac", "0000000000000000000000000000000000000000000000000003fffbfffc0000", "0000000000000000000000000000000000000000000000000f7e0b900758b8c4", "000000000000000000000000000000000000000000000000fffffffec0000001", "000000000000000000000000000000000000000000000000969e9096afde4510", "000000000000000000000000000000000000000000000000fffffdfefe000201", "0000000000000000000000000000000000000000000000006b622a0340fa37f5", "000000000000000000000000000000000000000000000000ffffffdf00000021", "0000000000000000000000000000000000000000000000003e6ad357b0b7b45d", "000000000000000000000000000000000000000000000000fffffffe00010002", "0000000000000000000000000000000000000000000000002e30fc204eeafe2a", "0000000000000000000000000000000000000000000000000000000000001000", "0000000000000000000000000000000000000000000000009143da57ca965409", "0000000000000000000000000000000000000000000000000080000000000080", "0000000000000000000000000000000000000000000000008dfd2526e781efc2", "0000000000000000000000000000000000000000000000000008000000000000", "000000000000000000000000000000000000000000000000ed1730645e12d3d3", "00000000000000000000000000000000000000000000000040003fffc0000000", "000000000000000000000000000000000000000000000000bf8a7473016d6c46", "00000000000000000000000000000000000000000000000003fffffffc000000", "00000000000000000000000000000000000000000000000095021bae7467cd5b", "000000000000000000000000000000000000000000000000001fffdfffe00000", "0000000000000000000000000000000000000000000000007bf05c803ac5c620", "000000000000000000000000000000000000000000000000fffffffd00000001", "000000000000000000000000000000000000000000000000b4f484b97ef2287c", "000000000000000000000000000000000000000000000000ffffeffef0001001", "0000000000000000000000000000000000000000000000005b11501d07d1bfa5", "000000000000000000000000000000000000000000000000fffffeff00000101", "000000000000000000000000000000000000000000000000f3569abe85bda2e7", "000000000000000000000000000000000000000000000000fffffff700080009", "0000000000000000000000000000000000000000000000007187e1037757f14f", "0000000000000000000000000000000000000000000000000000000000008000", "0000000000000000000000000000000000000000000000008a1ed2c254b2a044", "0000000000000000000000000000000000000000000000000400000000000400", "0000000000000000000000000000000000000000000000006fe9293b3c0f7e0c", "0000000000000000000000000000000000000000000000000040000000000000", "00000000000000000000000000000000000000000000000068b98329f0969e91", "0000000000000000000000000000000000000000000000000001fffffffffffe", "000000000000000000000000000000000000000000000000fc53a39d0b6b622b", "0000000000000000000000000000000000000000000000001fffffffe0000000", "000000000000000000000000000000000000000000000000a810dd77a33e6ad4", "00000000000000000000000000000000000000000000000000fffeffff000000", "000000000000000000000000000000000000000000000000df82e404d62e30fd", "000000000000000000000000000000000000000000000000ffffffef00000001", "000000000000000000000000000000000000000000000000a7a425d0f79143db", "000000000000000000000000000000000000000000000000ffff7ffe80008001", "000000000000000000000000000000000000000000000000d88a80ea3e8dfd26", "000000000000000000000000000000000000000000000000fffff7ff00000801", "0000000000000000000000000000000000000000000000009ab4d5fb2ded1731", "000000000000000000000000000000000000000000000000ffffffbf00400041", "0000000000000000000000000000000000000000000000008c3f081ebabf8a75", "0000000000000000000000000000000000000000000000000000000000040000", "00000000000000000000000000000000000000000000000050f69616a595021c", "0000000000000000000000000000000000000000000000002000000000002000", "0000000000000000000000000000000000000000000000007f4949dce07bf05d", "0000000000000000000000000000000000000000000000000200000000000000", "00000000000000000000000000000000000000000000000045cc195284b4f485", "000000000000000000000000000000000000000000000000000ffffffffffff0", "000000000000000000000000000000000000000000000000e29d1cef5b5b1151", "000000000000000000000000000000000000000000000000ffffffff00000000", "0000000000000000000000000000000000000000000000004086ebc219f3569b", "00000000000000000000000000000000000000000000000007fff7fff8000000", "000000000000000000000000000000000000000000000000fc17202cb17187e2", "000000000000000000000000000000000000000000000000ffffff7f00000001", "0000000000000000000000000000000000000000000000003d212e8cbc8a1ed3", "000000000000000000000000000000000000000000000000fffbfffb00040001", "000000000000000000000000000000000000000000000000c4540757f46fe92a", "000000000000000000000000000000000000000000000000ffffbfff00004001", "000000000000000000000000000000000000000000000000d5a6afdd6f68b984", "000000000000000000000000000000000000000000000000fffffdff02000201", "00000000000000000000000000000000000000000000000061f840f9d5fc53a4", "0000000000000000000000000000000000000000000000000000000000200000", "00000000000000000000000000000000000000000000000087b4b0b72ca810de", "000000000000000000000000000000000000000000000000000000010000ffff", "000000000000000000000000000000000000000000000000fa4a4eea03df82e5", "0000000000000000000000000000000000000000000000001000000000000000", "0000000000000000000000000000000000000000000000002e60ca9625a7a426", "000000000000000000000000000000000000000000000000007fffffffffff80", "00000000000000000000000000000000000000000000000014e8e781dad88a81", "000000000000000000000000000000000000000000000000fffffffefffffff9", "00000000000000000000000000000000000000000000000004375e12cf9ab4d6", "0000000000000000000000000000000000000000000000003fffbfffc0000000", "000000000000000000000000000000000000000000000000e0b9016c8b8c3f09", "000000000000000000000000000000000000000000000000fffffbff00000001", "000000000000000000000000000000000000000000000000e9097466e450f697", "000000000000000000000000000000000000000000000000ffdfffdf00200001", "00000000000000000000000000000000000000000000000022a03ac5a37f494a", "000000000000000000000000000000000000000000000000fffdffff00020001", "000000000000000000000000000000000000000000000000ad357ef17b45cc1a", "000000000000000000000000000000000000000000000000ffffefff10001001", "0000000000000000000000000000000000000000000000000fc207d1afe29d1d", "0000000000000000000000000000000000000000000000000000000001000000", "0000000000000000000000000000000000000000000000003da585bd654086ec", "000000000000000000000000000000000000000000000000000000080007fff8", "000000000000000000000000000000000000000000000000d25277571efc1721", "0000000000000000000000000000000000000000000000008000000000000000", "000000000000000000000000000000000000000000000000730654b22d3d212f", "00000000000000000000000000000000000000000000000003fffffffffffc00", "000000000000000000000000000000000000000000000000a7473c0ed6c45408", "000000000000000000000000000000000000000000000000fffffffeffffffc1", "00000000000000000000000000000000000000000000000021baf0967cd5a6b0", "000000000000000000000000000000000000000000000000fffdfffeffffffff", "00000000000000000000000000000000000000000000000005c80b6b5c61f841", "000000000000000000000000000000000000000000000000ffffdfff00000001", "000000000000000000000000000000000000000000000000484ba33e2287b4b1", "000000000000000000000000000000000000000000000000fefffeff01000001", "0000000000000000000000000000000000000000000000001501d62e1bfa4a4f", "000000000000000000000000000000000000000000000000ffefffff00100001", "00000000000000000000000000000000000000000000000069abf790da2e60cb", "000000000000000000000000000000000000000000000000ffff7fff80008001", "0000000000000000000000000000000000000000000000007e103e8d7f14e8e8", "0000000000000000000000000000000000000000000000000000000008000000", "000000000000000000000000000000000000000000000000ed2c2dec2a04375f", "00000000000000000000000000000000000000000000000000000040003fffc0", "0000000000000000000000000000000000000000000000009293babef7e0b902", "00000000000000000000000000000000000000000000000000000003fffffffc", "0000000000000000000000000000000000000000000000009832a59469e90975", "0000000000000000000000000000000000000000000000001fffffffffffe000", "0000000000000000000000000000000000000000000000003a39e07bb622a03b", "000000000000000000000000000000000000000000000000fffffffefffffe01", "0000000000000000000000000000000000000000000000000dd784b4e6ad357f", "000000000000000000000000000000000000000000000000ffeffffefffffff1", "0000000000000000000000000000000000000000000000002e405b5ae30fc208", "000000000000000000000000000000000000000000000000fffeffff00000001", "000000000000000000000000000000000000000000000000425d19f3143da586", "000000000000000000000000000000000000000000000000f7fff7ff08000001", "000000000000000000000000000000000000000000000000a80eb170dfd25278", "000000000000000000000000000000000000000000000000ff7fffff00800001", "0000000000000000000000000000000000000000000000004d5fbc89d1730655", "000000000000000000000000000000000000000000000000fffc000300040001", "000000000000000000000000000000000000000000000000f081f46ef8a7473d", "0000000000000000000000000000000000000000000000000000000040000000", "00000000000000000000000000000000000000000000000069616f685021baf1", "0000000000000000000000000000000000000000000000000000020001fffe00", "000000000000000000000000000000000000000000000000949dd5fbbf05c80c", "0000000000000000000000000000000000000000000000000000001fffffffe0", "000000000000000000000000000000000000000000000000c1952ca74f484ba4", "00000000000000000000000000000000000000000000000000000000fffeffff", "000000000000000000000000000000000000000000000000d1cf03deb11501d7", "000000000000000000000000000000000000000000000000fffffffefffff001", "0000000000000000000000000000000000000000000000006ebc25a73569abf8", "000000000000000000000000000000000000000000000000ff7ffffeffffff81", "0000000000000000000000000000000000000000000000007202dad8187e103f", "000000000000000000000000000000000000000000000000fff7ffff00000001", "00000000000000000000000000000000000000000000000012e8cf9aa1ed2c2e", "000000000000000000000000000000000000000000000000bfffbfff40000001", "00000000000000000000000000000000000000000000000040758b8bfe9293bb", "000000000000000000000000000000000000000000000000fbffffff04000001", "0000000000000000000000000000000000000000000000006afde4508b9832a6", "000000000000000000000000000000000000000000000000ffe0001f00200001", "000000000000000000000000000000000000000000000000840fa37ec53a39e1", "0000000000000000000000000000000000000000000000000000000200000000", "0000000000000000000000000000000000000000000000004b0b7b45810dd785", "000000000000000000000000000000000000000000000000000010000ffff000", "000000000000000000000000000000000000000000000000a4eeafe1f82e405c", "000000000000000000000000000000000000000000000000000000ffffffff00", "0000000000000000000000000000000000000000000000000ca965407a425d1a", "00000000000000000000000000000000000000000000000000000007fff7fff8", "0000000000000000000000000000000000000000000000008e781efb88a80eb2", "000000000000000000000000000000000000000000000000fffffffeffff8001", "00000000000000000000000000000000000000000000000075e12d3cab4d5fbd", "000000000000000000000000000000000000000000000000fbfffffefffffc01", "0000000000000000000000000000000000000000000000009016d6c3c3f081f5", "000000000000000000000000000000000000000000000000ffbfffff00000001", "00000000000000000000000000000000000000000000000097467cd50f696170", "000000000000000000000000000000000000000000000000fffdffff00000003", "00000000000000000000000000000000000000000000000003ac5c61f4949dd6", "000000000000000000000000000000000000000000000000dfffffff20000001", "00000000000000000000000000000000000000000000000057ef22875cc1952d", "000000000000000000000000000000000000000000000000ff0000ff01000001", "000000000000000000000000000000000000000000000000207d1bfa29d1cf04", "0000000000000000000000000000000000000000000000000000001000000000", "000000000000000000000000000000000000000000000000585bda2e086ebc26", "000000000000000000000000000000000000000000000000000080007fff8000", "00000000000000000000000000000000000000000000000027757f14c17202db", "000000000000000000000000000000000000000000000000000007fffffff800", "000000000000000000000000000000000000000000000000654b2a03d212e8d0", "0000000000000000000000000000000000000000000000000000003fffbfffc0", "00000000000000000000000000000000000000000000000073c0f7e04540758c", "000000000000000000000000000000000000000000000000fffffffefffc0001", "000000000000000000000000000000000000000000000000af0969e85a6afde5", "000000000000000000000000000000000000000000000000dffffffeffffe001", "00000000000000000000000000000000000000000000000080b6b6221f840fa4", "000000000000000000000000000000000000000000000000fdffffff00000001", "000000000000000000000000000000000000000000000000ba33e6ac7b4b0b7c", "000000000000000000000000000000000000000000000000ffefffff00000011", "0000000000000000000000000000000000000000000000001d62e30fa4a4eeb0" } },
    .{ .name = "the M31 torus domain", .kind = .torus, .base = .m31, .log_n = 8, .hex = &.{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000075d723f1", "0000000000000000000000000000000000000000000000000000000008761508", "0000000000000000000000000000000000000000000000000000000034ad0061", "000000000000000000000000000000000000000000000000000000006b1818f1", "0000000000000000000000000000000000000000000000000000000033e97024", "0000000000000000000000000000000000000000000000000000000025b8d56c", "00000000000000000000000000000000000000000000000000000000018f3dc5", "000000000000000000000000000000000000000000000000000000001e21f8ac", "000000000000000000000000000000000000000000000000000000003c71d5c5", "00000000000000000000000000000000000000000000000000000000009fcc12", "000000000000000000000000000000000000000000000000000000007f6a684d", "000000000000000000000000000000000000000000000000000000007beb6773", "00000000000000000000000000000000000000000000000000000000405c70e7", "00000000000000000000000000000000000000000000000000000000743755fa", "000000000000000000000000000000000000000000000000000000003604adb7", "0000000000000000000000000000000000000000000000000000000039aea997", "000000000000000000000000000000000000000000000000000000002ecacf47", "0000000000000000000000000000000000000000000000000000000034da7782", "000000000000000000000000000000000000000000000000000000003ded0e7c", "000000000000000000000000000000000000000000000000000000007800f33e", "0000000000000000000000000000000000000000000000000000000059cde7cf", "000000000000000000000000000000000000000000000000000000001a8b9a7e", "000000000000000000000000000000000000000000000000000000005e304d2e", "000000000000000000000000000000000000000000000000000000000b9ad44f", "000000000000000000000000000000000000000000000000000000000eeee90e", "000000000000000000000000000000000000000000000000000000007d15cb05", "00000000000000000000000000000000000000000000000000000000705f4834", "0000000000000000000000000000000000000000000000000000000067a71bb6", "000000000000000000000000000000000000000000000000000000003075300c", "0000000000000000000000000000000000000000000000000000000003ae13e7", "000000000000000000000000000000000000000000000000000000005cc9971d", "000000000000000000000000000000000000000000000000000000003a542275", "0000000000000000000000000000000000000000000000000000000021f9b423", "000000000000000000000000000000000000000000000000000000000e12acc7", "0000000000000000000000000000000000000000000000000000000031f5d806", "00000000000000000000000000000000000000000000000000000000163f08b8", "000000000000000000000000000000000000000000000000000000005a0a0c04", "000000000000000000000000000000000000000000000000000000000f0411d9", "0000000000000000000000000000000000000000000000000000000010bee9cb", "000000000000000000000000000000000000000000000000000000003c6fd295", "000000000000000000000000000000000000000000000000000000004126f459", "0000000000000000000000000000000000000000000000000000000026a8bf42", "0000000000000000000000000000000000000000000000000000000000ddb5ee", "000000000000000000000000000000000000000000000000000000000d9ec5ec", "000000000000000000000000000000000000000000000000000000002364e3a5", "000000000000000000000000000000000000000000000000000000002be279f0", "000000000000000000000000000000000000000000000000000000002ba76fb3", "00000000000000000000000000000000000000000000000000000000020ffc56", "0000000000000000000000000000000000000000000000000000000063713493", "000000000000000000000000000000000000000000000000000000000d764c25", "0000000000000000000000000000000000000000000000000000000067e0fb55", "00000000000000000000000000000000000000000000000000000000006d037f", "0000000000000000000000000000000000000000000000000000000050ebbd11", "0000000000000000000000000000000000000000000000000000000004d9bbd2", "000000000000000000000000000000000000000000000000000000001b389fb1", "00000000000000000000000000000000000000000000000000000000228c636d", "0000000000000000000000000000000000000000000000000000000022c859a2", "000000000000000000000000000000000000000000000000000000004d5c0e30", "000000000000000000000000000000000000000000000000000000000ca99fc5", "0000000000000000000000000000000000000000000000000000000073b7c994", "000000000000000000000000000000000000000000000000000000001c7cfe4d", "000000000000000000000000000000000000000000000000000000000774ed61", "0000000000000000000000000000000000000000000000000000000000008000", "0000000000000000000000000000000000000000000000000000000000008000", "000000000000000000000000000000000000000000000000000000000774ed61", "000000000000000000000000000000000000000000000000000000001c7cfe4d", "0000000000000000000000000000000000000000000000000000000073b7c994", "000000000000000000000000000000000000000000000000000000000ca99fc5", "000000000000000000000000000000000000000000000000000000004d5c0e30", "0000000000000000000000000000000000000000000000000000000022c859a2", "00000000000000000000000000000000000000000000000000000000228c636d", "000000000000000000000000000000000000000000000000000000001b389fb1", "0000000000000000000000000000000000000000000000000000000004d9bbd2", "0000000000000000000000000000000000000000000000000000000050ebbd11", "00000000000000000000000000000000000000000000000000000000006d037f", "0000000000000000000000000000000000000000000000000000000067e0fb55", "000000000000000000000000000000000000000000000000000000000d764c25", "0000000000000000000000000000000000000000000000000000000063713493", "00000000000000000000000000000000000000000000000000000000020ffc56", "000000000000000000000000000000000000000000000000000000002ba76fb3", "000000000000000000000000000000000000000000000000000000002be279f0", "000000000000000000000000000000000000000000000000000000002364e3a5", "000000000000000000000000000000000000000000000000000000000d9ec5ec", "0000000000000000000000000000000000000000000000000000000000ddb5ee", "0000000000000000000000000000000000000000000000000000000026a8bf42", "000000000000000000000000000000000000000000000000000000004126f459", "000000000000000000000000000000000000000000000000000000003c6fd295", "0000000000000000000000000000000000000000000000000000000010bee9cb", "000000000000000000000000000000000000000000000000000000000f0411d9", "000000000000000000000000000000000000000000000000000000005a0a0c04", "00000000000000000000000000000000000000000000000000000000163f08b8", "0000000000000000000000000000000000000000000000000000000031f5d806", "000000000000000000000000000000000000000000000000000000000e12acc7", "0000000000000000000000000000000000000000000000000000000021f9b423", "000000000000000000000000000000000000000000000000000000003a542275", "000000000000000000000000000000000000000000000000000000005cc9971d", "0000000000000000000000000000000000000000000000000000000003ae13e7", "000000000000000000000000000000000000000000000000000000003075300c", "0000000000000000000000000000000000000000000000000000000067a71bb6", "00000000000000000000000000000000000000000000000000000000705f4834", "000000000000000000000000000000000000000000000000000000007d15cb05", "000000000000000000000000000000000000000000000000000000000eeee90e", "000000000000000000000000000000000000000000000000000000000b9ad44f", "000000000000000000000000000000000000000000000000000000005e304d2e", "000000000000000000000000000000000000000000000000000000001a8b9a7e", "0000000000000000000000000000000000000000000000000000000059cde7cf", "000000000000000000000000000000000000000000000000000000007800f33e", "000000000000000000000000000000000000000000000000000000003ded0e7c", "0000000000000000000000000000000000000000000000000000000034da7782", "000000000000000000000000000000000000000000000000000000002ecacf47", "0000000000000000000000000000000000000000000000000000000039aea997", "000000000000000000000000000000000000000000000000000000003604adb7", "00000000000000000000000000000000000000000000000000000000743755fa", "00000000000000000000000000000000000000000000000000000000405c70e7", "000000000000000000000000000000000000000000000000000000007beb6773", "000000000000000000000000000000000000000000000000000000007f6a684d", "00000000000000000000000000000000000000000000000000000000009fcc12", "000000000000000000000000000000000000000000000000000000003c71d5c5", "000000000000000000000000000000000000000000000000000000001e21f8ac", "00000000000000000000000000000000000000000000000000000000018f3dc5", "0000000000000000000000000000000000000000000000000000000025b8d56c", "0000000000000000000000000000000000000000000000000000000033e97024", "000000000000000000000000000000000000000000000000000000006b1818f1", "0000000000000000000000000000000000000000000000000000000034ad0061", "0000000000000000000000000000000000000000000000000000000008761508", "0000000000000000000000000000000000000000000000000000000075d723f1", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000001", "000000000000000000000000000000000000000000000000000000007789eaf7", "0000000000000000000000000000000000000000000000000000000075d723f1", "0000000000000000000000000000000000000000000000000000000014e7e70e", "0000000000000000000000000000000000000000000000000000000034ad0061", "000000000000000000000000000000000000000000000000000000005a472a93", "0000000000000000000000000000000000000000000000000000000033e97024", "0000000000000000000000000000000000000000000000000000000061de0753", "00000000000000000000000000000000000000000000000000000000018f3dc5", "000000000000000000000000000000000000000000000000000000007f6033ed", "000000000000000000000000000000000000000000000000000000003c71d5c5", "000000000000000000000000000000000000000000000000000000000414988c", "000000000000000000000000000000000000000000000000000000007f6a684d", "000000000000000000000000000000000000000000000000000000000bc8aa05", "00000000000000000000000000000000000000000000000000000000405c70e7", "0000000000000000000000000000000000000000000000000000000046515668", "000000000000000000000000000000000000000000000000000000003604adb7", "000000000000000000000000000000000000000000000000000000004b25887d", "000000000000000000000000000000000000000000000000000000002ecacf47", "0000000000000000000000000000000000000000000000000000000007ff0cc1", "000000000000000000000000000000000000000000000000000000003ded0e7c", "0000000000000000000000000000000000000000000000000000000065746581", "0000000000000000000000000000000000000000000000000000000059cde7cf", "0000000000000000000000000000000000000000000000000000000074652bb0", "000000000000000000000000000000000000000000000000000000005e304d2e", "0000000000000000000000000000000000000000000000000000000002ea34fa", "000000000000000000000000000000000000000000000000000000000eeee90e", "000000000000000000000000000000000000000000000000000000001858e449", "00000000000000000000000000000000000000000000000000000000705f4834", "000000000000000000000000000000000000000000000000000000007c51ec18", "000000000000000000000000000000000000000000000000000000003075300c", "0000000000000000000000000000000000000000000000000000000045abdd8a", "000000000000000000000000000000000000000000000000000000005cc9971d", "0000000000000000000000000000000000000000000000000000000071ed5338", "0000000000000000000000000000000000000000000000000000000021f9b423", "0000000000000000000000000000000000000000000000000000000069c0f747", "0000000000000000000000000000000000000000000000000000000031f5d806", "0000000000000000000000000000000000000000000000000000000070fbee26", "000000000000000000000000000000000000000000000000000000005a0a0c04", "0000000000000000000000000000000000000000000000000000000043902d6a", "0000000000000000000000000000000000000000000000000000000010bee9cb", "00000000000000000000000000000000000000000000000000000000595740bd", "000000000000000000000000000000000000000000000000000000004126f459", "0000000000000000000000000000000000000000000000000000000072613a13", "0000000000000000000000000000000000000000000000000000000000ddb5ee", "00000000000000000000000000000000000000000000000000000000541d860f", "000000000000000000000000000000000000000000000000000000002364e3a5", "000000000000000000000000000000000000000000000000000000007df003a9", "000000000000000000000000000000000000000000000000000000002ba76fb3", "000000000000000000000000000000000000000000000000000000007289b3da", "0000000000000000000000000000000000000000000000000000000063713493", "000000000000000000000000000000000000000000000000000000007f92fc80", "0000000000000000000000000000000000000000000000000000000067e0fb55", "000000000000000000000000000000000000000000000000000000007b26442d", "0000000000000000000000000000000000000000000000000000000050ebbd11", "000000000000000000000000000000000000000000000000000000005d739c92", "000000000000000000000000000000000000000000000000000000001b389fb1", "0000000000000000000000000000000000000000000000000000000032a3f1cf", "0000000000000000000000000000000000000000000000000000000022c859a2", "000000000000000000000000000000000000000000000000000000000c48366b", "000000000000000000000000000000000000000000000000000000000ca99fc5", "00000000000000000000000000000000000000000000000000000000788b129e", "000000000000000000000000000000000000000000000000000000001c7cfe4d", "000000000000000000000000000000000000000000000000000000007fff7fff", "0000000000000000000000000000000000000000000000000000000000008000", "00000000000000000000000000000000000000000000000000000000638301b2", "000000000000000000000000000000000000000000000000000000000774ed61", "000000000000000000000000000000000000000000000000000000007356603a", "0000000000000000000000000000000000000000000000000000000073b7c994", "000000000000000000000000000000000000000000000000000000005d37a65d", "000000000000000000000000000000000000000000000000000000004d5c0e30", "0000000000000000000000000000000000000000000000000000000064c7604e", "00000000000000000000000000000000000000000000000000000000228c636d", "000000000000000000000000000000000000000000000000000000002f1442ee", "0000000000000000000000000000000000000000000000000000000004d9bbd2", "00000000000000000000000000000000000000000000000000000000181f04aa", "00000000000000000000000000000000000000000000000000000000006d037f", "000000000000000000000000000000000000000000000000000000001c8ecb6c", "000000000000000000000000000000000000000000000000000000000d764c25", "000000000000000000000000000000000000000000000000000000005458904c", "00000000000000000000000000000000000000000000000000000000020ffc56", "000000000000000000000000000000000000000000000000000000005c9b1c5a", "000000000000000000000000000000000000000000000000000000002be279f0", "000000000000000000000000000000000000000000000000000000007f224a11", "000000000000000000000000000000000000000000000000000000000d9ec5ec", "000000000000000000000000000000000000000000000000000000003ed90ba6", "0000000000000000000000000000000000000000000000000000000026a8bf42", "000000000000000000000000000000000000000000000000000000006f411634", "000000000000000000000000000000000000000000000000000000003c6fd295", "0000000000000000000000000000000000000000000000000000000025f5f3fb", "000000000000000000000000000000000000000000000000000000000f0411d9", "000000000000000000000000000000000000000000000000000000004e0a27f9", "00000000000000000000000000000000000000000000000000000000163f08b8", "000000000000000000000000000000000000000000000000000000005e064bdc", "000000000000000000000000000000000000000000000000000000000e12acc7", "00000000000000000000000000000000000000000000000000000000233668e2", "000000000000000000000000000000000000000000000000000000003a542275", "000000000000000000000000000000000000000000000000000000004f8acff3", "0000000000000000000000000000000000000000000000000000000003ae13e7", "000000000000000000000000000000000000000000000000000000000fa0b7cb", "0000000000000000000000000000000000000000000000000000000067a71bb6", "00000000000000000000000000000000000000000000000000000000711116f1", "000000000000000000000000000000000000000000000000000000007d15cb05", "0000000000000000000000000000000000000000000000000000000021cfb2d1", "000000000000000000000000000000000000000000000000000000000b9ad44f", "0000000000000000000000000000000000000000000000000000000026321830", "000000000000000000000000000000000000000000000000000000001a8b9a7e", "000000000000000000000000000000000000000000000000000000004212f183", "000000000000000000000000000000000000000000000000000000007800f33e", "00000000000000000000000000000000000000000000000000000000513530b8", "0000000000000000000000000000000000000000000000000000000034da7782", "0000000000000000000000000000000000000000000000000000000049fb5248", "0000000000000000000000000000000000000000000000000000000039aea997", "000000000000000000000000000000000000000000000000000000003fa38f18", "00000000000000000000000000000000000000000000000000000000743755fa", "00000000000000000000000000000000000000000000000000000000009597b2", "000000000000000000000000000000000000000000000000000000007beb6773", "00000000000000000000000000000000000000000000000000000000438e2a3a", "00000000000000000000000000000000000000000000000000000000009fcc12", "000000000000000000000000000000000000000000000000000000007e70c23a", "000000000000000000000000000000000000000000000000000000001e21f8ac", "000000000000000000000000000000000000000000000000000000004c168fdb", "0000000000000000000000000000000000000000000000000000000025b8d56c", "000000000000000000000000000000000000000000000000000000004b52ff9e", "000000000000000000000000000000000000000000000000000000006b1818f1", "000000000000000000000000000000000000000000000000000000000a28dc0e", "0000000000000000000000000000000000000000000000000000000008761508", "000000000000000000000000000000000000000000000000000000007ffffffe", "0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000000000000a28dc0e", "000000000000000000000000000000000000000000000000000000007789eaf7", "000000000000000000000000000000000000000000000000000000004b52ff9e", "0000000000000000000000000000000000000000000000000000000014e7e70e", "000000000000000000000000000000000000000000000000000000004c168fdb", "000000000000000000000000000000000000000000000000000000005a472a93", "000000000000000000000000000000000000000000000000000000007e70c23a", "0000000000000000000000000000000000000000000000000000000061de0753", "00000000000000000000000000000000000000000000000000000000438e2a3a", "000000000000000000000000000000000000000000000000000000007f6033ed", "00000000000000000000000000000000000000000000000000000000009597b2", "000000000000000000000000000000000000000000000000000000000414988c", "000000000000000000000000000000000000000000000000000000003fa38f18", "000000000000000000000000000000000000000000000000000000000bc8aa05", "0000000000000000000000000000000000000000000000000000000049fb5248", "0000000000000000000000000000000000000000000000000000000046515668", "00000000000000000000000000000000000000000000000000000000513530b8", "000000000000000000000000000000000000000000000000000000004b25887d", "000000000000000000000000000000000000000000000000000000004212f183", "0000000000000000000000000000000000000000000000000000000007ff0cc1", "0000000000000000000000000000000000000000000000000000000026321830", "0000000000000000000000000000000000000000000000000000000065746581", "0000000000000000000000000000000000000000000000000000000021cfb2d1", "0000000000000000000000000000000000000000000000000000000074652bb0", "00000000000000000000000000000000000000000000000000000000711116f1", "0000000000000000000000000000000000000000000000000000000002ea34fa", "000000000000000000000000000000000000000000000000000000000fa0b7cb", "000000000000000000000000000000000000000000000000000000001858e449", "000000000000000000000000000000000000000000000000000000004f8acff3", "000000000000000000000000000000000000000000000000000000007c51ec18", "00000000000000000000000000000000000000000000000000000000233668e2", "0000000000000000000000000000000000000000000000000000000045abdd8a", "000000000000000000000000000000000000000000000000000000005e064bdc", "0000000000000000000000000000000000000000000000000000000071ed5338", "000000000000000000000000000000000000000000000000000000004e0a27f9", "0000000000000000000000000000000000000000000000000000000069c0f747", "0000000000000000000000000000000000000000000000000000000025f5f3fb", "0000000000000000000000000000000000000000000000000000000070fbee26", "000000000000000000000000000000000000000000000000000000006f411634", "0000000000000000000000000000000000000000000000000000000043902d6a", "000000000000000000000000000000000000000000000000000000003ed90ba6", "00000000000000000000000000000000000000000000000000000000595740bd", "000000000000000000000000000000000000000000000000000000007f224a11", "0000000000000000000000000000000000000000000000000000000072613a13", "000000000000000000000000000000000000000000000000000000005c9b1c5a", "00000000000000000000000000000000000000000000000000000000541d860f", "000000000000000000000000000000000000000000000000000000005458904c", "000000000000000000000000000000000000000000000000000000007df003a9", "000000000000000000000000000000000000000000000000000000001c8ecb6c", "000000000000000000000000000000000000000000000000000000007289b3da", "00000000000000000000000000000000000000000000000000000000181f04aa", "000000000000000000000000000000000000000000000000000000007f92fc80", "000000000000000000000000000000000000000000000000000000002f1442ee", "000000000000000000000000000000000000000000000000000000007b26442d", "0000000000000000000000000000000000000000000000000000000064c7604e", "000000000000000000000000000000000000000000000000000000005d739c92", "000000000000000000000000000000000000000000000000000000005d37a65d", "0000000000000000000000000000000000000000000000000000000032a3f1cf", "000000000000000000000000000000000000000000000000000000007356603a", "000000000000000000000000000000000000000000000000000000000c48366b", "00000000000000000000000000000000000000000000000000000000638301b2", "00000000000000000000000000000000000000000000000000000000788b129e", "000000000000000000000000000000000000000000000000000000007fff7fff", "000000000000000000000000000000000000000000000000000000007fff7fff", "00000000000000000000000000000000000000000000000000000000788b129e", "00000000000000000000000000000000000000000000000000000000638301b2", "000000000000000000000000000000000000000000000000000000000c48366b", "000000000000000000000000000000000000000000000000000000007356603a", "0000000000000000000000000000000000000000000000000000000032a3f1cf", "000000000000000000000000000000000000000000000000000000005d37a65d", "000000000000000000000000000000000000000000000000000000005d739c92", "0000000000000000000000000000000000000000000000000000000064c7604e", "000000000000000000000000000000000000000000000000000000007b26442d", "000000000000000000000000000000000000000000000000000000002f1442ee", "000000000000000000000000000000000000000000000000000000007f92fc80", "00000000000000000000000000000000000000000000000000000000181f04aa", "000000000000000000000000000000000000000000000000000000007289b3da", "000000000000000000000000000000000000000000000000000000001c8ecb6c", "000000000000000000000000000000000000000000000000000000007df003a9", "000000000000000000000000000000000000000000000000000000005458904c", "00000000000000000000000000000000000000000000000000000000541d860f", "000000000000000000000000000000000000000000000000000000005c9b1c5a", "0000000000000000000000000000000000000000000000000000000072613a13", "000000000000000000000000000000000000000000000000000000007f224a11", "00000000000000000000000000000000000000000000000000000000595740bd", "000000000000000000000000000000000000000000000000000000003ed90ba6", "0000000000000000000000000000000000000000000000000000000043902d6a", "000000000000000000000000000000000000000000000000000000006f411634", "0000000000000000000000000000000000000000000000000000000070fbee26", "0000000000000000000000000000000000000000000000000000000025f5f3fb", "0000000000000000000000000000000000000000000000000000000069c0f747", "000000000000000000000000000000000000000000000000000000004e0a27f9", "0000000000000000000000000000000000000000000000000000000071ed5338", "000000000000000000000000000000000000000000000000000000005e064bdc", "0000000000000000000000000000000000000000000000000000000045abdd8a", "00000000000000000000000000000000000000000000000000000000233668e2", "000000000000000000000000000000000000000000000000000000007c51ec18", "000000000000000000000000000000000000000000000000000000004f8acff3", "000000000000000000000000000000000000000000000000000000001858e449", "000000000000000000000000000000000000000000000000000000000fa0b7cb", "0000000000000000000000000000000000000000000000000000000002ea34fa", "00000000000000000000000000000000000000000000000000000000711116f1", "0000000000000000000000000000000000000000000000000000000074652bb0", "0000000000000000000000000000000000000000000000000000000021cfb2d1", "0000000000000000000000000000000000000000000000000000000065746581", "0000000000000000000000000000000000000000000000000000000026321830", "0000000000000000000000000000000000000000000000000000000007ff0cc1", "000000000000000000000000000000000000000000000000000000004212f183", "000000000000000000000000000000000000000000000000000000004b25887d", "00000000000000000000000000000000000000000000000000000000513530b8", "0000000000000000000000000000000000000000000000000000000046515668", "0000000000000000000000000000000000000000000000000000000049fb5248", "000000000000000000000000000000000000000000000000000000000bc8aa05", "000000000000000000000000000000000000000000000000000000003fa38f18", "000000000000000000000000000000000000000000000000000000000414988c", "00000000000000000000000000000000000000000000000000000000009597b2", "000000000000000000000000000000000000000000000000000000007f6033ed", "00000000000000000000000000000000000000000000000000000000438e2a3a", "0000000000000000000000000000000000000000000000000000000061de0753", "000000000000000000000000000000000000000000000000000000007e70c23a", "000000000000000000000000000000000000000000000000000000005a472a93", "000000000000000000000000000000000000000000000000000000004c168fdb", "0000000000000000000000000000000000000000000000000000000014e7e70e", "000000000000000000000000000000000000000000000000000000004b52ff9e", "000000000000000000000000000000000000000000000000000000007789eaf7", "000000000000000000000000000000000000000000000000000000000a28dc0e", "0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000000000007ffffffe", "0000000000000000000000000000000000000000000000000000000008761508", "000000000000000000000000000000000000000000000000000000000a28dc0e", "000000000000000000000000000000000000000000000000000000006b1818f1", "000000000000000000000000000000000000000000000000000000004b52ff9e", "0000000000000000000000000000000000000000000000000000000025b8d56c", "000000000000000000000000000000000000000000000000000000004c168fdb", "000000000000000000000000000000000000000000000000000000001e21f8ac", "000000000000000000000000000000000000000000000000000000007e70c23a", "00000000000000000000000000000000000000000000000000000000009fcc12", "00000000000000000000000000000000000000000000000000000000438e2a3a", "000000000000000000000000000000000000000000000000000000007beb6773", "00000000000000000000000000000000000000000000000000000000009597b2", "00000000000000000000000000000000000000000000000000000000743755fa", "000000000000000000000000000000000000000000000000000000003fa38f18", "0000000000000000000000000000000000000000000000000000000039aea997", "0000000000000000000000000000000000000000000000000000000049fb5248", "0000000000000000000000000000000000000000000000000000000034da7782", "00000000000000000000000000000000000000000000000000000000513530b8", "000000000000000000000000000000000000000000000000000000007800f33e", "000000000000000000000000000000000000000000000000000000004212f183", "000000000000000000000000000000000000000000000000000000001a8b9a7e", "0000000000000000000000000000000000000000000000000000000026321830", "000000000000000000000000000000000000000000000000000000000b9ad44f", "0000000000000000000000000000000000000000000000000000000021cfb2d1", "000000000000000000000000000000000000000000000000000000007d15cb05", "00000000000000000000000000000000000000000000000000000000711116f1", "0000000000000000000000000000000000000000000000000000000067a71bb6", "000000000000000000000000000000000000000000000000000000000fa0b7cb", "0000000000000000000000000000000000000000000000000000000003ae13e7", "000000000000000000000000000000000000000000000000000000004f8acff3", "000000000000000000000000000000000000000000000000000000003a542275", "00000000000000000000000000000000000000000000000000000000233668e2", "000000000000000000000000000000000000000000000000000000000e12acc7", "000000000000000000000000000000000000000000000000000000005e064bdc", "00000000000000000000000000000000000000000000000000000000163f08b8", "000000000000000000000000000000000000000000000000000000004e0a27f9", "000000000000000000000000000000000000000000000000000000000f0411d9", "0000000000000000000000000000000000000000000000000000000025f5f3fb", "000000000000000000000000000000000000000000000000000000003c6fd295", "000000000000000000000000000000000000000000000000000000006f411634", "0000000000000000000000000000000000000000000000000000000026a8bf42", "000000000000000000000000000000000000000000000000000000003ed90ba6", "000000000000000000000000000000000000000000000000000000000d9ec5ec", "000000000000000000000000000000000000000000000000000000007f224a11", "000000000000000000000000000000000000000000000000000000002be279f0", "000000000000000000000000000000000000000000000000000000005c9b1c5a", "00000000000000000000000000000000000000000000000000000000020ffc56", "000000000000000000000000000000000000000000000000000000005458904c", "000000000000000000000000000000000000000000000000000000000d764c25", "000000000000000000000000000000000000000000000000000000001c8ecb6c", "00000000000000000000000000000000000000000000000000000000006d037f", "00000000000000000000000000000000000000000000000000000000181f04aa", "0000000000000000000000000000000000000000000000000000000004d9bbd2", "000000000000000000000000000000000000000000000000000000002f1442ee", "00000000000000000000000000000000000000000000000000000000228c636d", "0000000000000000000000000000000000000000000000000000000064c7604e", "000000000000000000000000000000000000000000000000000000004d5c0e30", "000000000000000000000000000000000000000000000000000000005d37a65d", "0000000000000000000000000000000000000000000000000000000073b7c994", "000000000000000000000000000000000000000000000000000000007356603a", "000000000000000000000000000000000000000000000000000000000774ed61", "00000000000000000000000000000000000000000000000000000000638301b2", "0000000000000000000000000000000000000000000000000000000000008000", "000000000000000000000000000000000000000000000000000000007fff7fff", "000000000000000000000000000000000000000000000000000000001c7cfe4d", "00000000000000000000000000000000000000000000000000000000788b129e", "000000000000000000000000000000000000000000000000000000000ca99fc5", "000000000000000000000000000000000000000000000000000000000c48366b", "0000000000000000000000000000000000000000000000000000000022c859a2", "0000000000000000000000000000000000000000000000000000000032a3f1cf", "000000000000000000000000000000000000000000000000000000001b389fb1", "000000000000000000000000000000000000000000000000000000005d739c92", "0000000000000000000000000000000000000000000000000000000050ebbd11", "000000000000000000000000000000000000000000000000000000007b26442d", "0000000000000000000000000000000000000000000000000000000067e0fb55", "000000000000000000000000000000000000000000000000000000007f92fc80", "0000000000000000000000000000000000000000000000000000000063713493", "000000000000000000000000000000000000000000000000000000007289b3da", "000000000000000000000000000000000000000000000000000000002ba76fb3", "000000000000000000000000000000000000000000000000000000007df003a9", "000000000000000000000000000000000000000000000000000000002364e3a5", "00000000000000000000000000000000000000000000000000000000541d860f", "0000000000000000000000000000000000000000000000000000000000ddb5ee", "0000000000000000000000000000000000000000000000000000000072613a13", "000000000000000000000000000000000000000000000000000000004126f459", "00000000000000000000000000000000000000000000000000000000595740bd", "0000000000000000000000000000000000000000000000000000000010bee9cb", "0000000000000000000000000000000000000000000000000000000043902d6a", "000000000000000000000000000000000000000000000000000000005a0a0c04", "0000000000000000000000000000000000000000000000000000000070fbee26", "0000000000000000000000000000000000000000000000000000000031f5d806", "0000000000000000000000000000000000000000000000000000000069c0f747", "0000000000000000000000000000000000000000000000000000000021f9b423", "0000000000000000000000000000000000000000000000000000000071ed5338", "000000000000000000000000000000000000000000000000000000005cc9971d", "0000000000000000000000000000000000000000000000000000000045abdd8a", "000000000000000000000000000000000000000000000000000000003075300c", "000000000000000000000000000000000000000000000000000000007c51ec18", "00000000000000000000000000000000000000000000000000000000705f4834", "000000000000000000000000000000000000000000000000000000001858e449", "000000000000000000000000000000000000000000000000000000000eeee90e", "0000000000000000000000000000000000000000000000000000000002ea34fa", "000000000000000000000000000000000000000000000000000000005e304d2e", "0000000000000000000000000000000000000000000000000000000074652bb0", "0000000000000000000000000000000000000000000000000000000059cde7cf", "0000000000000000000000000000000000000000000000000000000065746581", "000000000000000000000000000000000000000000000000000000003ded0e7c", "0000000000000000000000000000000000000000000000000000000007ff0cc1", "000000000000000000000000000000000000000000000000000000002ecacf47", "000000000000000000000000000000000000000000000000000000004b25887d", "000000000000000000000000000000000000000000000000000000003604adb7", "0000000000000000000000000000000000000000000000000000000046515668", "00000000000000000000000000000000000000000000000000000000405c70e7", "000000000000000000000000000000000000000000000000000000000bc8aa05", "000000000000000000000000000000000000000000000000000000007f6a684d", "000000000000000000000000000000000000000000000000000000000414988c", "000000000000000000000000000000000000000000000000000000003c71d5c5", "000000000000000000000000000000000000000000000000000000007f6033ed", "00000000000000000000000000000000000000000000000000000000018f3dc5", "0000000000000000000000000000000000000000000000000000000061de0753", "0000000000000000000000000000000000000000000000000000000033e97024", "000000000000000000000000000000000000000000000000000000005a472a93", "0000000000000000000000000000000000000000000000000000000034ad0061", "0000000000000000000000000000000000000000000000000000000014e7e70e", "0000000000000000000000000000000000000000000000000000000075d723f1", "000000000000000000000000000000000000000000000000000000007789eaf7" } },
    .{ .name = "the M61 torus domain", .kind = .torus, .base = .m61, .log_n = 8, .hex = &.{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000fc05dbea891b9fa", "00000000000000000000000000000000000000000000000001a56401c207aabf", "00000000000000000000000000000000000000000000000006604cda29bebdf4", "00000000000000000000000000000000000000000000000011c8cc42d5c47bdb", "00000000000000000000000000000000000000000000000012c2df4677759cae", "00000000000000000000000000000000000000000000000003b13afa545c9c4a", "0000000000000000000000000000000000000000000000001170924ca0ac8bc3", "0000000000000000000000000000000000000000000000000b919e2a8630d5df", "0000000000000000000000000000000000000000000000000b9473288f7e96a9", "0000000000000000000000000000000000000000000000000f625a8b6d473b9f", "0000000000000000000000000000000000000000000000001b7e7d85db38096d", "0000000000000000000000000000000000000000000000000f773852571e011b", "0000000000000000000000000000000000000000000000001cd8636af22fb526", "000000000000000000000000000000000000000000000000138db1c3174f93ef", "00000000000000000000000000000000000000000000000009ad6477f49aa8fe", "0000000000000000000000000000000000000000000000000127f5081dad7767", "00000000000000000000000000000000000000000000000004d59808619cc64d", "0000000000000000000000000000000000000000000000000ca957120ce04208", "00000000000000000000000000000000000000000000000001e4ab205a9121bb", "0000000000000000000000000000000000000000000000000219ed4f63e81678", "00000000000000000000000000000000000000000000000004ef8ddb75a4afe6", "00000000000000000000000000000000000000000000000000ecccd35c906912", "000000000000000000000000000000000000000000000000142522edd4eb645a", "00000000000000000000000000000000000000000000000007f82a8c3fcef77c", "000000000000000000000000000000000000000000000000141becc470f3b1f9", "00000000000000000000000000000000000000000000000004c4db3cfce2b179", "00000000000000000000000000000000000000000000000009b81024b935c54e", "00000000000000000000000000000000000000000000000012056d2a41b2111d", "0000000000000000000000000000000000000000000000000b260522b9e3abc3", "0000000000000000000000000000000000000000000000000db1ca8403fafe8c", "000000000000000000000000000000000000000000000000177fdf85ee633b8d", "0000000000000000000000000000000000000000000000001fb1be40ef9c4289", "0000000000000000000000000000000000000000000000000f77aa93f1af9f4d", "0000000000000000000000000000000000000000000000000d7a2b4dbae8753d", "0000000000000000000000000000000000000000000000001eb9f59af77afa9d", "0000000000000000000000000000000000000000000000001de0ed0c2f6545f4", "0000000000000000000000000000000000000000000000001b7598dcb1c19002", "0000000000000000000000000000000000000000000000001d0440201eae230e", "000000000000000000000000000000000000000000000000052e96f5b83a9af4", "00000000000000000000000000000000000000000000000005471b379859f0c3", "000000000000000000000000000000000000000000000000148d463e0bb8b55d", "000000000000000000000000000000000000000000000000064511b508058210", "0000000000000000000000000000000000000000000000000f9e4e0cc7fd30df", "0000000000000000000000000000000000000000000000001daa42d0bf957ba1", "0000000000000000000000000000000000000000000000001b9f421562fdde34", "000000000000000000000000000000000000000000000000152f2111305881ec", "0000000000000000000000000000000000000000000000000492081955aab300", "00000000000000000000000000000000000000000000000015bb4c65d10adedf", "000000000000000000000000000000000000000000000000025fd245a0cc2a5c", "00000000000000000000000000000000000000000000000016b8084dd295634f", "0000000000000000000000000000000000000000000000000c9582a255eb6bb0", "00000000000000000000000000000000000000000000000001068214980e8a67", "0000000000000000000000000000000000000000000000001f31749235ed9b67", "000000000000000000000000000000000000000000000000088dd6c27864313a", "00000000000000000000000000000000000000000000000009b75868ba0460ee", "000000000000000000000000000000000000000000000000069eed790bbde844", "00000000000000000000000000000000000000000000000012f48e3e2ce83481", "00000000000000000000000000000000000000000000000008c640191e234898", "0000000000000000000000000000000000000000000000001fe0ce73f0523239", "00000000000000000000000000000000000000000000000014fe9086292f012e", "0000000000000000000000000000000000000000000000001aa6592e62cb8380", "00000000000000000000000000000000000000000000000019a283cedc35f379", "0000000000000000000000000000000000000000000000000000000040000000", "0000000000000000000000000000000000000000000000000000000040000000", "00000000000000000000000000000000000000000000000019a283cedc35f379", "0000000000000000000000000000000000000000000000001aa6592e62cb8380", "00000000000000000000000000000000000000000000000014fe9086292f012e", "0000000000000000000000000000000000000000000000001fe0ce73f0523239", "00000000000000000000000000000000000000000000000008c640191e234898", "00000000000000000000000000000000000000000000000012f48e3e2ce83481", "000000000000000000000000000000000000000000000000069eed790bbde844", "00000000000000000000000000000000000000000000000009b75868ba0460ee", "000000000000000000000000000000000000000000000000088dd6c27864313a", "0000000000000000000000000000000000000000000000001f31749235ed9b67", "00000000000000000000000000000000000000000000000001068214980e8a67", "0000000000000000000000000000000000000000000000000c9582a255eb6bb0", "00000000000000000000000000000000000000000000000016b8084dd295634f", "000000000000000000000000000000000000000000000000025fd245a0cc2a5c", "00000000000000000000000000000000000000000000000015bb4c65d10adedf", "0000000000000000000000000000000000000000000000000492081955aab300", "000000000000000000000000000000000000000000000000152f2111305881ec", "0000000000000000000000000000000000000000000000001b9f421562fdde34", "0000000000000000000000000000000000000000000000001daa42d0bf957ba1", "0000000000000000000000000000000000000000000000000f9e4e0cc7fd30df", "000000000000000000000000000000000000000000000000064511b508058210", "000000000000000000000000000000000000000000000000148d463e0bb8b55d", "00000000000000000000000000000000000000000000000005471b379859f0c3", "000000000000000000000000000000000000000000000000052e96f5b83a9af4", "0000000000000000000000000000000000000000000000001d0440201eae230e", "0000000000000000000000000000000000000000000000001b7598dcb1c19002", "0000000000000000000000000000000000000000000000001de0ed0c2f6545f4", "0000000000000000000000000000000000000000000000001eb9f59af77afa9d", "0000000000000000000000000000000000000000000000000d7a2b4dbae8753d", "0000000000000000000000000000000000000000000000000f77aa93f1af9f4d", "0000000000000000000000000000000000000000000000001fb1be40ef9c4289", "000000000000000000000000000000000000000000000000177fdf85ee633b8d", "0000000000000000000000000000000000000000000000000db1ca8403fafe8c", "0000000000000000000000000000000000000000000000000b260522b9e3abc3", "00000000000000000000000000000000000000000000000012056d2a41b2111d", "00000000000000000000000000000000000000000000000009b81024b935c54e", "00000000000000000000000000000000000000000000000004c4db3cfce2b179", "000000000000000000000000000000000000000000000000141becc470f3b1f9", "00000000000000000000000000000000000000000000000007f82a8c3fcef77c", "000000000000000000000000000000000000000000000000142522edd4eb645a", "00000000000000000000000000000000000000000000000000ecccd35c906912", "00000000000000000000000000000000000000000000000004ef8ddb75a4afe6", "0000000000000000000000000000000000000000000000000219ed4f63e81678", "00000000000000000000000000000000000000000000000001e4ab205a9121bb", "0000000000000000000000000000000000000000000000000ca957120ce04208", "00000000000000000000000000000000000000000000000004d59808619cc64d", "0000000000000000000000000000000000000000000000000127f5081dad7767", "00000000000000000000000000000000000000000000000009ad6477f49aa8fe", "000000000000000000000000000000000000000000000000138db1c3174f93ef", "0000000000000000000000000000000000000000000000001cd8636af22fb526", "0000000000000000000000000000000000000000000000000f773852571e011b", "0000000000000000000000000000000000000000000000001b7e7d85db38096d", "0000000000000000000000000000000000000000000000000f625a8b6d473b9f", "0000000000000000000000000000000000000000000000000b9473288f7e96a9", "0000000000000000000000000000000000000000000000000b919e2a8630d5df", "0000000000000000000000000000000000000000000000001170924ca0ac8bc3", "00000000000000000000000000000000000000000000000003b13afa545c9c4a", "00000000000000000000000000000000000000000000000012c2df4677759cae", "00000000000000000000000000000000000000000000000011c8cc42d5c47bdb", "00000000000000000000000000000000000000000000000006604cda29bebdf4", "00000000000000000000000000000000000000000000000001a56401c207aabf", "0000000000000000000000000000000000000000000000000fc05dbea891b9fa", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000001e5a9bfe3df85540", "0000000000000000000000000000000000000000000000000fc05dbea891b9fa", "0000000000000000000000000000000000000000000000000e3733bd2a3b8424", "00000000000000000000000000000000000000000000000006604cda29bebdf4", "0000000000000000000000000000000000000000000000001c4ec505aba363b5", "00000000000000000000000000000000000000000000000012c2df4677759cae", "000000000000000000000000000000000000000000000000146e61d579cf2a20", "0000000000000000000000000000000000000000000000001170924ca0ac8bc3", "000000000000000000000000000000000000000000000000109da57492b8c460", "0000000000000000000000000000000000000000000000000b9473288f7e96a9", "0000000000000000000000000000000000000000000000001088c7ada8e1fee4", "0000000000000000000000000000000000000000000000001b7e7d85db38096d", "0000000000000000000000000000000000000000000000000c724e3ce8b06c10", "0000000000000000000000000000000000000000000000001cd8636af22fb526", "0000000000000000000000000000000000000000000000001ed80af7e2528898", "00000000000000000000000000000000000000000000000009ad6477f49aa8fe", "0000000000000000000000000000000000000000000000001356a8edf31fbdf7", "00000000000000000000000000000000000000000000000004d59808619cc64d", "0000000000000000000000000000000000000000000000001de612b09c17e987", "00000000000000000000000000000000000000000000000001e4ab205a9121bb", "0000000000000000000000000000000000000000000000001f13332ca36f96ed", "00000000000000000000000000000000000000000000000004ef8ddb75a4afe6", "0000000000000000000000000000000000000000000000001807d573c0310883", "000000000000000000000000000000000000000000000000142522edd4eb645a", "0000000000000000000000000000000000000000000000001b3b24c3031d4e86", "000000000000000000000000000000000000000000000000141becc470f3b1f9", "0000000000000000000000000000000000000000000000000dfa92d5be4deee2", "00000000000000000000000000000000000000000000000009b81024b935c54e", "000000000000000000000000000000000000000000000000124e357bfc050173", "0000000000000000000000000000000000000000000000000b260522b9e3abc3", "000000000000000000000000000000000000000000000000004e41bf1063bd76", "000000000000000000000000000000000000000000000000177fdf85ee633b8d", "0000000000000000000000000000000000000000000000001285d4b245178ac2", "0000000000000000000000000000000000000000000000000f77aa93f1af9f4d", "000000000000000000000000000000000000000000000000021f12f3d09aba0b", "0000000000000000000000000000000000000000000000001eb9f59af77afa9d", "00000000000000000000000000000000000000000000000002fbbfdfe151dcf1", "0000000000000000000000000000000000000000000000001b7598dcb1c19002", "0000000000000000000000000000000000000000000000001ab8e4c867a60f3c", "000000000000000000000000000000000000000000000000052e96f5b83a9af4", "00000000000000000000000000000000000000000000000019baee4af7fa7def", "000000000000000000000000000000000000000000000000148d463e0bb8b55d", "0000000000000000000000000000000000000000000000000255bd2f406a845e", "0000000000000000000000000000000000000000000000000f9e4e0cc7fd30df", "0000000000000000000000000000000000000000000000000ad0deeecfa77e13", "0000000000000000000000000000000000000000000000001b9f421562fdde34", "0000000000000000000000000000000000000000000000000a44b39a2ef52120", "0000000000000000000000000000000000000000000000000492081955aab300", "0000000000000000000000000000000000000000000000000947f7b22d6a9cb0", "000000000000000000000000000000000000000000000000025fd245a0cc2a5c", "0000000000000000000000000000000000000000000000001ef97deb67f17598", "0000000000000000000000000000000000000000000000000c9582a255eb6bb0", "0000000000000000000000000000000000000000000000001772293d879bcec5", "0000000000000000000000000000000000000000000000001f31749235ed9b67", "00000000000000000000000000000000000000000000000019611286f44217bb", "00000000000000000000000000000000000000000000000009b75868ba0460ee", "0000000000000000000000000000000000000000000000001739bfe6e1dcb767", "00000000000000000000000000000000000000000000000012f48e3e2ce83481", "0000000000000000000000000000000000000000000000000b016f79d6d0fed1", "0000000000000000000000000000000000000000000000001fe0ce73f0523239", "000000000000000000000000000000000000000000000000065d7c3123ca0c86", "0000000000000000000000000000000000000000000000001aa6592e62cb8380", "0000000000000000000000000000000000000000000000001fffffffbfffffff", "0000000000000000000000000000000000000000000000000000000040000000", "0000000000000000000000000000000000000000000000000559a6d19d347c7f", "00000000000000000000000000000000000000000000000019a283cedc35f379", "000000000000000000000000000000000000000000000000001f318c0fadcdc6", "00000000000000000000000000000000000000000000000014fe9086292f012e", "0000000000000000000000000000000000000000000000000d0b71c1d317cb7e", "00000000000000000000000000000000000000000000000008c640191e234898", "0000000000000000000000000000000000000000000000001648a79745fb9f11", "000000000000000000000000000000000000000000000000069eed790bbde844", "00000000000000000000000000000000000000000000000000ce8b6dca126498", "000000000000000000000000000000000000000000000000088dd6c27864313a", "000000000000000000000000000000000000000000000000136a7d5daa14944f", "00000000000000000000000000000000000000000000000001068214980e8a67", "0000000000000000000000000000000000000000000000001da02dba5f33d5a3", "00000000000000000000000000000000000000000000000016b8084dd295634f", "0000000000000000000000000000000000000000000000001b6df7e6aa554cff", "00000000000000000000000000000000000000000000000015bb4c65d10adedf", "0000000000000000000000000000000000000000000000000460bdea9d0221cb", "000000000000000000000000000000000000000000000000152f2111305881ec", "0000000000000000000000000000000000000000000000001061b1f33802cf20", "0000000000000000000000000000000000000000000000001daa42d0bf957ba1", "0000000000000000000000000000000000000000000000000b72b9c1f4474aa2", "000000000000000000000000000000000000000000000000064511b508058210", "0000000000000000000000000000000000000000000000001ad1690a47c5650b", "00000000000000000000000000000000000000000000000005471b379859f0c3", "000000000000000000000000000000000000000000000000048a67234e3e6ffd", "0000000000000000000000000000000000000000000000001d0440201eae230e", "00000000000000000000000000000000000000000000000001460a6508850562", "0000000000000000000000000000000000000000000000001de0ed0c2f6545f4", "0000000000000000000000000000000000000000000000001088556c0e5060b2", "0000000000000000000000000000000000000000000000000d7a2b4dbae8753d", "0000000000000000000000000000000000000000000000000880207a119cc472", "0000000000000000000000000000000000000000000000001fb1be40ef9c4289", "00000000000000000000000000000000000000000000000014d9fadd461c543c", "0000000000000000000000000000000000000000000000000db1ca8403fafe8c", "0000000000000000000000000000000000000000000000001647efdb46ca3ab1", "00000000000000000000000000000000000000000000000012056d2a41b2111d", "0000000000000000000000000000000000000000000000000be4133b8f0c4e06", "00000000000000000000000000000000000000000000000004c4db3cfce2b179", "0000000000000000000000000000000000000000000000000bdadd122b149ba5", "00000000000000000000000000000000000000000000000007f82a8c3fcef77c", "0000000000000000000000000000000000000000000000001b1072248a5b5019", "00000000000000000000000000000000000000000000000000ecccd35c906912", "0000000000000000000000000000000000000000000000001e1b54dfa56ede44", "0000000000000000000000000000000000000000000000000219ed4f63e81678", "0000000000000000000000000000000000000000000000001b2a67f79e6339b2", "0000000000000000000000000000000000000000000000000ca957120ce04208", "00000000000000000000000000000000000000000000000016529b880b655701", "0000000000000000000000000000000000000000000000000127f5081dad7767", "00000000000000000000000000000000000000000000000003279c950dd04ad9", "000000000000000000000000000000000000000000000000138db1c3174f93ef", "0000000000000000000000000000000000000000000000000481827a24c7f692", "0000000000000000000000000000000000000000000000000f773852571e011b", "000000000000000000000000000000000000000000000000146b8cd770816956", "0000000000000000000000000000000000000000000000000f625a8b6d473b9f", "0000000000000000000000000000000000000000000000000e8f6db35f53743c", "0000000000000000000000000000000000000000000000000b919e2a8630d5df", "0000000000000000000000000000000000000000000000000d3d20b9888a6351", "00000000000000000000000000000000000000000000000003b13afa545c9c4a", "000000000000000000000000000000000000000000000000199fb325d641420b", "00000000000000000000000000000000000000000000000011c8cc42d5c47bdb", "000000000000000000000000000000000000000000000000103fa241576e4605", "00000000000000000000000000000000000000000000000001a56401c207aabf", "0000000000000000000000000000000000000000000000001ffffffffffffffe", "0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000000000000000000000000000103fa241576e4605", "0000000000000000000000000000000000000000000000001e5a9bfe3df85540", "000000000000000000000000000000000000000000000000199fb325d641420b", "0000000000000000000000000000000000000000000000000e3733bd2a3b8424", "0000000000000000000000000000000000000000000000000d3d20b9888a6351", "0000000000000000000000000000000000000000000000001c4ec505aba363b5", "0000000000000000000000000000000000000000000000000e8f6db35f53743c", "000000000000000000000000000000000000000000000000146e61d579cf2a20", "000000000000000000000000000000000000000000000000146b8cd770816956", "000000000000000000000000000000000000000000000000109da57492b8c460", "0000000000000000000000000000000000000000000000000481827a24c7f692", "0000000000000000000000000000000000000000000000001088c7ada8e1fee4", "00000000000000000000000000000000000000000000000003279c950dd04ad9", "0000000000000000000000000000000000000000000000000c724e3ce8b06c10", "00000000000000000000000000000000000000000000000016529b880b655701", "0000000000000000000000000000000000000000000000001ed80af7e2528898", "0000000000000000000000000000000000000000000000001b2a67f79e6339b2", "0000000000000000000000000000000000000000000000001356a8edf31fbdf7", "0000000000000000000000000000000000000000000000001e1b54dfa56ede44", "0000000000000000000000000000000000000000000000001de612b09c17e987", "0000000000000000000000000000000000000000000000001b1072248a5b5019", "0000000000000000000000000000000000000000000000001f13332ca36f96ed", "0000000000000000000000000000000000000000000000000bdadd122b149ba5", "0000000000000000000000000000000000000000000000001807d573c0310883", "0000000000000000000000000000000000000000000000000be4133b8f0c4e06", "0000000000000000000000000000000000000000000000001b3b24c3031d4e86", "0000000000000000000000000000000000000000000000001647efdb46ca3ab1", "0000000000000000000000000000000000000000000000000dfa92d5be4deee2", "00000000000000000000000000000000000000000000000014d9fadd461c543c", "000000000000000000000000000000000000000000000000124e357bfc050173", "0000000000000000000000000000000000000000000000000880207a119cc472", "000000000000000000000000000000000000000000000000004e41bf1063bd76", "0000000000000000000000000000000000000000000000001088556c0e5060b2", "0000000000000000000000000000000000000000000000001285d4b245178ac2", "00000000000000000000000000000000000000000000000001460a6508850562", "000000000000000000000000000000000000000000000000021f12f3d09aba0b", "000000000000000000000000000000000000000000000000048a67234e3e6ffd", "00000000000000000000000000000000000000000000000002fbbfdfe151dcf1", "0000000000000000000000000000000000000000000000001ad1690a47c5650b", "0000000000000000000000000000000000000000000000001ab8e4c867a60f3c", "0000000000000000000000000000000000000000000000000b72b9c1f4474aa2", "00000000000000000000000000000000000000000000000019baee4af7fa7def", "0000000000000000000000000000000000000000000000001061b1f33802cf20", "0000000000000000000000000000000000000000000000000255bd2f406a845e", "0000000000000000000000000000000000000000000000000460bdea9d0221cb", "0000000000000000000000000000000000000000000000000ad0deeecfa77e13", "0000000000000000000000000000000000000000000000001b6df7e6aa554cff", "0000000000000000000000000000000000000000000000000a44b39a2ef52120", "0000000000000000000000000000000000000000000000001da02dba5f33d5a3", "0000000000000000000000000000000000000000000000000947f7b22d6a9cb0", "000000000000000000000000000000000000000000000000136a7d5daa14944f", "0000000000000000000000000000000000000000000000001ef97deb67f17598", "00000000000000000000000000000000000000000000000000ce8b6dca126498", "0000000000000000000000000000000000000000000000001772293d879bcec5", "0000000000000000000000000000000000000000000000001648a79745fb9f11", "00000000000000000000000000000000000000000000000019611286f44217bb", "0000000000000000000000000000000000000000000000000d0b71c1d317cb7e", "0000000000000000000000000000000000000000000000001739bfe6e1dcb767", "000000000000000000000000000000000000000000000000001f318c0fadcdc6", "0000000000000000000000000000000000000000000000000b016f79d6d0fed1", "0000000000000000000000000000000000000000000000000559a6d19d347c7f", "000000000000000000000000000000000000000000000000065d7c3123ca0c86", "0000000000000000000000000000000000000000000000001fffffffbfffffff", "0000000000000000000000000000000000000000000000001fffffffbfffffff", "000000000000000000000000000000000000000000000000065d7c3123ca0c86", "0000000000000000000000000000000000000000000000000559a6d19d347c7f", "0000000000000000000000000000000000000000000000000b016f79d6d0fed1", "000000000000000000000000000000000000000000000000001f318c0fadcdc6", "0000000000000000000000000000000000000000000000001739bfe6e1dcb767", "0000000000000000000000000000000000000000000000000d0b71c1d317cb7e", "00000000000000000000000000000000000000000000000019611286f44217bb", "0000000000000000000000000000000000000000000000001648a79745fb9f11", "0000000000000000000000000000000000000000000000001772293d879bcec5", "00000000000000000000000000000000000000000000000000ce8b6dca126498", "0000000000000000000000000000000000000000000000001ef97deb67f17598", "000000000000000000000000000000000000000000000000136a7d5daa14944f", "0000000000000000000000000000000000000000000000000947f7b22d6a9cb0", "0000000000000000000000000000000000000000000000001da02dba5f33d5a3", "0000000000000000000000000000000000000000000000000a44b39a2ef52120", "0000000000000000000000000000000000000000000000001b6df7e6aa554cff", "0000000000000000000000000000000000000000000000000ad0deeecfa77e13", "0000000000000000000000000000000000000000000000000460bdea9d0221cb", "0000000000000000000000000000000000000000000000000255bd2f406a845e", "0000000000000000000000000000000000000000000000001061b1f33802cf20", "00000000000000000000000000000000000000000000000019baee4af7fa7def", "0000000000000000000000000000000000000000000000000b72b9c1f4474aa2", "0000000000000000000000000000000000000000000000001ab8e4c867a60f3c", "0000000000000000000000000000000000000000000000001ad1690a47c5650b", "00000000000000000000000000000000000000000000000002fbbfdfe151dcf1", "000000000000000000000000000000000000000000000000048a67234e3e6ffd", "000000000000000000000000000000000000000000000000021f12f3d09aba0b", "00000000000000000000000000000000000000000000000001460a6508850562", "0000000000000000000000000000000000000000000000001285d4b245178ac2", "0000000000000000000000000000000000000000000000001088556c0e5060b2", "000000000000000000000000000000000000000000000000004e41bf1063bd76", "0000000000000000000000000000000000000000000000000880207a119cc472", "000000000000000000000000000000000000000000000000124e357bfc050173", "00000000000000000000000000000000000000000000000014d9fadd461c543c", "0000000000000000000000000000000000000000000000000dfa92d5be4deee2", "0000000000000000000000000000000000000000000000001647efdb46ca3ab1", "0000000000000000000000000000000000000000000000001b3b24c3031d4e86", "0000000000000000000000000000000000000000000000000be4133b8f0c4e06", "0000000000000000000000000000000000000000000000001807d573c0310883", "0000000000000000000000000000000000000000000000000bdadd122b149ba5", "0000000000000000000000000000000000000000000000001f13332ca36f96ed", "0000000000000000000000000000000000000000000000001b1072248a5b5019", "0000000000000000000000000000000000000000000000001de612b09c17e987", "0000000000000000000000000000000000000000000000001e1b54dfa56ede44", "0000000000000000000000000000000000000000000000001356a8edf31fbdf7", "0000000000000000000000000000000000000000000000001b2a67f79e6339b2", "0000000000000000000000000000000000000000000000001ed80af7e2528898", "00000000000000000000000000000000000000000000000016529b880b655701", "0000000000000000000000000000000000000000000000000c724e3ce8b06c10", "00000000000000000000000000000000000000000000000003279c950dd04ad9", "0000000000000000000000000000000000000000000000001088c7ada8e1fee4", "0000000000000000000000000000000000000000000000000481827a24c7f692", "000000000000000000000000000000000000000000000000109da57492b8c460", "000000000000000000000000000000000000000000000000146b8cd770816956", "000000000000000000000000000000000000000000000000146e61d579cf2a20", "0000000000000000000000000000000000000000000000000e8f6db35f53743c", "0000000000000000000000000000000000000000000000001c4ec505aba363b5", "0000000000000000000000000000000000000000000000000d3d20b9888a6351", "0000000000000000000000000000000000000000000000000e3733bd2a3b8424", "000000000000000000000000000000000000000000000000199fb325d641420b", "0000000000000000000000000000000000000000000000001e5a9bfe3df85540", "000000000000000000000000000000000000000000000000103fa241576e4605", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000001ffffffffffffffe", "00000000000000000000000000000000000000000000000001a56401c207aabf", "000000000000000000000000000000000000000000000000103fa241576e4605", "00000000000000000000000000000000000000000000000011c8cc42d5c47bdb", "000000000000000000000000000000000000000000000000199fb325d641420b", "00000000000000000000000000000000000000000000000003b13afa545c9c4a", "0000000000000000000000000000000000000000000000000d3d20b9888a6351", "0000000000000000000000000000000000000000000000000b919e2a8630d5df", "0000000000000000000000000000000000000000000000000e8f6db35f53743c", "0000000000000000000000000000000000000000000000000f625a8b6d473b9f", "000000000000000000000000000000000000000000000000146b8cd770816956", "0000000000000000000000000000000000000000000000000f773852571e011b", "0000000000000000000000000000000000000000000000000481827a24c7f692", "000000000000000000000000000000000000000000000000138db1c3174f93ef", "00000000000000000000000000000000000000000000000003279c950dd04ad9", "0000000000000000000000000000000000000000000000000127f5081dad7767", "00000000000000000000000000000000000000000000000016529b880b655701", "0000000000000000000000000000000000000000000000000ca957120ce04208", "0000000000000000000000000000000000000000000000001b2a67f79e6339b2", "0000000000000000000000000000000000000000000000000219ed4f63e81678", "0000000000000000000000000000000000000000000000001e1b54dfa56ede44", "00000000000000000000000000000000000000000000000000ecccd35c906912", "0000000000000000000000000000000000000000000000001b1072248a5b5019", "00000000000000000000000000000000000000000000000007f82a8c3fcef77c", "0000000000000000000000000000000000000000000000000bdadd122b149ba5", "00000000000000000000000000000000000000000000000004c4db3cfce2b179", "0000000000000000000000000000000000000000000000000be4133b8f0c4e06", "00000000000000000000000000000000000000000000000012056d2a41b2111d", "0000000000000000000000000000000000000000000000001647efdb46ca3ab1", "0000000000000000000000000000000000000000000000000db1ca8403fafe8c", "00000000000000000000000000000000000000000000000014d9fadd461c543c", "0000000000000000000000000000000000000000000000001fb1be40ef9c4289", "0000000000000000000000000000000000000000000000000880207a119cc472", "0000000000000000000000000000000000000000000000000d7a2b4dbae8753d", "0000000000000000000000000000000000000000000000001088556c0e5060b2", "0000000000000000000000000000000000000000000000001de0ed0c2f6545f4", "00000000000000000000000000000000000000000000000001460a6508850562", "0000000000000000000000000000000000000000000000001d0440201eae230e", "000000000000000000000000000000000000000000000000048a67234e3e6ffd", "00000000000000000000000000000000000000000000000005471b379859f0c3", "0000000000000000000000000000000000000000000000001ad1690a47c5650b", "000000000000000000000000000000000000000000000000064511b508058210", "0000000000000000000000000000000000000000000000000b72b9c1f4474aa2", "0000000000000000000000000000000000000000000000001daa42d0bf957ba1", "0000000000000000000000000000000000000000000000001061b1f33802cf20", "000000000000000000000000000000000000000000000000152f2111305881ec", "0000000000000000000000000000000000000000000000000460bdea9d0221cb", "00000000000000000000000000000000000000000000000015bb4c65d10adedf", "0000000000000000000000000000000000000000000000001b6df7e6aa554cff", "00000000000000000000000000000000000000000000000016b8084dd295634f", "0000000000000000000000000000000000000000000000001da02dba5f33d5a3", "00000000000000000000000000000000000000000000000001068214980e8a67", "000000000000000000000000000000000000000000000000136a7d5daa14944f", "000000000000000000000000000000000000000000000000088dd6c27864313a", "00000000000000000000000000000000000000000000000000ce8b6dca126498", "000000000000000000000000000000000000000000000000069eed790bbde844", "0000000000000000000000000000000000000000000000001648a79745fb9f11", "00000000000000000000000000000000000000000000000008c640191e234898", "0000000000000000000000000000000000000000000000000d0b71c1d317cb7e", "00000000000000000000000000000000000000000000000014fe9086292f012e", "000000000000000000000000000000000000000000000000001f318c0fadcdc6", "00000000000000000000000000000000000000000000000019a283cedc35f379", "0000000000000000000000000000000000000000000000000559a6d19d347c7f", "0000000000000000000000000000000000000000000000000000000040000000", "0000000000000000000000000000000000000000000000001fffffffbfffffff", "0000000000000000000000000000000000000000000000001aa6592e62cb8380", "000000000000000000000000000000000000000000000000065d7c3123ca0c86", "0000000000000000000000000000000000000000000000001fe0ce73f0523239", "0000000000000000000000000000000000000000000000000b016f79d6d0fed1", "00000000000000000000000000000000000000000000000012f48e3e2ce83481", "0000000000000000000000000000000000000000000000001739bfe6e1dcb767", "00000000000000000000000000000000000000000000000009b75868ba0460ee", "00000000000000000000000000000000000000000000000019611286f44217bb", "0000000000000000000000000000000000000000000000001f31749235ed9b67", "0000000000000000000000000000000000000000000000001772293d879bcec5", "0000000000000000000000000000000000000000000000000c9582a255eb6bb0", "0000000000000000000000000000000000000000000000001ef97deb67f17598", "000000000000000000000000000000000000000000000000025fd245a0cc2a5c", "0000000000000000000000000000000000000000000000000947f7b22d6a9cb0", "0000000000000000000000000000000000000000000000000492081955aab300", "0000000000000000000000000000000000000000000000000a44b39a2ef52120", "0000000000000000000000000000000000000000000000001b9f421562fdde34", "0000000000000000000000000000000000000000000000000ad0deeecfa77e13", "0000000000000000000000000000000000000000000000000f9e4e0cc7fd30df", "0000000000000000000000000000000000000000000000000255bd2f406a845e", "000000000000000000000000000000000000000000000000148d463e0bb8b55d", "00000000000000000000000000000000000000000000000019baee4af7fa7def", "000000000000000000000000000000000000000000000000052e96f5b83a9af4", "0000000000000000000000000000000000000000000000001ab8e4c867a60f3c", "0000000000000000000000000000000000000000000000001b7598dcb1c19002", "00000000000000000000000000000000000000000000000002fbbfdfe151dcf1", "0000000000000000000000000000000000000000000000001eb9f59af77afa9d", "000000000000000000000000000000000000000000000000021f12f3d09aba0b", "0000000000000000000000000000000000000000000000000f77aa93f1af9f4d", "0000000000000000000000000000000000000000000000001285d4b245178ac2", "000000000000000000000000000000000000000000000000177fdf85ee633b8d", "000000000000000000000000000000000000000000000000004e41bf1063bd76", "0000000000000000000000000000000000000000000000000b260522b9e3abc3", "000000000000000000000000000000000000000000000000124e357bfc050173", "00000000000000000000000000000000000000000000000009b81024b935c54e", "0000000000000000000000000000000000000000000000000dfa92d5be4deee2", "000000000000000000000000000000000000000000000000141becc470f3b1f9", "0000000000000000000000000000000000000000000000001b3b24c3031d4e86", "000000000000000000000000000000000000000000000000142522edd4eb645a", "0000000000000000000000000000000000000000000000001807d573c0310883", "00000000000000000000000000000000000000000000000004ef8ddb75a4afe6", "0000000000000000000000000000000000000000000000001f13332ca36f96ed", "00000000000000000000000000000000000000000000000001e4ab205a9121bb", "0000000000000000000000000000000000000000000000001de612b09c17e987", "00000000000000000000000000000000000000000000000004d59808619cc64d", "0000000000000000000000000000000000000000000000001356a8edf31fbdf7", "00000000000000000000000000000000000000000000000009ad6477f49aa8fe", "0000000000000000000000000000000000000000000000001ed80af7e2528898", "0000000000000000000000000000000000000000000000001cd8636af22fb526", "0000000000000000000000000000000000000000000000000c724e3ce8b06c10", "0000000000000000000000000000000000000000000000001b7e7d85db38096d", "0000000000000000000000000000000000000000000000001088c7ada8e1fee4", "0000000000000000000000000000000000000000000000000b9473288f7e96a9", "000000000000000000000000000000000000000000000000109da57492b8c460", "0000000000000000000000000000000000000000000000001170924ca0ac8bc3", "000000000000000000000000000000000000000000000000146e61d579cf2a20", "00000000000000000000000000000000000000000000000012c2df4677759cae", "0000000000000000000000000000000000000000000000001c4ec505aba363b5", "00000000000000000000000000000000000000000000000006604cda29bebdf4", "0000000000000000000000000000000000000000000000000e3733bd2a3b8424", "0000000000000000000000000000000000000000000000000fc05dbea891b9fa", "0000000000000000000000000000000000000000000000001e5a9bfe3df85540" } },
};

/// Decode one 64-digit hex literal from the fixture. Run time on purpose: the
/// fixtures are data, and a comptime reader would make the whole table a
/// compile-time computation for no gain.
/// Decode one hex literal from the fixture, right-aligned: the Goldilocks
/// domain is 16 digits wide and the torus ones are 64, and both carry the same
/// value in the low 8 bytes.
fn friU64(h: []const u8, buf: []u8) !u64 {
    if (h.len < 16 or h.len % 2 != 0) return error.MalformedOracleLiteral;
    _ = std.fmt.hexToBytes(buf, h[h.len - 16 ..]) catch return error.MalformedOracleLiteral;
    return std.mem.readInt(u64, buf[0..8], .big);
}

test "fri: the torus generators are the ones the documented search names" {
    // `torusAdicity` and `findGenerator` are both documented as computed, so
    // this pins the adicity as well as the generator.
    try testing.expectEqual(@as(comptime_int, 31), torus.torusAdicity(zfield.M31));
    try testing.expectEqual(@as(comptime_int, 61), torus.torusAdicity(zfield.M61));

    const g31 = try torus.findGenerator(torus.Torus31, zfield.M31);
    try testing.expectEqual(fri_torus_generators[0].a, g31.a);
    try testing.expectEqual(fri_torus_generators[0].b, g31.b);

    const g61 = try torus.findGenerator(torus.Torus61, zfield.M61);
    try testing.expectEqual(fri_torus_generators[1].a, g61.a);
    try testing.expectEqual(fri_torus_generators[1].b, g61.b);
}

test "fri: the generator search is bounded, and the two moduli here start at t = 2 and t = 4" {
    // The bound is the load-bearing half. `findGenerator` walks candidates
    // until one has exact order 2^A, and the previous loop had no bound worth
    // the name: with `torusAdicity` returning `ctz(p - 1)` instead of
    // `ctz(p + 1)`, every candidate fails the order test and the loop runs to
    // p. What that looks like from a gate is a timeout, not a failure, which
    // is why the search now stops at `max_candidates` and returns a typed
    // error instead.
    //
    // The first `t` is measured, per modulus, and the object travels with the
    // number: t = 2 over M31 (p = 2^31 - 1) and t = 4 over M61 (p = 2^61 - 1).
    try testing.expectEqual(torus.max_candidates, @as(u64, 1) << 20);

    const g31 = try torus.findGenerator(torus.Torus31, zfield.M31);
    try testing.expectEqual(fri_torus_generators[0].a, g31.a);
    const g61 = try torus.findGenerator(torus.Torus61, zfield.M61);
    try testing.expectEqual(fri_torus_generators[1].a, g61.a);

    // Both first candidates are single digits, which is what makes the bound
    // comfortable rather than tight: t = 2 for M31 and t = 4 for M61, both
    // below a million by five orders of magnitude.
    try testing.expect(fri_torus_generators[0].a == 1717986917);
    try testing.expect(fri_torus_generators[1].a == 1627653888856725141);
}

test "fri: every domain element matches the documented construction" {
    for (fri_domains) |c| {
        switch (c.kind) {
            .base => {
                const dom = try Domain(Goldilocks).init(Goldilocks, c.log_n);
                try testing.expectEqual(@as(usize, 1) << c.log_n, dom.size());
                for (c.hex, 0..) |h, i| {
                    var buf: [8]u8 = undefined;
                    const want = try friU64(h, &buf);
                    const got = dom.at(i).toInt();
                    if (got != want) {
                        std.debug.print("dominio {s}[{d}]: fixture {d}, implementation {d}\n", .{
                            c.name, i, want, got,
                        });
                        return error.TestExpectedEqual;
                    }
                }
            },
            .torus => {
                const T31 = torus.TorusDomain(torus.Torus31, zfield.M31);
                const T61 = torus.TorusDomain(torus.Torus61, zfield.M61);
                switch (c.base) {
                    .m31 => {
                        const dom = try T31.init(torus.Torus31, c.log_n);
                        // The pairs are flattened: c0 of element 0, c1 of element 0,
                        // c0 of element 1, ...
                        for (c.hex, 0..) |h, k| {
                            var buf: [8]u8 = undefined;
                            const want = try friU64(h, &buf);
                            const got = dom.at(k / 2);
                            const seen = if (k % 2 == 0) got.c0.toInt() else got.c1.toInt();
                            if (seen != want) {
                                std.debug.print("dominio {s} elemento {d} componente {d}: fixture {d}, implementation {d}\n", .{
                                    c.name, k / 2, k % 2, want, seen,
                                });
                                return error.TestExpectedEqual;
                            }
                        }
                    },
                    .m61 => {
                        const dom = try T61.init(torus.Torus61, c.log_n);
                        for (c.hex, 0..) |h, k| {
                            var buf: [8]u8 = undefined;
                            const want = try friU64(h, &buf);
                            const got = dom.at(k / 2);
                            const seen = if (k % 2 == 0) got.c0.toInt() else got.c1.toInt();
                            if (seen != want) {
                                std.debug.print("dominio {s} elemento {d} componente {d}: fixture {d}, implementation {d}\n", .{
                                    c.name, k / 2, k % 2, want, seen,
                                });
                                return error.TestExpectedEqual;
                            }
                        }
                    },
                }
            },
        }
    }
}

test "fri: the fold does not collapse a maximum-degree input to a constant" {
    // The claim, with the object in it: over `log_domain = 8`, `log_final = 6`
    // and therefore 2 folding rounds, a polynomial of degree 31 (the largest
    // the config admits, since `log_initial_degree = 5`) leaves a residual
    // whose coefficients can be nonzero all the way up to index 7, because
    // each round halves the domain variable and floor(31 / 4) = 7.
    //
    // Two earlier versions of this test asserted the residual *was* the
    // polynomial's own coefficients, and then that it was a degree-3
    // polynomial. Both are false about FRI and both were caught by the
    // arithmetic: the fold is `p_even(x) + alpha * p_odd(x)/x`, so the child
    // is a function of `x^2`, not of `x`, and a degree-3 input becomes a
    // constant after two rounds. What survives is the property that has
    // content: a fold that dropped the odd part, or forgot the challenge,
    // would send *every* input to a constant, and a max-degree input is the
    // one that cannot hide it.
    const a = testing.allocator;
    const F = torus.Torus61;
    const Dom = torus.TorusDomain(F, zfield.M61);
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    const dom = try Dom.init(F, log_n);
    var evals = try a.alloc(F, n);
    defer a.free(evals);
    for (0..n) |i| {
        var acc = F.zero();
        var xp = F.one();
        for (0..32) |_| {
            acc = acc.add(xp);
            xp = xp.mul(dom.at(i));
        }
        evals[i] = acc;
    }

    var pt = Transcript.init("fri-fold-keeps-degree");
    var proof = try proveOn(F, Dom, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var no_constantes: usize = 0;
    for (proof.residual, 0..) |cb, i| {
        if (i == 0) continue;
        const got = try deserializeElem(F, cb);
        if (!got.isZero()) no_constantes += 1;
    }
    if (no_constantes == 0) {
        std.debug.print("el plegado envio un polinomio de grado 31 a una constante: el residual solo tiene coeficiente 0\n", .{});
        return error.TestExpectedEqual;
    }

    var vt = Transcript.init("fri-fold-keeps-degree");
    try testing.expect(try verifyOn(F, Dom, &vt, &proof, cfg));
}

test "fri: the degree anchor rejects the very next degree up" {
    // The same config, one degree above the bound: `log_initial_degree = 5`
    // admits degrees 0..31, so a degree-32 polynomial is the adjacent case and
    // the sharpest one. The input is x^32 evaluated on the domain, which is a
    // genuinely different function from every polynomial of degree below 32.
    //
    // x^(n-1) and not x^n: on a domain of order n, x^n is the constant 1 --
    // the *lowest* degree function on the domain, and an earlier version of
    // this test used it, which is why it verified.
    const a = testing.allocator;
    const F = torus.Torus61;
    const Dom = torus.TorusDomain(F, zfield.M61);
    const log_n: u6 = 8;
    const n: usize = @as(usize, 1) << log_n;
    const cfg = testConfig(log_n, 8);

    const dom = try Dom.init(F, log_n);
    var evals = try a.alloc(F, n);
    defer a.free(evals);
    for (0..n) |i| {
        var acc = F.one();
        for (0..32) |_| acc = acc.mul(dom.at(i));
        evals[i] = acc;
    }

    var pt = Transcript.init("fri-one-degree-over");
    var proof = try proveOn(F, Dom, a, &pt, evals, cfg);
    defer proof.deinit(a);

    var vt = Transcript.init("fri-one-degree-over");
    try testing.expect(!try verifyOn(F, Dom, &vt, &proof, cfg));
}
