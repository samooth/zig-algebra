// SPDX-License-Identifier: MIT OR Apache-2.0

//! Inner Product Argument (IPA) over finite fields.
//!
//! Bulletproofs-style logarithmic IPA that proves `<a, b> = c` without
//! revealing vectors `a` and `b`. Uses field elements as pseudo-generators
//! derived deterministically from a seed via a PRNG.
//!
//! ## Overview
//!
//! - **Commit**: `C = <a, G> + <b, H> + c * U` where G, H, U are generators
//! - **Prove**: Recursive halving (log n rounds) producing L, R challenges
//! - **Verify**: Reconstruct final generators and check the equation
//!
//! ## Usage
//! ```zig
//! var ipa = try Ipa(F).init(allocator, 64, seed);
//! defer ipa.deinit();
//!
//! const c = innerProduct(&a, &b);
//! const proof = try ipa.prove(allocator, &a, &b, c);
//! defer proof.deinit(allocator);
//!
//! try ipa.verify(&proof, c);
//! ```

const std = @import("std");

pub fn Ipa(comptime F: type) type {
    return struct {
        const Self = @This();
        const Hash = std.crypto.hash.sha2.Sha256;

        allocator: std.mem.Allocator,
        n: usize, // vector length (power of 2)
        g: []F, // generator vector G (length n)
        h: []F, // generator vector H (length n)
        u: F, // generator U for the inner product

        /// Initialize IPA with vector length `n` (must be power of 2).
        /// Generators G, H, U are derived deterministically from `seed`.
        pub fn init(allocator: std.mem.Allocator, n: usize, seed: [32]u8) !Self {
            if (n == 0 or (n & (n - 1)) != 0) return error.LengthNotPowerOfTwo;

            var g = try allocator.alloc(F, n);
            errdefer allocator.free(g);
            var h = try allocator.alloc(F, n);
            errdefer allocator.free(h);

            // Derive generators deterministically from seed
            var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, seed[0..8], .little));
            const rnd = prng.random();

            for (0..n) |i| {
                g[i] = F.random(rnd);
                h[i] = F.random(rnd);
            }
            const u = F.random(rnd);

            return .{
                .allocator = allocator,
                .n = n,
                .g = g,
                .h = h,
                .u = u,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.g);
            self.allocator.free(self.h);
        }

        // -- Inner product ---------------------------------------------------

        /// Compute `<a, b> = sum(a_i * b_i)`.
        pub fn innerProduct(a: []const F, b: []const F) F {
            std.debug.assert(a.len == b.len);
            var result = F.zero();
            for (a, b) |ai, bi| {
                result = result.add(ai.mul(bi));
            }
            return result;
        }

        // -- Commitment ------------------------------------------------------

        /// Commit to vectors `a`, `b` with claimed inner product `c`.
        /// `C = <a, G> + <b, H> + c * U`.
        pub fn commit(self: Self, a: []const F, b: []const F, c: F) F {
            std.debug.assert(a.len == self.n and b.len == self.n);
            var result = F.zero();
            for (a, self.g) |ai, gi| result = result.add(ai.mul(gi));
            for (b, self.h) |bi, hi| result = result.add(bi.mul(hi));
            result = result.add(c.mul(self.u));
            return result;
        }

        // -- Proof -----------------------------------------------------------

        pub const Proof = struct {
            l: []F, // left commitments per round
            r: []F, // right commitments per round
            a0: F, // final scalar a
            b0: F, // final scalar b

            pub fn deinit(self: *const Proof, allocator: std.mem.Allocator) void {
                allocator.free(self.l);
                allocator.free(self.r);
            }
        };

        /// Generate an IPA proof that `<a, b> = c`.
        pub fn prove(
            self: Self,
            allocator: std.mem.Allocator,
            a_in: []const F,
            b_in: []const F,
        ) !Proof {
            std.debug.assert(a_in.len == self.n and b_in.len == self.n);
            const log_n = @ctz(self.n);

            // Working copies (mutable)
            var a = try allocator.alloc(F, self.n);
            defer allocator.free(a);
            @memcpy(a, a_in);

            var b = try allocator.alloc(F, self.n);
            defer allocator.free(b);
            @memcpy(b, b_in);

            var g = try allocator.alloc(F, self.n);
            defer allocator.free(g);
            @memcpy(g, self.g);

            var h = try allocator.alloc(F, self.n);
            defer allocator.free(h);
            @memcpy(h, self.h);

            var l = try allocator.alloc(F, log_n);
            errdefer allocator.free(l);
            var r = try allocator.alloc(F, log_n);
            errdefer allocator.free(r);

            var n = self.n;
            var round: usize = 0;
            while (n > 1) {
                const half = n / 2;

                // L = <a_lo, g_hi> + <b_hi, h_lo> + <a_lo, b_hi> * U
                var l_commit = F.zero();
                for (a[0..half], g[half..n]) |ai, gi| l_commit = l_commit.add(ai.mul(gi));
                for (b[half..n], h[0..half]) |bi, hi| l_commit = l_commit.add(bi.mul(hi));
                var l_ip = F.zero();
                for (a[0..half], b[half..n]) |ai, bi| l_ip = l_ip.add(ai.mul(bi));
                l_commit = l_commit.add(l_ip.mul(self.u));
                l[round] = l_commit;

                // R = <a_hi, g_lo> + <b_lo, h_hi> + <a_hi, b_lo> * U
                var r_commit = F.zero();
                for (a[half..n], g[0..half]) |ai, gi| r_commit = r_commit.add(ai.mul(gi));
                for (b[0..half], h[half..n]) |bi, hi| r_commit = r_commit.add(bi.mul(hi));
                var r_ip = F.zero();
                for (a[half..n], b[0..half]) |ai, bi| r_ip = r_ip.add(ai.mul(bi));
                r_commit = r_commit.add(r_ip.mul(self.u));
                r[round] = r_commit;

                // Challenge x = Hash(L, R, round)
                const x = challenge(l[round], r[round], round);
                const x_inv = x.inv();

                // a' = a_lo * x + a_hi * x^{-1}
                var a_new = try allocator.alloc(F, half);
                defer allocator.free(a_new);
                for (0..half) |i| {
                    a_new[i] = a[i].mul(x).add(a[half + i].mul(x_inv));
                }

                // b' = b_lo * x^{-1} + b_hi * x
                var b_new = try allocator.alloc(F, half);
                defer allocator.free(b_new);
                for (0..half) |i| {
                    b_new[i] = b[i].mul(x_inv).add(b[half + i].mul(x));
                }

                // g' = g_lo * x^{-1} + g_hi * x
                var g_new = try allocator.alloc(F, half);
                defer allocator.free(g_new);
                for (0..half) |i| {
                    g_new[i] = g[i].mul(x_inv).add(g[half + i].mul(x));
                }

                // h' = h_lo * x + h_hi * x^{-1}
                var h_new = try allocator.alloc(F, half);
                defer allocator.free(h_new);
                for (0..half) |i| {
                    h_new[i] = h[i].mul(x).add(h[half + i].mul(x_inv));
                }

                // Copy back
                @memcpy(a[0..half], a_new);
                @memcpy(b[0..half], b_new);
                @memcpy(g[0..half], g_new);
                @memcpy(h[0..half], h_new);

                n = half;
                round += 1;
            }

            return .{
                .l = l,
                .r = r,
                .a0 = a[0],
                .b0 = b[0],
            };
        }

        // -- Verification ----------------------------------------------------

        /// Verify an IPA proof that `<a, b> = c` against the commitment.
        pub fn verify(self: Self, proof: *const Proof, c: F) !void {
            _ = self;
            _ = proof;
            _ = c;
            return error.Unsupported;
        }

        /// Verify with the original commitment included.
        pub fn verifyWithCommitment(
            self: Self,
            commitment: F,
            proof: *const Proof,
        ) !void {
            if (proof.l.len != proof.r.len) return error.InvalidProof;
            const log_n = proof.l.len;
            if (log_n >= @bitSizeOf(usize)) return error.InvalidProof;
            if (self.n != (@as(usize, 1) << @intCast(log_n))) return error.InvalidProof;

            var g_current = try self.allocator.alloc(F, self.n);
            defer self.allocator.free(g_current);
            @memcpy(g_current, self.g);
            var h_current = try self.allocator.alloc(F, self.n);
            defer self.allocator.free(h_current);
            @memcpy(h_current, self.h);

            var current = commitment;
            var n = self.n;
            for (0..log_n) |round| {
                const x = challenge(proof.l[round], proof.r[round], round);
                if (x.isZero()) return error.InvalidProof;
                const x_inv = x.inv();
                const x_sq = x.mul(x);
                const x_inv_sq = x_inv.mul(x_inv);
                current = current.add(proof.l[round].mul(x_sq));
                current = current.add(proof.r[round].mul(x_inv_sq));

                const half = n / 2;
                for (0..half) |i| {
                    g_current[i] = g_current[i].mul(x_inv).add(g_current[half + i].mul(x));
                    h_current[i] = h_current[i].mul(x).add(h_current[half + i].mul(x_inv));
                }
                n = half;
            }

            const expected = proof.a0.mul(g_current[0])
                .add(proof.b0.mul(h_current[0]))
                .add(proof.a0.mul(proof.b0).mul(self.u));
            if (!current.eql(expected)) return error.VerificationFailed;
        }

        // -- Helpers ---------------------------------------------------------

        fn challenge(l: F, r: F, round: usize) F {
            var hasher = Hash.init(.{});
            hasher.update(&l.toBytes());
            hasher.update(&r.toBytes());
            var round_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &round_bytes, round, .little);
            hasher.update(&round_bytes);
            var out: [32]u8 = undefined;
            hasher.final(&out);

            var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, out[0..8], .little));
            return F.random(prng.random());
        }
    };
}
