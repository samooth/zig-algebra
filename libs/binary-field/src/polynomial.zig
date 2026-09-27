const std = @import("std");

/// A multilinear polynomial over a binary field `F` in `k` variables, stored
/// as its table of evaluations on the hypercube {0,1}^k (2^k entries).
///
/// Every function on the boolean hypercube extends uniquely to a multilinear
/// polynomial (the *multilinear extension*, MLE); that extension is exactly
/// what the sum-check protocol commits to and what Bitcoin Script re-evaluates
/// during final verification.
pub fn Multilinear(comptime Field: type) type {
    return struct {
        const Self = @This();

        /// Evaluations indexed by variable bit-vector: index i has bit j =
        /// value of variable j (LSB first), and evals[i] = f(i's bits).
        evals: []const Field,

        /// Number of variables `k`, so that `evals.len == 2^k`.
        ///
        /// Total: returns 0 for a table that is not a power of two (including
        /// the empty table), which used to trip `log2_int(0)`/the assert. Use
        /// `numVarsChecked` to detect the malformed case.
        pub fn numVars(self: Self) usize {
            return numVarsChecked(self) catch 0;
        }

        /// `k` with `2^k == evals.len`, or `error.NotPowerOfTwo`.
        pub fn numVarsChecked(self: Self) error{NotPowerOfTwo}!usize {
            if (self.evals.len == 0) return error.NotPowerOfTwo;
            const k = std.math.log2_int(usize, self.evals.len);
            if ((@as(usize, 1) << @intCast(k)) != self.evals.len) return error.NotPowerOfTwo;
            return k;
        }

        /// The sum of f over the whole hypercube (used as the claimed value H).
        pub fn hypercubeSum(self: Self) Field {
            var acc = Field.zero();
            for (self.evals) |v| acc = acc.add(v);
            return acc;
        }

        /// Evaluate the MLE at an arbitrary field point `r` of length k.
        /// Standard repeated-folding: in each round every pair (a, b) at
        /// positions (2i, 2i+1) becomes (1 - r_i)*a + r_i*b, the linear
        /// polynomial that interpolates (0 -> a, 1 -> b) at r_i. Over a binary
        /// field this is the same as a + r_i*(a + b), which is why it used to
        /// be written that way; the general form is what holds for a prime
        /// field, and it is checked against one in `prime_fixture.zig`.
        ///
        /// `error.NotPowerOfTwo` for a malformed table, `error.InvalidPointLength`
        /// when `r.len != k` (the old assert let a short `r` fold the table
        /// down past its first entry in ReleaseFast, and a long `r` fold it to
        /// zero entries).
        pub fn eval(self: Self, allocator: std.mem.Allocator, r: []const Field) !Field {
            const k = try self.numVarsChecked();
            if (r.len != k) return error.InvalidPointLength;
            var cur = try allocator.dupe(Field, self.evals);
            defer allocator.free(cur);

            var len = cur.len;
            for (r) |ri| {
                const half = len / 2;
                for (0..half) |i| {
                    const a = cur[2 * i];
                    const b = cur[2 * i + 1];
                    cur[i] = Field.one().sub(ri).mul(a).add(ri.mul(b));
                }
                len = half;
            }
            return cur[0];
        }

        /// Fix the first `r.len` variables at the point `r` and return the
        /// evaluation table over the remaining `k - r.len` variables. This is
        /// the same folding as `eval`, stopped early: `eval` is `extend`
        /// followed by a final hypercube sum.
        ///
        /// `error.NotPowerOfTwo` for a malformed table, `error.InvalidPointLength`
        /// when `r.len > k` (checked before allocating, so nothing leaks).
        pub fn extend(self: Self, allocator: std.mem.Allocator, r: []const Field) ![]Field {
            const k = try self.numVarsChecked();
            if (r.len > k) return error.InvalidPointLength;
            var cur = try allocator.dupe(Field, self.evals);
            var len = cur.len;
            for (r) |ri| {
                const half = len / 2;
                for (0..half) |i| {
                    const a = cur[2 * i];
                    const b = cur[2 * i + 1];
                    cur[i] = Field.one().sub(ri).mul(a).add(ri.mul(b));
                }
                len = half;
            }
            return allocator.realloc(cur, len);
        }
    };
}

/// Constructs the multilinear polynomial from an explicit evaluation table.
pub fn fromEvals(comptime Field: type, evals: []const Field) Multilinear(Field) {
    return .{ .evals = evals };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Gf16 = @import("field.zig").Gf16;
const FTest = Gf16;

fn fe(x: u128) FTest {
    return FTest.fromInt(x);
}

test "mle eval matches multilinear formula on small hypercube" {
    const alloc = std.testing.allocator;
    // f(x0, x1) with table = [f00, f10, f01, f11] (bit 0 = x0).
    // Take f(x0,x1) = x0 + 2*x1 over GF(2): table [0,1,2,3].
    const evals = [_]FTest{ fe(0), fe(1), fe(2), fe(3) };
    const p = fromEvals(FTest, &evals);
    try std.testing.expectEqual(@as(usize, 2), p.numVars());

    // MLE of f is: 0*(1+x0)(1+x1) + 1*x0*(1+x1) + 2*(1+x0)*x1 + 3*x0*x1.
    // At r = (r0, r1) = (3, 5): verified against direct Lagrange evaluation.
    const r = [_]FTest{ fe(3), fe(5) };
    const got = try p.eval(alloc, &r);
    try std.testing.expectEqual(@as(u128, 9), got.value);
}

test "mle eval agrees with direct boolean hypercube sum formula" {
    const alloc = std.testing.allocator;
    // Random-ish table over k=4 vars.
    var evals_buf: [16]FTest = undefined;
    for (0..16) |i| evals_buf[i] = fe((i * 7 + 3) % 16);
    const p = fromEvals(FTest, &evals_buf);

    // Pick a point with coordinates in {0,1}: MLE must equal table value.
    const r = [_]FTest{ fe(1), fe(0), fe(1), fe(0) };
    const got = try p.eval(alloc, &r);
    try std.testing.expectEqual(@as(u128, evals_buf[0b0101].value), got.value);
}

test "mle eval at r=0 equals f(0,..,0)" {
    const alloc = std.testing.allocator;
    const evals = [_]FTest{ fe(5), fe(9), fe(2), fe(7) };
    const p = fromEvals(FTest, &evals);
    const r = [_]FTest{ FTest.zero(), FTest.zero() };
    try std.testing.expectEqual(@as(u128, 5), (try p.eval(alloc, &r)).value);
}

test "mle eval at r=1 equals hypercube sum of linear form" {
    const alloc = std.testing.allocator;
    // f(x0,x1) = x0: table [0,1,0,1]. MLE at (1,1) should be 1.
    const evals = [_]FTest{ fe(0), fe(1), fe(0), fe(1) };
    const p = fromEvals(FTest, &evals);
    const r = [_]FTest{ FTest.one(), FTest.one() };
    try std.testing.expectEqual(@as(u128, 1), (try p.eval(alloc, &r)).value);
}

test "hypercube sum of evals" {
    const evals = [_]FTest{ fe(1), fe(2), fe(3), fe(4) };
    const p = fromEvals(FTest, &evals);
    // 1 ^ 2 ^ 3 ^ 4 = 4
    try std.testing.expectEqual(@as(u128, 4), p.hypercubeSum().value);
}

test "extend produces the full table from partial assignments" {
    const alloc = std.testing.allocator;
    const evals = [_]FTest{ fe(0), fe(1), fe(2), fe(3) };
    const p = fromEvals(FTest, &evals);
    // Extend the first variable at r0=3 -> the table of the (k-1)-variable MLE.
    const r = [_]FTest{fe(3)};
    const out = try p.extend(alloc, &r);
    defer alloc.free(out);
    // full f(x0,x1) = x0 + 2x1. Fixing x0=3 gives 3 + 2*x1: values [3, 3+2=1]...
    // In char 2, 3 + 2*x1: x1=0 -> 3, x1=1 -> 3+2 = 1.
    try std.testing.expectEqual(@as(u128, 3), out[0].value);
    try std.testing.expectEqual(@as(u128, 1), out[1].value);
}

test "malformed tables and points are typed errors, not out-of-bounds access" {
    const alloc = std.testing.allocator;
    const evals = [_]FTest{ fe(0), fe(1), fe(2), fe(3) };

    // Point longer than the table: rejected instead of folding to zero entries.
    const too_long = [_]FTest{ fe(1), fe(2), fe(3) };
    const p = fromEvals(FTest, &evals);
    try std.testing.expectError(error.InvalidPointLength, p.eval(alloc, &too_long));
    try std.testing.expectError(error.InvalidPointLength, p.extend(alloc, &too_long));

    // Point shorter than the table: rejected instead of evaluating at the
    // wrong dimension.
    const too_short = [_]FTest{fe(1)};
    try std.testing.expectError(error.InvalidPointLength, p.eval(alloc, &too_short));

    // Non power-of-two and empty tables: `numVars` is total, `numVarsChecked`
    // reports the problem, and eval/extend propagate it.
    const odd = [_]FTest{ fe(1), fe(2), fe(3) };
    const odd_p = fromEvals(FTest, &odd);
    try std.testing.expectError(error.NotPowerOfTwo, odd_p.numVarsChecked());
    try std.testing.expectEqual(@as(usize, 0), odd_p.numVars());
    try std.testing.expectError(error.NotPowerOfTwo, odd_p.eval(alloc, &too_short));
    try std.testing.expectError(error.NotPowerOfTwo, odd_p.extend(alloc, &too_short));

    const empty = [_]FTest{};
    const empty_p = fromEvals(FTest, &empty);
    try std.testing.expectError(error.NotPowerOfTwo, empty_p.numVarsChecked());
    try std.testing.expectEqual(@as(usize, 0), empty_p.numVars());
    try std.testing.expectError(error.NotPowerOfTwo, empty_p.eval(alloc, &too_short));
    try std.testing.expectError(error.NotPowerOfTwo, empty_p.extend(alloc, &too_short));

    // Single-entry table is a valid 0-variable polynomial.
    const single = [_]FTest{fe(9)};
    const single_p = fromEvals(FTest, &single);
    try std.testing.expectEqual(@as(usize, 0), try single_p.numVarsChecked());
    try std.testing.expectEqual(@as(u128, 9), (try single_p.eval(alloc, &[_]FTest{})).value);
}
