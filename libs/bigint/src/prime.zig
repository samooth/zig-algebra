//! Primality testing: Miller-Rabin and trial division.
//!
//! Provides probabilistic primality testing for arbitrary-precision integers.
//!
//! # Quick Start
//! ```zig
//! const Big = BigInt(8);
//! const P = PrimalityTest(8);
//!
//! const n = Big.fromU64(104729);
//! const is_prime = try P.millerRabin(n, 7);
//! // is_prime == true (104729 is the 10000th prime)
//!
//! const composite = Big.fromU64(91);
//! const is_comp = try P.millerRabin(composite, 7);
//! // is_comp == false (91 = 7 * 13)
//! ```
//!
//! # Algorithm
//! 1. **Trial division** by the first 50 small primes (up to 229).
//!    This quickly eliminates most composites.
//! 2. **Miller-Rabin** with 7 deterministic bases for 64-bit integers.
//!    Error probability <= 4^(-7) for numbers < 2^64.

const std = @import("std");
const bigint = @import("bigint.zig");
const modexp = @import("modexp.zig");

/// Primality testing for a given BigInt precision.
///
/// `max_limbs` must match the precision of the `BigInt` instances you pass in.
pub fn PrimalityTest(comptime max_limbs: usize) type {
    const Big = bigint.BigInt(max_limbs);
    const ModExp = modexp.ModExp(max_limbs);

    // Small primes for trial division.
    const SMALL_PRIMES = [_]u32{
        2,   3,   5,   7,   11,  13,  17,  19,  23,  29,
        31,  37,  41,  43,  47,  53,  59,  61,  67,  71,
        73,  79,  83,  89,  97,  101, 103, 107, 109, 113,
        127, 131, 137, 139, 149, 151, 157, 163, 167, 173,
        179, 181, 191, 193, 197, 199, 211, 223, 227, 229,
    };

    return struct {
        /// Trial division by small primes.
        ///
        /// Returns `true` if `n` passes trial division (no small factor found),
        /// `false` if a small prime divides `n`.
        pub fn trialDivision(n: Big) bool {
            if (n.isZero() or n.isOne()) return false;
            const mag = n.abs();
            for (SMALL_PRIMES) |p| {
                const p_big = Big.fromU64(p);
                if (mag.eql(p_big)) return true;
                const rem = mag.rem(p_big) catch unreachable;
                if (rem.isZero()) return false;
            }
            return true;
        }

        /// Miller-Rabin primality test.
        ///
        /// Returns `true` if `n` is probably prime, `false` if composite.
        ///
        /// `rounds` determines accuracy.  For numbers < 2^64, 7 rounds with
        /// deterministic bases guarantees correctness.
        ///
        /// # Errors
        /// None currently, but may return errors for invalid inputs in the future.
        pub fn millerRabin(n: Big, rounds: usize) !bool {
            if (n.isZero() or n.isOne()) return false;
            if (n.isNegative()) return false;

            const mag = n.abs();

            // Check small primes
            if (!trialDivision(mag)) return false;

            // Write n-1 = d * 2^s
            var d = try mag.sub(Big.one());
            var s: usize = 0;
            while (!d.isZero() and (d.limbs[0] & 1) == 0) {
                d = d.shr(1);
                s += 1;
            }

            if (s == 0) {
                // n-1 is odd => n = 2, which is prime
                return true;
            }

            // Deterministic bases for 64-bit integers
            const bases = [_]u64{ 2, 325, 9375, 28178, 450775, 9780504, 1795265022 };
            const num_bases = @min(bases.len, rounds);

            for (0..num_bases) |i| {
                const a = Big.fromU64(bases[i]);
                if (a.cmp(mag) >= 0) continue;

                var x = try ModExp.modExpU64(a, d, mag);
                if (x.isOne() or x.eql(try mag.sub(Big.one()))) continue;

                var composite = true;
                for (1..s) |_| {
                    x = try (try x.mul(x)).mod(mag);
                    if (x.eql(try mag.sub(Big.one()))) {
                        composite = false;
                        break;
                    }
                }
                if (composite) return false;
            }
            return true;
        }

        /// Combined test: trial division + Miller-Rabin with 7 rounds.
        ///
        /// Convenience wrapper that applies both tests.
        pub fn isProbablyPrime(n: Big) !bool {
            return try millerRabin(n, 7);
        }
    };
}
