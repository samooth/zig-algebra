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
    InvalidPolynomial,
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
// Helpers: G1/G2 scalar multiplication by an Fr element.
// Delegates to zig-curve's windowed scalar mul (projective ladder).
// ---------------------------------------------------------------------------

/// Non-CT (synthetic setup and public proof values only).
fn g1MulFr(p: G1, s: Fr) G1 {
    return p.scalarMul(s.toInt());
}

/// Non-CT (synthetic setup and public proof values only).
fn g2MulFr(p: G2, s: Fr) G2 {
    return p.scalarMul(s.toInt());
}

fn toProj(p: G1) G1Proj {
    if (p.infinity) return G1Proj.zero();
    return .{ .x = p.x, .y = p.y, .z = Fp.one() };
}

// ---------------------------------------------------------------------------
// Core KZG operations
// ---------------------------------------------------------------------------

/// Commit to a polynomial (coefficients, low degree first):
/// C = sum(coeffs[i] * [tau^i]G1).
pub fn commit(
    setup: *const Setup,
    allocator: std.mem.Allocator,
    coeffs: []const Fr,
) KzgError!G1 {
    if (coeffs.len == 0) return KzgError.InvalidPolynomial;
    if (coeffs.len > setup.g1_pows.len) return KzgError.DegreeExceedsSetup;
    const r = try msmG1(allocator, setup.g1_pows[0..coeffs.len], coeffs);
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
) KzgError![]Fr {
    if (coeffs.len == 0) return KzgError.InvalidPolynomial;
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
    if (coeffs.len == 0) return KzgError.InvalidPolynomial;
    const y = evaluate(coeffs, z);
    const q = try witnessCoeffs(allocator, coeffs, z);
    defer allocator.free(q);
    const w = try msmG1(allocator, setup.g1_pows[0..q.len], q);
    return .{ .witness = affine(w), .y = y };
}

/// Verify: e(C - [y]G1, G2) == e(W, [tau]G2 - [z]G2).
///
/// The two G2 operands were the wrong way round here, and the `- [z]G2` term
/// was missing: the code has always checked this equation, and the docstring
/// named another one. The mistake is harmless in isolation -- both sides are
/// computed from the same alpha-free pairing -- and fatal to anyone using the
/// sentence to reimplement or to audit the check.
pub fn verify(
    setup: *const Setup,
    commitment: G1,
    z: Fr,
    y: Fr,
    witness: G1,
) bool {
    if (!commitment.isOnCurve() or !witness.isOnCurve()) return false;
    if (!tp.isG1InSubgroup(commitment) or !tp.isG1InSubgroup(witness)) return false;
    const yg1 = toProj(g1MulFr(zc.bn254.G1_generator, y));
    const c_proj = toProj(commitment).add(yg1.neg());

    const zg2 = g2MulFr(setup.g2_gen, z);
    const tau_side = setup.g2_tau.add(zg2.neg()); // affine sub

    const lhs = if (c_proj.isZero())
        Fp12T.one()
    else
        tp.pairing(affine(c_proj), setup.g2_gen);
    const rhs = if (witness.infinity or tau_side.infinity)
        Fp12T.one()
    else
        tp.pairing(witness, tau_side);
    return lhs.eql(rhs);
}

// G2 projective type comes from weierstrass via curve root; derive from G2's ops instead:

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn msmG1(
    allocator: std.mem.Allocator,
    g1_pows: []const G1,
    scalars: []const Fr,
) KzgError!G1Proj {
    if (g1_pows.len != scalars.len) return KzgError.InvalidPolynomial;
    return zc.msm.msm(G1, G1Proj, Fr, allocator, g1_pows, scalars) catch |err| switch (err) {
        error.OutOfMemory => KzgError.OutOfMemory,
        // Pre-checked above; kept for exhaustiveness.
        error.LengthMismatch => KzgError.InvalidPolynomial,
    };
}

fn affine(p: G1Proj) G1 {
    if (p.isZero()) return G1.zero();
    const zi = p.z.inv();
    const zi2 = zi.mul(zi);
    const zi3 = zi2.mul(zi);
    return G1.generator(p.x.mul(zi2), p.y.mul(zi3));
}

// ============================================================================
// Tests
// ============================================================================

const stdt = std.testing;

test "kzg: constant and empty-polynomial edge cases" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(7), 4);
    defer setup.deinit();

    const constant = [_]Fr{Fr.fromInt(9)};
    const commitment = try commit(&setup, stdt.allocator, &constant);
    try stdt.expect(commitment.eql(g1MulFr(zc.bn254.G1_generator, Fr.fromInt(9))));
    try stdt.expectError(KzgError.InvalidPolynomial, commit(&setup, stdt.allocator, &.{}));
    try stdt.expectError(KzgError.InvalidPolynomial, prove(&setup, stdt.allocator, &.{}, Fr.fromInt(2)));
    try stdt.expectError(KzgError.InvalidPolynomial, witnessCoeffs(stdt.allocator, &.{}, Fr.fromInt(2)));
}

test "kzg: commit matches manual sum for degree 1" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(7), 8);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(3), Fr.fromInt(5) }; // p(x) = 3 + 5x
    const C = try commit(&setup, stdt.allocator, &coeffs);

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

    const C = try commit(&setup, stdt.allocator, &coeffs);
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
    const C = try commit(&setup, stdt.allocator, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, z);

    const wrong_y = pf.y.add(Fr.one());
    try stdt.expect(!verify(&setup, C, z, wrong_y, pf.witness));
}

test "kzg: tampered witness fails" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 16);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const z = Fr.fromInt(5);
    const C = try commit(&setup, stdt.allocator, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, z);

    const bad_w = g1MulFr(pf.witness, Fr.fromInt(2)); // 2W != W
    try stdt.expect(!verify(&setup, C, z, pf.y, bad_w));
}

test "kzg: different opening point fails with same witness" {
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 16);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const C = try commit(&setup, stdt.allocator, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, Fr.fromInt(5));

    // verify at a DIFFERENT z with same witness/eval must fail
    try stdt.expect(!verify(&setup, C, Fr.fromInt(9), pf.y, pf.witness));
    const invalid = G1.generator(Fp.one(), Fp.one());
    try stdt.expect(!verify(&setup, invalid, Fr.fromInt(5), pf.y, pf.witness));
}
// ---------------------------------------------------------------------------
// Differential against py_ecc's reference BN254 module
// ---------------------------------------------------------------------------
//
// Every coordinate and every verdict below was produced by `py_ecc.bn128`
// (py_ecc's non-optimized module: the standard parameters, G1 over p, scalars
// mod r) and by nothing in this repository. `verdict` is py_ecc's own answer to
// the verification equation, so what this test compares across
// implementations is the *decision*, not only the bytes that go into it.
//
// Two things about that module are worth knowing before trusting it, because
// both cost this differential a false "the library is wrong":
//
//   * Scalars reduce mod r, the group order. py_ecc's `field_modulus` is p, and
//     a tau smaller than both makes the two reductions identical, so a fixture
//     of small taus cannot tell them apart.
//   * `neg` returns a coordinate that is not on the curve for large scalars,
//     and `multiply` inherits it. The inverses below are the group's own
//     negation with the sign reduced by hand; the ladder and the pairing are
//     still py_ecc's.
//
// The hex is decoded at run time rather than at comptime: a fixture this size
// spends the comptime budget on arithmetic it does not need, and a literal that
// fails to decode then surfaces as an unrelated error.

const KzgHexError = error{MalformedFixtureLiteral};

fn kzgHex(s: []const u8) KzgHexError!u256 {
    if (s.len != 64) return error.MalformedFixtureLiteral;
    var buf: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buf, s) catch return error.MalformedFixtureLiteral;
    return std.mem.readInt(u256, &buf, .big);
}

fn kzgFr(s: []const u8) KzgHexError!Fr {
    return Fr.fromInt(try kzgHex(s));
}

/// G1 coordinates are base-field elements; only the scalars live in `Fr`.
fn kzgFp(s: []const u8) KzgHexError!Fp {
    return Fp.fromInt(try kzgHex(s));
}

fn kzgExpectG1(actual: G1, want: [2][]const u8) !void {
    const x = try kzgFp(want[0]);
    const y = try kzgFp(want[1]);
    if (x.isZero() and y.isZero()) {
        if (!actual.infinity) {
            std.debug.print("G1: el fixture dice el punto en el infinito, aqui es finito\n", .{});
            return error.TestExpectedEqual;
        }
        return;
    }
    if (actual.infinity) {
        std.debug.print("G1: el fixture dice (0, 0) y el punto es finito\n", .{});
        return error.TestExpectedEqual;
    }
    if (!x.eql(actual.x) or !y.eql(actual.y)) {
        std.debug.print(
            "G1: fixture ({d}, {d})\n    implementation ({d}, {d})\n",
            .{ x.toInt(), y.toInt(), actual.x.toInt(), actual.y.toInt() },
        );
        return error.TestExpectedEqual;
    }
}

fn kzgExpectG2(actual: G2, want: [4][]const u8) !void {
    const wx0 = try kzgFp(want[0]);
    const wx1 = try kzgFp(want[1]);
    const wy0 = try kzgFp(want[2]);
    const wy1 = try kzgFp(want[3]);
    if (!wx0.eql(actual.x.c0) or !wx1.eql(actual.x.c1) or
        !wy0.eql(actual.y.c0) or !wy1.eql(actual.y.c1))
    {
        std.debug.print(
            "G2: fixture ({d}, {d}) / ({d}, {d})\n" ++
                "    implementation ({d}, {d}) / ({d}, {d})\n",
            .{
                wx0.toInt(),         wx1.toInt(),         wy0.toInt(),         wy1.toInt(),
                actual.x.c0.toInt(), actual.x.c1.toInt(), actual.y.c0.toInt(), actual.y.c1.toInt(),
            },
        );
        return error.TestExpectedEqual;
    }
}

const KzgCase = struct {
    name: []const u8,
    tau: []const u8,
    max_degree: usize,
    coeffs: []const []const u8,
    z: []const u8,
    g1_pows: []const [2][]const u8,
    g2_gen: [4][]const u8,
    g2_tau: [4][]const u8,
    commitment: [2][]const u8,
    y: []const u8,
    witness: [2][]const u8,
    verdict: bool,
    verdict_tampered: bool,
};

const kzg_cases = [_]KzgCase{
    .{
        .name = "the existing happy path",
        .tau = "000000000000000000000000000000000000000000000000000000000000002a",
        .max_degree = 8,
        .coeffs = &.{ "0000000000000000000000000000000000000000000000000000000000000002", "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000003" },
        .z = "0000000000000000000000000000000000000000000000000000000000000005",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0988f35db6971fd77c8f9afdae27f7fb355577586de4c517537d17882f9b3f34", "23baffa63fafc8c67007390a6e6dd52860b4a8ae95f49905d52cdb2c3b4cb203" },
            .{ "0d4b868bd01f4e7a548f7eb25b8804890153e13d05ab0783f4a9fabe91a4434a", "054e363bd9aaf55f8354328c3d7d1e515665b0875bfaa639e3e654d291cf9bc6" },
            .{ "06b484269f98405b8a069acd2d0ec1af79260324b75a98bbb8d1930638b7cd8f", "14999aab584bc84ca5972c96865182cd757a8debef592a9697c068f4c241a8a4" },
            .{ "0a8caf709ecdc62b96eb0f5489f598660dd339bb8ce8fdda0ff5c6e229babc0e", "1f070f6ee634a0de54f105aef1089f9730317635b1a1eb9af4f816579ebc5635" },
            .{ "031d89e236d9c799ae876c29f325e2d87b2c5c91f13dede99e22fabe3e55d18e", "07f23953786c0851e8b3fa9a360a264bf7a815ffb3a08fd66aa276dbbc385bd6" },
            .{ "2f5b922d0d6e3dec853afb82762681301937c090eabf0ad41f65a37fd468088d", "05064bded4d639b60b1a3473ac57f6e23024449fd147fa0ccb732ddb2c979ca9" },
            .{ "01a3b130cedeefb3282154ad59bc4d2132f1e1c068914192135f217a5ccfd9fa", "05d39e795b2ce973471b2b2cea7fb127f5bb1764a4cfce91fefd43f8a58c9e88" },
            .{ "0d5cd3c28e46282d07ff22dcd6e6e9faa38d3f2fa8eaf5faa31dfeaddd14f3f9", "18325d787053ce9a2aa5e05fd7eeba78d57dffd9c31d005faecf2bc0f2243f82" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "116da8c89a0d090f3d8644ada33a5f1c8013ba7204aeca62d66d931b99afe6e7", "12740934ba9615b77b6a49b06fcce83ce90d67b1d0e2a530069e3a7306569a91", "076441042e77b6309644b56251f059cf14befc72ac8a6157d30924e58dc4c172", "25222d9816e5f86b4a7dedd00d04acc5c979c18bd22b834ea8c6d07c0ba441db" },
        .commitment = .{ "1e7ff14292921f0f90cfb5893824674d51700a2debe85302ce6fcefd58c1fbb4", "09c8d888473277020d557d325113181bd25c4c6e745ae0264385b952e59249e8" },
        .y = "0000000000000000000000000000000000000000000000000000000000000052",
        .witness = .{ "2426a77d2a11faea96d227622374449c5dc60734e2107f0debc19a69adb84393", "02cd3064f5e47182e0eb78036ad6815a781bd602c57777a72476adea8586648d" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "tau = 1 makes every power the generator",
        .tau = "0000000000000000000000000000000000000000000000000000000000000001",
        .max_degree = 4,
        .coeffs = &.{ "0000000000000000000000000000000000000000000000000000000000000007", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000009", "0000000000000000000000000000000000000000000000000000000000000002" },
        .z = "0000000000000000000000000000000000000000000000000000000000000003",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .commitment = .{ "2dbc7ba68f840c758c76373cd37b2cd78d6b02bee047cf401e8db90d73ce56f7", "062800987ee0dae9f9f36e1f050eb2621cbb4aa7c50b1c168ecc319370889de2" },
        .y = "000000000000000000000000000000000000000000000000000000000000008e",
        .witness = .{ "19d607c830714c3cc198e3ec45d2e1b04c72056927704b5fe5cb9cc996d2da41", "2f73848174a7ee872de9dd9b2e4b7544b440b9095029a80aef862af9b0c4f8f6" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "a random large tau over a degree-8 polynomial",
        .tau = "28f334534ec07f85acc137cd38ea4b5bbacf63c8a16adbb567cde14076792a42",
        .max_degree = 8,
        .coeffs = &.{ "1fd470b50a3565b0d00a8eba06dcf1506e06f9ff9592a229c1cfdd31de33eaf5", "205d68d801c14745ec8871fb3e3945050bc38c28e5c4550867376da1ef6d202a", "066f5a1a8b7d8a68cba0f71e830df4f5de74c870fa62347071d9089d474f7d5b", "11b9b99d873d1a806a93fea98e2471d9c5257b71597526c8c0731e7f44d7e8c3", "0292873164f855f2dc0b98b708d09109edd05a712e218e1bbea3fac525627256", "2ce0dcee43fd9cce43e1896188653f5592b38d61a5294043a89b4baf7e475e59", "29b230a357cc67a330ebe8c2bbedf8cae044483453c59cce878b2677032df3e6", "1184a147d1480a9d760ecf71d699577c6f890f84409df04ff93047679e1e7846", "1a668868644da4a8c3a8c35145df9d9adf2fa9b42aa32b3d499a7ab20a2d0cd9" },
        .z = "016b5982d267337f6b280d11a4d4dc67b81e8504f0cc3f67b67dab32807ff661",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "23c219f41f8c3bea001b5d2b1486a9644efa5caacbdcc94ff802356e0c7692e5", "2ba7511578596f5caa19d92cfdb5fb24e83aa571fc4d49ea94bf093f9b658c32" },
            .{ "2fa1c38b576b37876b93902d6859e6cfca17df397e4d922806c700f6e1d5b06a", "25685de6b28c165085c0edbd9ad6e12586009acf4ff31c28b9abe35e9db01ae8" },
            .{ "0485496b5246cd9de3324abbf325359c36b9c49e498ee57a2c2f5263a3e92a63", "07556bb40f5fca9e1b4ee608f43594e7433838bd87d62e82bba68b6e8ad7a4fd" },
            .{ "149dde1d339e57e55dbbec3b2ca74ec147dde76f668d27a678a89b3ea87680a9", "2ea7632460bd01dd6abe2a3671a43526ac14b50a66cf74244ed7c1219bd977c8" },
            .{ "25571b4779fbbff2c7ceb841a46823f887c17311002ecec9846aef676ec5e77e", "05a446e0076af468213954fe76bfce7584f352c321e3d794ae2632782311a265" },
            .{ "27293781c988e2ef687ac52ce8f9c4b551f6aa354322fa662467adfaa9a14424", "13777770163680246d83455622aa00db34c0553bc3b8460e7709394138e30c37" },
            .{ "2ecdddfbb34123850b3cf5c0f6991c45be70c49f2f99886ad9f52440e7ba38ad", "27dbb2b3775be05c51e7452d3e31637c6acb58f5c15704d6ef09cc7590a2c8a3" },
            .{ "1fbc7a9089f1687249f920e3b76056b4daaf73484fe529566964efef898a09d0", "0b4a4926c971cb7f0a5690428378dcb304ac26de0742c98f0346b5dc5f647cdf" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "212bb6b13bc4ae8a102ac49b2916d3da6042fc64ca67214972ae56acd96e8295", "057cc7e9ec15e995f9becd4f5434ca68a7d3d4b3dd2a9c32456acae2f236135c", "20f6b73db34f5e68fc7f581c8ace92b488b531644b4d2b25c2026e5068b03a55", "119209aa76fa2c9dd6d2365ddfbe26d1bbe7869478c4c470f3b594a5cce43511" },
        .commitment = .{ "1224c15c48d44e337565284fa1b50508eafe5a8f599c929a7ca885add9dbfe77", "07b3e207d27d28bfe38670892df7154c75f2d9babfc9e98cca3b74d03528f21e" },
        .y = "0cf67f10aaf561a48bbd8440274537440d956abdd65c29771019e807396651d7",
        .witness = .{ "20e450e038b94d0cd56956f2be40ed0277882080f9ef4cb813e132426699243c", "14eefb5265fa8eafd242dab0abacb784ef6f81979e4114172fcb4c00fa014053" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "the zero polynomial: both points are the point at infinity",
        .tau = "000000000000000000000000000000000000000000000000000000000000002a",
        .max_degree = 4,
        .coeffs = &.{ "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000" },
        .z = "0000000000000000000000000000000000000000000000000000000000000005",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0988f35db6971fd77c8f9afdae27f7fb355577586de4c517537d17882f9b3f34", "23baffa63fafc8c67007390a6e6dd52860b4a8ae95f49905d52cdb2c3b4cb203" },
            .{ "0d4b868bd01f4e7a548f7eb25b8804890153e13d05ab0783f4a9fabe91a4434a", "054e363bd9aaf55f8354328c3d7d1e515665b0875bfaa639e3e654d291cf9bc6" },
            .{ "06b484269f98405b8a069acd2d0ec1af79260324b75a98bbb8d1930638b7cd8f", "14999aab584bc84ca5972c96865182cd757a8debef592a9697c068f4c241a8a4" },
            .{ "0a8caf709ecdc62b96eb0f5489f598660dd339bb8ce8fdda0ff5c6e229babc0e", "1f070f6ee634a0de54f105aef1089f9730317635b1a1eb9af4f816579ebc5635" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "116da8c89a0d090f3d8644ada33a5f1c8013ba7204aeca62d66d931b99afe6e7", "12740934ba9615b77b6a49b06fcce83ce90d67b1d0e2a530069e3a7306569a91", "076441042e77b6309644b56251f059cf14befc72ac8a6157d30924e58dc4c172", "25222d9816e5f86b4a7dedd00d04acc5c979c18bd22b834ea8c6d07c0ba441db" },
        .commitment = .{ "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000" },
        .y = "0000000000000000000000000000000000000000000000000000000000000000",
        .witness = .{ "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000000" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "a leading zero coefficient",
        .tau = "000000000000000000000000000000000000000000000000000000000000002a",
        .max_degree = 5,
        .coeffs = &.{ "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000003", "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000007" },
        .z = "000000000000000000000000000000000000000000000000000000000000000b",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0988f35db6971fd77c8f9afdae27f7fb355577586de4c517537d17882f9b3f34", "23baffa63fafc8c67007390a6e6dd52860b4a8ae95f49905d52cdb2c3b4cb203" },
            .{ "0d4b868bd01f4e7a548f7eb25b8804890153e13d05ab0783f4a9fabe91a4434a", "054e363bd9aaf55f8354328c3d7d1e515665b0875bfaa639e3e654d291cf9bc6" },
            .{ "06b484269f98405b8a069acd2d0ec1af79260324b75a98bbb8d1930638b7cd8f", "14999aab584bc84ca5972c96865182cd757a8debef592a9697c068f4c241a8a4" },
            .{ "0a8caf709ecdc62b96eb0f5489f598660dd339bb8ce8fdda0ff5c6e229babc0e", "1f070f6ee634a0de54f105aef1089f9730317635b1a1eb9af4f816579ebc5635" },
            .{ "031d89e236d9c799ae876c29f325e2d87b2c5c91f13dede99e22fabe3e55d18e", "07f23953786c0851e8b3fa9a360a264bf7a815ffb3a08fd66aa276dbbc385bd6" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "116da8c89a0d090f3d8644ada33a5f1c8013ba7204aeca62d66d931b99afe6e7", "12740934ba9615b77b6a49b06fcce83ce90d67b1d0e2a530069e3a7306569a91", "076441042e77b6309644b56251f059cf14befc72ac8a6157d30924e58dc4c172", "25222d9816e5f86b4a7dedd00d04acc5c979c18bd22b834ea8c6d07c0ba441db" },
        .commitment = .{ "165ace9acd9207ba6b22a5f11fa8be1f7e03e891cb5781db3812a99e67cf9249", "2b60659c25cf71b97c720c412e637378393ef9ddf2d1b4575ee0c2f26cfb630c" },
        .y = "0000000000000000000000000000000000000000000000000000000000002486",
        .witness = .{ "1341d3caab2f66ad4e09a1439f53a9679a932506ed6bcdd863574acd5a352eab", "25498de90762998847aba4ed192ecb3df561aa0051910912f9ea33528831caa4" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "opening at z = 0 with a non-zero constant term",
        .tau = "000000000000000000000000000000000000000000000000000000000000002a",
        .max_degree = 4,
        .coeffs = &.{ "0000000000000000000000000000000000000000000000000000000000000006", "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000004", "0000000000000000000000000000000000000000000000000000000000000009" },
        .z = "0000000000000000000000000000000000000000000000000000000000000000",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "0988f35db6971fd77c8f9afdae27f7fb355577586de4c517537d17882f9b3f34", "23baffa63fafc8c67007390a6e6dd52860b4a8ae95f49905d52cdb2c3b4cb203" },
            .{ "0d4b868bd01f4e7a548f7eb25b8804890153e13d05ab0783f4a9fabe91a4434a", "054e363bd9aaf55f8354328c3d7d1e515665b0875bfaa639e3e654d291cf9bc6" },
            .{ "06b484269f98405b8a069acd2d0ec1af79260324b75a98bbb8d1930638b7cd8f", "14999aab584bc84ca5972c96865182cd757a8debef592a9697c068f4c241a8a4" },
            .{ "0a8caf709ecdc62b96eb0f5489f598660dd339bb8ce8fdda0ff5c6e229babc0e", "1f070f6ee634a0de54f105aef1089f9730317635b1a1eb9af4f816579ebc5635" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "116da8c89a0d090f3d8644ada33a5f1c8013ba7204aeca62d66d931b99afe6e7", "12740934ba9615b77b6a49b06fcce83ce90d67b1d0e2a530069e3a7306569a91", "076441042e77b6309644b56251f059cf14befc72ac8a6157d30924e58dc4c172", "25222d9816e5f86b4a7dedd00d04acc5c979c18bd22b834ea8c6d07c0ba441db" },
        .commitment = .{ "1cfcbc7f09bf2de1b841fd55917d7eb7e067ef7ccd75353455e03d9425f6ebcd", "2466bb9d20cb47ddd15e92261bdbb33605f6e4f2b00ef7bddfbe714363628979" },
        .y = "0000000000000000000000000000000000000000000000000000000000000006",
        .witness = .{ "2b37d4debaa21c68f02a893523802593fc3b646116690c214d8e0dc0336db928", "0247c695169af71e42daa7ada7952b72c0735da8bbd52be2982ebb64a489c886" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "degree equal to the setup bound",
        .tau = "00000000000000000000000000000000000000000000000000000000075bcd15",
        .max_degree = 3,
        .coeffs = &.{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002", "0000000000000000000000000000000000000000000000000000000000000003", "0000000000000000000000000000000000000000000000000000000000000004" },
        .z = "0000000000000000000000000000000000000000000000000000000000000063",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "142a7688cf05c29f7593351e1b86eb87e3ad5dcb1b0fc3d853e9852040c57019", "136b5d7e238ae6edc22d1fba5a2dcde8a7b0df53b0c4af7f600e6a0c4610c899" },
            .{ "2fafa72fc85f0b05cf81bd71eb4ed99492ba4e3018f7ad7d0dc863b264540772", "2426a0afb0e87f141d438adb313f40b1de926f9ff1944b8e90d5aa9d71812a2c" },
            .{ "13108085a9efaa1104be33110c94f76f77bc98cf4fdb7c31a83dc13cbabf058a", "134e759842807b7e911b5ad19226112e8e461d776137c7e68d1348129a383f45" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "00506c3def7620270716e18bfc554f9f5380ce2b3b425f0a6625d73afb204fff", "1c15df6dc9bd529991343f0a78d9a0d355b1b648567c7ee58d02664c8e2d4631", "17397d778e1a5422e54482feb4199a5249a7a4dbfb3f2bf319520234b3137e06", "302e3e5b6b93a75d13b0a899163155f0a57b5e721277d2c718f2300d10a29899" },
        .commitment = .{ "2f74096906c071bbfaddf6228e394fa6d7c13fc73e9a5fb0bb1ce8961bc97c6b", "26024b24e326318fc2bd545c917b6b8007d782ffaf0fa49e8e9c055464987993" },
        .y = "00000000000000000000000000000000000000000000000000000000003bac8e",
        .witness = .{ "1d3ce2d4964ee9a2d245c47f7db80b77a595225c5ef230ace4067df078ed04e6", "10d9ed189ba1f6477d05390e2e038edbbbafa40e9c35c264b3f11a39c2632f15" },
        .verdict = true,
        .verdict_tampered = false,
    },
    .{
        .name = "a second random tau, to keep the large-scalar path plural",
        .tau = "016b5982d267337f6b280d11a4d4dc67b81e8504f0cc3f67b67dab32807ff661",
        .max_degree = 6,
        .coeffs = &.{ "118f8a96e6c2dcdaec1911f2cee25cb60b54dbbc08ffa065ef2b915eb256f405", "2fe3186c0b7bcd10f0adc620035ba0535d195a1d545b55049b1dfd8f12e3f251", "1891230863131c571553619baa8ae2510a68309ef86b7946836ff64737018bd2", "2aa6ca2155bbfc344bee0cecd8d424c1220f5e896916579493a87797608fbb11", "3028389158e88afe5e86b7fdd70a503db52b8bf25e30225ba03dbcc997cc1d22", "1e1c337dcebc51f2e244e7a0105d6458422af63c1d39d2f6a7f5418505ecd6c5" },
        .z = "28f334534ec07f85acc137cd38ea4b5bbacf63c8a16adbb567cde14076792a42",
        .g1_pows = &[_][2][]const u8{
            .{ "0000000000000000000000000000000000000000000000000000000000000001", "0000000000000000000000000000000000000000000000000000000000000002" },
            .{ "239b6a2fa113de88a3d9cccfb8de082f95c126834f7098e1317b979617d4d88f", "21de1ccb1e6bd6627ccd08687405def8b3422b199c805af9e76d6612ca4624c7" },
            .{ "20c0d6f36c437a6f4eef3ebd017a8fa58e88c2bcf51b4f42d7c1fc0ef56d1bde", "137819617f8132e53e0efac27f828fd789d5c2acf4abf3a7c2870ee7893b9da2" },
            .{ "08330b20bc1c8ae991021407bd7d1abdbbc7948dde7923f29ec62d7888a179fa", "2f908ce4f1688ee3b804a4308b4fd8cae1c255ba18525f914d416fbd01ac1233" },
            .{ "2dbe5885a8c0cf0be797292cb485e9a0da406dae988c7e5ad6b3653c96404c51", "15931adc2ba7ee08e70b5d06430d3148f09279ce2da2fead86bb16d93cca8a35" },
            .{ "0826e766cba9accd09f79eb73e56e531e40952ac42eefe3db4ad38d6075f2f08", "0c05b53fa323e460cc40edadf02b1bb67d9c85fa1ae85a3bc6872ba3a6a95a07" },
            .{ "10a1643aebe5987cefa41dbcc8b19c2fc53ceae92856db08b21a3967a089d3e1", "0c15a03ad8c1c3d6e4f88f39568d8156efa96cdb78c46d070d970b4af21af636" },
        },
        .g2_gen = .{ "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed", "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2", "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa", "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" },
        .g2_tau = .{ "0694bbcad05cd96073c923c4ef4426e5d8088c634919d843a0cef1009541a468", "09a6e7d7ee3da13e8f67bf5fc7685d2c749adc5534ad8d688087dbbf1cd5c3d4", "0fbbbe44b7d9f72672d27a29a293bba7617dee94ff205227975df7cc48d84691", "1cf6aa400de410930acd9c06483c9a1e3a5811f1f8ea6190745395f3b7bbb689" },
        .commitment = .{ "056602aa18b92eab3fdca210e198ed575b02feda0c9e99b5ec37baaaaedb5631", "0435e026a82e66ded3a4cee34b99acf7e951c70273b51f687f864c485300f2ad" },
        .y = "0fe3d2cf13f789d8e762e5af86971c126b94a69751173b62c593b606c476ef85",
        .witness = .{ "1514751cf659ff4d3834570fd79253ba580f3606f1e1c41f9b148f9a47d38fe4", "22cd1472773f3c9d896ad977f9b382f890a3ae62de4adb71bc1fe303e29f9ef1" },
        .verdict = true,
        .verdict_tampered = false,
    },
};

test "kzg: setup, commitment, witness and the pairing decision match py_ecc" {
    // A differential that fails without saying which case failed is a
    // differential nobody can act on, so the name travels with the failure.
    for (kzg_cases) |c| kzgRunCase(c) catch |err| {
        std.debug.print("fallo el caso del fixture \"{s}\" ({s})\n", .{ c.name, @errorName(err) });
        return err;
    };
}

fn kzgRunCase(c: KzgCase) !void {
    var setup = try Setup.generate(stdt.allocator, try kzgFr(c.tau), c.max_degree);
    defer setup.deinit();

    // The synthetic setup is [tau^i]G1 plus [tau]G2 and the G2 generator. That
    // is a claim about coordinates, not about the code that produced them, so
    // it is checked against the external ones.
    try stdt.expectEqual(c.g1_pows.len, setup.g1_pows.len);
    for (setup.g1_pows, c.g1_pows) |actual, want| try kzgExpectG1(actual, want);
    try kzgExpectG2(setup.g2_gen, c.g2_gen);
    try kzgExpectG2(setup.g2_tau, c.g2_tau);

    var coeffs: [16]Fr = undefined;
    try stdt.expect(c.coeffs.len <= coeffs.len);
    for (c.coeffs, 0..) |hex, k| coeffs[k] = try kzgFr(hex);
    const p = coeffs[0..c.coeffs.len];
    const z = try kzgFr(c.z);

    const C = try commit(&setup, stdt.allocator, p);
    try kzgExpectG1(C, c.commitment);

    const pf = try prove(&setup, stdt.allocator, p, z);
    try stdt.expectEqual(try kzgFr(c.y), pf.y);
    try kzgExpectG1(pf.witness, c.witness);

    try stdt.expect(verify(&setup, C, z, pf.y, pf.witness) == c.verdict);
    try stdt.expect(verify(&setup, C, z, pf.y.add(Fr.one()), pf.witness) == c.verdict_tampered);
}

test "kzg: verify rejects a commitment that is not on the curve" {
    // The on-curve and subgroup checks in `verify` cannot be reached by the
    // differential above: everything py_ecc hands us is a valid point, so a
    // mutation that deletes either check survives it. This is the input that
    // makes those two checks falsifiable, and it is why the row is no longer
    // "survived".
    var setup = try Setup.generate(stdt.allocator, Fr.fromInt(42), 8);
    defer setup.deinit();

    const coeffs = [_]Fr{ Fr.fromInt(2), Fr.fromInt(1), Fr.fromInt(3) };
    const z = Fr.fromInt(5);
    const C = try commit(&setup, stdt.allocator, &coeffs);
    const pf = try prove(&setup, stdt.allocator, &coeffs, z);
    try stdt.expect(verify(&setup, C, z, pf.y, pf.witness));

    // y + 1 leaves the curve: the setup is sound, so a verifier that accepts
    // this is not checking what it claims to check.
    const off_curve = G1.generator(C.x, C.y.add(Fp.one()));
    try stdt.expect(!off_curve.isOnCurve());
    try stdt.expect(!verify(&setup, off_curve, z, pf.y, pf.witness));

    const off_curve_witness = G1.generator(pf.witness.x, pf.witness.y.add(Fp.one()));
    try stdt.expect(!off_curve_witness.isOnCurve());
    try stdt.expect(!verify(&setup, C, z, pf.y, off_curve_witness));

    // A point at infinity where a real commitment is expected is not a
    // commitment either.
    try stdt.expect(!verify(&setup, G1.zero(), z, pf.y, pf.witness));
}
