//! Example: Schnorr signature over BLS12-381 G1.
//!
//! Demonstrates the full crypto stack working together:
//!   field arithmetic → curve scalar multiplication → hashing → verification

const std = @import("std");
const zf = @import("zig-field");
const zc = @import("zig-curve");

const Fp = zf.BLS12_381_Fp;
const Fr = zc.bls12_381.Fr;
const G1 = zc.bls12_381.G1;
const G1Gen = zc.bls12_381.G1_generator;

/// Deterministic key derivation from a seed (production code should use a CSPRNG).
fn deriveScalar(seed: []const u8) u64 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(seed);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .big) | 1; // ensure non-zero
}

/// Hash pk + commitment + message to a challenge scalar c (Fiat-Shamir).
fn challenge(pk: G1, committer: G1, msg: []const u8) u64 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const pk_bytes = pk.x.toBytes();
    const com_bytes = committer.x.toBytes();
    h.update(&pk_bytes);
    h.update(msg);
    h.update(&com_bytes);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .big) | 1; // non-zero
}

pub fn main() !void {
    std.debug.print("=== Schnorr Signature over BLS12-381 G1 ===\n\n", .{});

    // 1. Key Generation
    const sk: u64 = deriveScalar("alice-secret-key-seed");
    const pk = G1Gen.scalarMul(sk);

    std.debug.print("KeyGen:\n", .{});
    std.debug.print("  sk = {d} (secret)\n", .{sk});
    std.debug.print("  pk = sk·G on-curve: {}\n\n", .{pk.isOnCurve()});

    // 2. Signing
    //   r = nonce, R = r·G, c = H(pk||R||m), z = r + c·sk
    //   Signature: (R, z)
    const msg = "Hello, BSV + STARKs!";

    const r_nonce: u64 = deriveScalar("nonce-from-rng");
    const R_commit = G1Gen.scalarMul(r_nonce);
    const c_chal = challenge(pk, R_commit, msg);

    // Modular arithmetic: z = (r + c·sk) mod r (using Fr field ops)
    const sk_fr = Fr.fromInt(sk);
    const c_fr = Fr.fromInt(c_chal);
    const r_fr = Fr.fromInt(r_nonce);
    const z_fr = r_fr.add(c_fr.mul(sk_fr));
    const z_u512: u512 = z_fr.toInt();

    std.debug.print("Sign:\n", .{});
    std.debug.print("  m = \"{s}\"\n", .{msg});
    std.debug.print("  R = r·G (commitment), c = H(pk‖R‖m) = {d}\n", .{c_chal});
    std.debug.print("  z = r + c·sk = {d}\n\n", .{z_u512});

    // 3. Verification: z·G == R + c·pk
    const lhs = G1Gen.scalarMul(z_u512);
    const rhs = R_commit.add(pk.scalarMul(c_chal));
    const valid = lhs.eql(rhs);

    std.debug.print("Verify:\n", .{});
    std.debug.print("  z·G == R + c·pk ? {}\n", .{valid});

    if (valid) {
        std.debug.print("  SIGNATURE VALID\n\n", .{});
    } else {
        std.debug.print("  SIGNATURE INVALID\n\n", .{});
        return error.InvalidSignature;
    }

    // 4. Tamper detection
    const wrong_msg = "Hello, BSV + STARKs?";
    const bad_c = challenge(pk, R_commit, wrong_msg);
    const bad_lhs = G1Gen.scalarMul(z_u512);
    const bad_rhs = R_commit.add(pk.scalarMul(bad_c));

    std.debug.print("Tamper test:\n", .{});
    std.debug.print("  Modified msg valid? {} (want false)\n\n", .{bad_lhs.eql(bad_rhs)});

    // 5. Pairing demo
    const pairing_impl = @import("zig-pairing");
    const g2_gen = zc.bls12_381.G2_generator;

    const start_ns = blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        break :blk @as(u64, @intCast(@as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec))));
    };
    _ = pairing_impl.bls12_381_pairing_impl.pairing(G1Gen, g2_gen);
    const end_ns = blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        break :blk @as(u64, @intCast(@as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec))));
    };

    std.debug.print("Pairing demo:\n", .{});
    std.debug.print("  e(G1, G2) in {d} ms\n", .{(end_ns - start_ns) / 1_000_000});
}
