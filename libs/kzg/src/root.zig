//! zig-kzg: Kate-Zaverucha-Goldberg polynomial commitments over BN254.
//!
//! Uses the project's verified optimal ate pairing (zig-pairing) and
//! Pippenger MSM (zig-curve). The trusted setup is SYNTHETIC — a fixed
//! tau chosen by the caller — suitable for tests and development only.
//! Production deployments require a proper powers-of-tau ceremony.

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");
const tp = @import("zig-pairing").bn254_tower_pairing;

pub const Fr = zc.bn254.Fr;
pub const Fp = zf.BN254_Fp;
pub const Fp2 = zf.BN254_Fp2;
pub const G1 = zc.bn254.G1;
pub const G2 = zc.bn254.G2;
pub const G1Proj = zc.bn254.G1Projective;
pub const Fp12T = tp.Fp12T;

pub const KzgError = error{
    DegreeExceedsSetup,
    InvalidPoint,
    OutOfMemory,
};

/// Synthetic trusted setup: [tau^i]G1 for i in 0..max_degree, plus
/// [tau]G2 and the G2 generator.
pub const Setup = struct {
    /// g1_pows[i] = [tau^i]G1, len == max_degree + 1.
    g1_pows: []G1,
    /// [tau]G2
    g2_tau: G2,
    /// G2 generator (identity of the pairing check's second slot).
    g2_gen: G2,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Setup) void {
        self.allocator.free(self.g1_pows);
    }

    /// Generate a synthetic setup from a known tau. TEST-ONLY.
    pub fn generate(
        allocator: std.mem.Allocator,
        tau: Fr,
        max_degree: usize,
    ) !Setup {
        const g1_pows = try allocator.alloc(G1, max_degree + 1);
        errdefer allocator.free(g1_pows);

        // g1_pows[0] = G1 generator; then successive scalar muls by tau.
        g1_pows[0] = zc.bn254.G1_generator;
        var i: usize = 1;
        while (i <= max_degree) : (i += 1) {
            g1_pows[i] = g1MulFr(g1_pows[i - 1], tau);
        }

        return .{
            .g1_pows = g1_pows,
            .g2_tau = g2MulFr(zc.bn254.G2_generator, tau),
            .g2_gen = zc.bn254.G2_generator,
            .allocator = allocator,
        };
    }
};

// ---------------------------------------------------------------------------
// Helpers: G1/G2 scalar multiplication by an Fr element (via its LE bytes).
// ---------------------------------------------------------------------------

/// Double-and-add over the scalar's little-endian bytes (affine ops).
fn scalarMulFr(comptime Pt: type, p: Pt, s: Fr) Pt {
    const bytes = s.toBytes();
    var result = p;
    result.infinity = true; // group identity
    var base = p;
    const n_bits = bytes.len * 8;
    var i: usize = 0;
    while (i < n_bits) : (i += 1) {
        const bit_i: u3 = @intCast(i % 8);
        if ((bytes[i / 8] >> bit_i) & 1 == 1)
            result = result.add(base);
        base = base.dbl();
    }
    return result;
}

fn g1MulFr(p: G1, s: Fr) G1 {
    return scalarMulFr(G1, p, s);
}

fn g2MulFr(p: G2, s: Fr) G2 {
    return scalarMulFr(G2, p, s);
}

fn toProj(p: G1) G1Proj {
    return .{ .x = p.x, .y = p.y, .z = Fp.one() };
}

// ---------------------------------------------------------------------------
// Core KZG operations
// ---------------------------------------------------------------------------

/// Commit to a polynomial (coefficients, low degree first):
/// C = sum(coeffs[i] * [tau^i]G1).
pub fn commit(setup: *const Setup, coeffs: []const Fr) KzgError!G1 {
    if (coeffs.len > setup.g1_pows.len) return KzgError.DegreeExceedsSetup;
    const r = msmG1(setup.g1_pows[0..coeffs.len], coeffs);
    return affine(r);
}

/// Evaluate polynomial at z via Horner's method.
pub fn evaluate(coeffs: []const Fr, z: Fr) Fr {
    var acc = Fr.zero();
    var k = coeffs.len;
    while (k > 0) {
        k -= 1;
        acc = acc.mul(z).add(coeffs[k]);
    }
    return acc;
}

/// Compute witness/quotient q(x) = (p(x) - p(z)) / (x - z)
/// via synthetic division. Returns quotient coefficients (len n-1).
pub fn witnessCoeffs(
    allocator: std.mem.Allocator,
    coeffs: []const Fr,
    z: Fr,
) ![]Fr {
    std.debug.assert(coeffs.len >= 1);
    // Horner-based division: b[i-1] = coeffs[i] + z*b[i]
    const n = coeffs.len;
    const b = try allocator.alloc(Fr, n);
    defer allocator.free(b);
    var acc = Fr.zero();
    var k = n;
    while (k > 0) {
        k -= 1;
        acc = acc.mul(z).add(coeffs[k]);
        b[k] = acc;
    }
    // b[0] is the remainder p(z); quotient is b[1..].
    const q = try allocator.alloc(Fr, n - 1);
    @memcpy(q, b[1..]);
    return q;
}

/// Full open: returns the witness commitment and the evaluation y=p(z).
pub fn prove(
    setup: *const Setup,
    allocator: std.mem.Allocator,
    coeffs: []const Fr,
    z: Fr,
) KzgError!struct { witness: G1, y: Fr } {
    if (coeffs.len > setup.g1_pows.len) return KzgError.DegreeExceedsSetup;
    const y = evaluate(coeffs, z);
    const q = try witnessCoeffs(allocator, coeffs, z);
    defer allocator.free(q);
    const w = msmG1(setup.g1_pows[0..q.len], q);
    return .{ .witness = affine(w), .y = y };
}

/// Verify: e(C - [y]G1, [tau]G2) == e(W, G2).
pub fn verify(
    setup: *const Setup,
    commitment: G1,
    z: Fr,
    y: Fr,
    witness: G1,
) bool {
    // Check: e(C - [y]G1, G2gen) == e(W, [tau]G2 - [z]G2gen)
    const yg1 = toProj(g1MulFr(zc.bn254.G1_generator, y));
    const c_proj = toProj(commitment).add(yg1.neg());

    const zg2 = g2MulFr(setup.g2_gen, z);
    const tau_side = setup.g2_tau.add(zg2.neg()); // affine sub

    const lhs = tp.pairing(affine(c_proj), setup.g2_gen);
    const rhs = tp.pairing(witness, tau_side);
    return lhs.eql(rhs);
}

// G2 projective type comes from weierstrass via curve root; derive from G2's ops instead:

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn msmG1(g1_pows: []const G1, scalars: []const Fr) G1Proj {
    return zc.msm.msm(G1, G1Proj, Fr, std.heap.page_allocator, g1_pows, scalars) catch unreachable;
}

fn affine(p: G1Proj) G1 {
    // Normalise Jacobian -> affine via field inversion.
    if (p.isZero()) return G1.generator(Fp.zero(), Fp.zero());
    const zi = p.z.inv();
    const zi2 = zi.mul(zi);
    const zi3 = zi2.mul(zi);
    return G1.generator(p.x.mul(zi2), p.y.mul(zi3));
}

// ============================================================================
// Tests
// ============================================================================

const stdt = std.testing;

test "kzg: commit matches manual sum for degree 1" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(7), 8);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(3), Fr.fromInt(5) }; // p(x) = 3 + 5x
    const C = try commit(&setup, &coeffs);

    const t1 = g1MulFr(zc.bn254.G1_generator, Fr.fromInt(3));
    const t2 = g1MulFr(setup.g1_pows[1], Fr.fromInt(5));
    try stdt.expect(C.eql(t1.add(t2)));
}

test "kzg: open/verify happy path" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 16);
    defer setup.deinit();

    // p(x) = 2 + x + 3x^2 (evaluated at z=5 -> 2+5+75=82)
    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const z = Fr.fromInt(5);

    const C = try commit(&setup, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, z);
    defer {} // witness is a value copy

    try stdt.expect(evaluate(&coeffs, z).eql(pf.y));
    try stdt.expect(pf.y.eql(Fr.fromInt(82)));
    try stdt.expect(verify(&setup, C, z, pf.y, pf.witness));
}

test "kzg: tampered evaluation fails" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 16);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const z = Fr.fromInt(5);
    const C = try commit(&setup, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, z);

    const wrong_y = pf.y.add(Fr.one());
    try stdt.expect(!verify(&setup, C, z, wrong_y, pf.witness));
}

test "kzg: tampered witness fails" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 16);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const z = Fr.fromInt(5);
    const C = try commit(&setup, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, z);

    const bad_w = g1MulFr(pf.witness, Fr.fromInt(2)); // 2W != W
    try stdt.expect(!verify(&setup, C, z, pf.y, bad_w));
}

test "kzg: different opening point fails with same witness" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 16);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const C = try commit(&setup, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, Fr.fromInt(5));

    // verify at a DIFFERENT z with same witness/eval must fail
    try stdt.expect(!verify(&setup, C, Fr.fromInt(9), pf.y, pf.witness));
}
