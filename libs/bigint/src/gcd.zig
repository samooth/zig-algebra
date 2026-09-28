//! Extended GCD and modular inverse for BigInt.
//!
//! Provides the Extended Euclidean Algorithm and modular multiplicative inverse
//! for arbitrary-precision integers.
//!
//! # Quick Start
//! ```zig
//! const Big = BigInt(8);
//! const G = ExtendedGcd(8);
//!
//! const a = Big.fromU64(240);
//! const b = Big.fromU64(46);
//! const res = G.egcd(a, b);
//! // res.g == gcd(240, 46) == 2
//! // res.x == -9, res.y == 47
//! // Verify: 240*(-9) + 46*47 = 2
//!
//! const inv = try G.modInv(Big.fromU64(3), Big.fromU64(11));
//! // inv == 4 because 3*4 = 12 = 1 (mod 11)
//! ```

const std = @import("std");
const bigint = @import("bigint.zig");

/// Extended GCD operations for a given BigInt precision.
///
/// `max_limbs` must match the precision of the `BigInt` instances you pass in.
pub fn ExtendedGcd(comptime max_limbs: usize) type {
    const Big = bigint.BigInt(max_limbs);

    return struct {
        /// Extended Euclidean Algorithm.
        ///
        /// Returns `(g, x, y)` such that `a*x + b*y = g = gcd(a, b)`.
        ///
        /// The result is normalized so that `g` is always non-negative.
        /// If `a` and `b` are both zero, `g` is zero.
        ///
        /// # Errors
        /// `error.Overflow` if an intermediate product needs more than
        /// `max_limbs` limbs. The intermediate `q * r` can be as wide as twice
        /// the modulus, so this is reachable for any modulus whose bit length
        /// reaches the container; it used to be `catch unreachable`, which is
        /// undefined behaviour in `ReleaseFast` and a trap elsewhere. See
        /// `modInv` for the width at which this stops being reachable.
        pub fn egcd(a: Big, b: Big) !struct { g: Big, x: Big, y: Big } {
            var old_r = a;
            var r = b;
            var old_s = Big.one();
            var s = Big.zero();
            var old_t = Big.zero();
            var t = Big.one();

            while (!r.isZero()) {
                const q = try old_r.div(r);

                const tmp_r = old_r;
                old_r = r;
                r = try tmp_r.sub(try q.mul(r));

                const tmp_s = old_s;
                old_s = s;
                s = try tmp_s.sub(try q.mul(s));

                const tmp_t = old_t;
                old_t = t;
                t = try tmp_t.sub(try q.mul(t));
            }

            // Ensure gcd is positive
            if (old_r.isNegative()) {
                old_r = old_r.neg();
                old_s = old_s.neg();
                old_t = old_t.neg();
            }

            return .{ .g = old_r, .x = old_s, .y = old_t };
        }

        /// Modular multiplicative inverse: `a^-1 mod m`.
        ///
        /// Returns `error.InvalidModulus` if `m <= 0`.
        /// Returns `error.NotInvertible` if `gcd(a, m) != 1`.
        /// Returns `error.Overflow` if the modulus is too wide for the
        /// container to hold the algorithm's intermediates.
        ///
        /// **There is no `bitLength(m)` bound that makes `error.Overflow`
        /// unreachable, and this doc does not pretend otherwise.** The
        /// intermediate `q * r` needs as many limbs as the sum of the
        /// significant limbs of `q` and `r`, and `BigInt.mul` rejects the
        /// product when that sum exceeds `max_limbs` (`bigint.zig:325`). For a
        /// modulus occupying all `max_limbs` limbs the first iteration already
        /// needs more than the container.
        ///
        /// The threshold is **not** a function of the modulus alone. Measured on
        /// a 256-bit container: the widest modulus that survives is **193 bits**
        /// for `a` in 2..13 and **218 bits** for `a = 2^31 - 1`, so the
        /// boundary moves with the trajectory of the Euclidean algorithm, not
        /// with `m`. A rule of the form "container minus one" or "container
        /// minus two" is therefore **unsafe** -- both admit inputs that
        /// overflow, and both were proposed before being measured.
        ///
        /// The rule that does hold: **size the `BigInt` with headroom for the
        /// modulus you intend** -- a 256-bit modulus in a 512-bit container --
        /// and treat `error.Overflow` as a real answer, not a bug. It never
        /// truncated; it aborted, and now it says so.
        ///
        /// # Example
        /// ```zig
        /// const inv = try G.modInv(Big.fromU64(3), Big.fromU64(11));
        /// // inv == 4
        /// ```
        pub fn modInv(a: Big, m: Big) !Big {
            if (m.isZero() or m.isNegative()) return error.InvalidModulus;
            const a_pos = try a.mod(m);
            const res = try egcd(a_pos, m);
            if (!res.g.eql(Big.one())) return error.NotInvertible;
            return res.x.mod(m);
        }
    };
}
