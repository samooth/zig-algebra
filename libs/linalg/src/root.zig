//! zig-linalg: Linear algebra over finite fields.
//!
//! Provides vector and matrix operations, linear system solving,
//! and matrix decompositions over any field from zig-field.

const std = @import("std");
const traits = @import("zig-algebra-traits");
const testing = std.testing;

/// Vector over field F with compile-time known dimension.
pub fn Vector(comptime F: type, comptime n: usize) type {
    traits.assertField(F);

    return struct {
        const Self = @This();
        data: [n]F,

        pub fn zero() Self {
            return .{ .data = std.mem.zeroes([n]F) };
        }

        pub fn fromArray(arr: [n]F) Self {
            return .{ .data = arr };
        }

        pub fn get(self: Self, i: usize) F {
            return self.data[i];
        }

        pub fn set(self: *Self, i: usize, val: F) void {
            self.data[i] = val;
        }

        pub fn add(self: Self, other: Self) Self {
            var result: [n]F = undefined;
            for (0..n) |i| result[i] = self.data[i].add(other.data[i]);
            return .{ .data = result };
        }

        pub fn sub(self: Self, other: Self) Self {
            var result: [n]F = undefined;
            for (0..n) |i| result[i] = self.data[i].sub(other.data[i]);
            return .{ .data = result };
        }

        pub fn neg(self: Self) Self {
            var result: [n]F = undefined;
            for (0..n) |i| result[i] = self.data[i].neg();
            return .{ .data = result };
        }

        pub fn scale(self: Self, scalar: F) Self {
            var result: [n]F = undefined;
            for (0..n) |i| result[i] = self.data[i].mul(scalar);
            return .{ .data = result };
        }

        pub fn dot(self: Self, other: Self) F {
            var sum = F.zero();
            for (0..n) |i| {
                sum = sum.add(self.data[i].mul(other.data[i]));
            }
            return sum;
        }

        pub fn norm2(self: Self) F {
            return self.dot(self);
        }

        pub fn eql(self: Self, other: Self) bool {
            for (0..n) |i| {
                if (!self.data[i].eql(other.data[i])) return false;
            }
            return true;
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("[", .{});
            for (0..n) |i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("{}", .{self.data[i]});
            }
            try writer.print("]", .{});
        }
    };
}

/// Matrix over field F with compile-time known dimensions.
pub fn Matrix(comptime F: type, comptime rows: usize, comptime cols: usize) type {
    traits.assertField(F);

    return struct {
        const Self = @This();
        data: [rows][cols]F,

        pub fn zero() Self {
            return .{ .data = std.mem.zeroes([rows][cols]F) };
        }

        /// # Errors
        /// `error.NotSquare` when `rows != cols`. The old `std.debug.assert` is
        /// compiled out in `ReleaseFast`, where `m.data[i][i]` then wrote past
        /// the end of the shorter rows.
        pub fn identity() error{NotSquare}!Self {
            if (rows != cols) return error.NotSquare;
            var m: Self = .zero();
            for (0..rows) |i| m.data[i][i] = F.one();
            return m;
        }

        pub fn fromArray(arr: [rows][cols]F) Self {
            return .{ .data = arr };
        }

        pub fn get(self: Self, r: usize, c: usize) F {
            return self.data[r][c];
        }

        pub fn set(self: *Self, r: usize, c: usize, val: F) void {
            self.data[r][c] = val;
        }

        pub fn row(self: Self, r: usize) Vector(F, cols) {
            return Vector(F, cols).fromArray(self.data[r]);
        }

        pub fn col(self: Self, c: usize) Vector(F, rows) {
            var v: Vector(F, rows) = undefined;
            for (0..rows) |i| v.data[i] = self.data[i][c];
            return v;
        }

        pub fn setRow(self: *Self, r: usize, vec: Vector(F, cols)) void {
            self.data[r] = vec.data;
        }

        pub fn setCol(self: *Self, c: usize, vec: Vector(F, rows)) void {
            for (0..rows) |i| self.data[i][c] = vec.data[i];
        }

        pub fn transpose(self: Self) Matrix(F, cols, rows) {
            var result: Matrix(F, cols, rows) = undefined;
            for (0..rows) |i| {
                for (0..cols) |j| {
                    result.data[j][i] = self.data[i][j];
                }
            }
            return result;
        }

        pub fn add(self: Self, other: Self) Self {
            var result: Self = undefined;
            for (0..rows) |i| {
                for (0..cols) |j| {
                    result.data[i][j] = self.data[i][j].add(other.data[i][j]);
                }
            }
            return result;
        }

        pub fn sub(self: Self, other: Self) Self {
            var result: Self = undefined;
            for (0..rows) |i| {
                for (0..cols) |j| {
                    result.data[i][j] = self.data[i][j].sub(other.data[i][j]);
                }
            }
            return result;
        }

        pub fn scale(self: Self, scalar: F) Self {
            var result: Self = undefined;
            for (0..rows) |i| {
                for (0..cols) |j| {
                    result.data[i][j] = self.data[i][j].mul(scalar);
                }
            }
            return result;
        }

        pub fn mul(self: Self, comptime OtherCols: usize, other: Matrix(F, cols, OtherCols)) Matrix(F, rows, OtherCols) {
            var result: Matrix(F, rows, OtherCols) = .zero();
            for (0..rows) |i| {
                for (0..OtherCols) |j| {
                    var sum = F.zero();
                    for (0..cols) |k| {
                        sum = sum.add(self.data[i][k].mul(other.data[k][j]));
                    }
                    result.data[i][j] = sum;
                }
            }
            return result;
        }

        pub fn mulVec(self: Self, vec: Vector(F, cols)) Vector(F, rows) {
            var result: Vector(F, rows) = .zero();
            for (0..rows) |i| {
                var sum = F.zero();
                for (0..cols) |j| {
                    sum = sum.add(self.data[i][j].mul(vec.data[j]));
                }
                result.data[i] = sum;
            }
            return result;
        }

        /// # Errors
        /// `error.NotSquare` when `rows != cols`; the old `std.debug.assert`
        /// vanished in `ReleaseFast` and the diagonal read went out of bounds.
        pub fn trace(self: Self) error{NotSquare}!F {
            if (rows != cols) return error.NotSquare;
            var sum = F.zero();
            for (0..rows) |i| sum = sum.add(self.data[i][i]);
            return sum;
        }

        /// # Errors
        /// `error.NotSquare` when `rows != cols`; the old `std.debug.assert`
        /// vanished in `ReleaseFast` and the elimination indexed out of bounds.
        pub fn determinant(self: Self) error{NotSquare}!F {
            if (rows != cols) return error.NotSquare;
            if (rows == 1) return self.data[0][0];
            if (rows == 2) {
                return self.data[0][0].mul(self.data[1][1]).sub(self.data[0][1].mul(self.data[1][0]));
            }
            // Gaussian elimination for larger matrices
            var mat = self;
            var det = F.one();
            for (0..rows) |col_idx| {
                // Find pivot
                var pivot_row: ?usize = null;
                for (col_idx..rows) |row_idx| {
                    if (!mat.data[row_idx][col_idx].isZero()) {
                        pivot_row = row_idx;
                        break;
                    }
                }
                if (pivot_row == null) return F.zero();
                if (pivot_row.? != col_idx) {
                    // Swap rows
                    for (0..cols) |j| {
                        const tmp = mat.data[col_idx][j];
                        mat.data[col_idx][j] = mat.data[pivot_row.?][j];
                        mat.data[pivot_row.?][j] = tmp;
                    }
                    det = det.neg();
                }
                const pivot = mat.data[col_idx][col_idx];
                det = det.mul(pivot);
                // Scale pivot row
                const pivot_inv = pivot.inv();
                for (col_idx..cols) |j| {
                    mat.data[col_idx][j] = mat.data[col_idx][j].mul(pivot_inv);
                }
                // Eliminate below
                for (col_idx + 1..rows) |row_idx| {
                    const factor = mat.data[row_idx][col_idx];
                    if (!factor.isZero()) {
                        for (col_idx..cols) |j| {
                            mat.data[row_idx][j] = mat.data[row_idx][j].sub(factor.mul(mat.data[col_idx][j]));
                        }
                    }
                }
            }
            return det;
        }

        /// LU decomposition: returns (L, U, P) where P * A = L * U
        /// L is lower triangular with unit diagonal, U is upper triangular
        /// # Errors
        /// `error.NotSquare} when `rows != cols`; the old `std.debug.assert`
        /// vanished in `ReleaseFast` and the decomposition indexed out of
        /// bounds.
        pub fn lu(self: Self) error{NotSquare}!LU(F, rows) {
            if (rows != cols) return error.NotSquare;
            var L = try Matrix(F, rows, rows).identity();
            var U = self;
            var P = try Matrix(F, rows, rows).identity();

            for (0..rows) |col_idx| {
                // Find pivot
                var pivot_row: ?usize = null;
                var max_val = F.zero();
                for (col_idx..rows) |row_idx| {
                    const val = U.data[row_idx][col_idx];
                    if (!val.isZero() and (val.lexicographicCmp(max_val) > 0 or max_val.isZero())) {
                        max_val = val;
                        pivot_row = row_idx;
                    }
                }
                if (pivot_row == null) continue; // Singular

                if (pivot_row.? != col_idx) {
                    // Swap rows in U
                    for (0..cols) |j| {
                        const tmp = U.data[col_idx][j];
                        U.data[col_idx][j] = U.data[pivot_row.?][j];
                        U.data[pivot_row.?][j] = tmp;
                    }
                    // Swap rows in P
                    for (0..cols) |j| {
                        const tmp = P.data[col_idx][j];
                        P.data[col_idx][j] = P.data[pivot_row.?][j];
                        P.data[pivot_row.?][j] = tmp;
                    }
                    // Swap rows in L (only previous columns)
                    for (0..col_idx) |j| {
                        const tmp = L.data[col_idx][j];
                        L.data[col_idx][j] = L.data[pivot_row.?][j];
                        L.data[pivot_row.?][j] = tmp;
                    }
                }

                const pivot = U.data[col_idx][col_idx];
                for (col_idx + 1..rows) |row_idx| {
                    const factor = U.data[row_idx][col_idx].mul(pivot.inv());
                    L.data[row_idx][col_idx] = factor;
                    for (col_idx..cols) |j| {
                        U.data[row_idx][j] = U.data[row_idx][j].sub(factor.mul(U.data[col_idx][j]));
                    }
                }
            }

            return .{ .L = L, .U = U, .P = P };
        }

        /// Solve A * x = b using LU decomposition.
        ///
        /// # Errors
        /// `error.NotSquare` when `rows != cols`; the old `std.debug.assert`
        /// vanished in `ReleaseFast` and the substitution indexed out of
        /// bounds. A `null` result means the matrix is singular.
        pub fn solve(self: Self, b: Vector(F, rows)) error{NotSquare}!?Vector(F, rows) {
            const lu_decomp = try self.lu();
            // Apply permutation: Pb
            const Pb = lu_decomp.P.mulVec(b);
            // Forward substitution: L * y = Pb
            var y = Vector(F, rows).zero();
            for (0..rows) |i| {
                var sum = Pb.data[i];
                for (0..i) |j| {
                    sum = sum.sub(lu_decomp.L.data[i][j].mul(y.data[j]));
                }
                y.data[i] = sum;
            }
            // Backward substitution: U * x = y
            var x = Vector(F, rows).zero();
            var i: usize = rows;
            while (i > 0) {
                i -= 1;
                var sum = y.data[i];
                for (i + 1..rows) |j| {
                    sum = sum.sub(lu_decomp.U.data[i][j].mul(x.data[j]));
                }
                if (lu_decomp.U.data[i][i].isZero()) return null;
                x.data[i] = sum.mul(lu_decomp.U.data[i][i].inv());
            }
            return x;
        }

        pub fn eql(self: Self, other: Self) bool {
            for (0..rows) |i| {
                for (0..cols) |j| {
                    if (!self.data[i][j].eql(other.data[i][j])) return false;
                }
            }
            return true;
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("[", .{});
            for (0..rows) |i| {
                if (i > 0) try writer.print(",\n ", .{});
                try writer.print("[", .{});
                for (0..cols) |j| {
                    if (j > 0) try writer.print(", ", .{});
                    try writer.print("{}", .{self.data[i][j]});
                }
                try writer.print("]", .{});
            }
            try writer.print("]", .{});
        }
    };
}

/// Result of LU decomposition
pub fn LU(comptime F: type, comptime n: usize) type {
    return struct {
        L: Matrix(F, n, n),
        U: Matrix(F, n, n),
        P: Matrix(F, n, n),
    };
}

// Helper function to create test field F7
fn F7Type() type {
    return struct {
        const Self = @This();
        value: u64,
        pub const modulus: u64 = 7;
        pub const characteristic: u64 = 7;
        pub const order: u64 = 7;
        pub fn zero() Self {
            return .{ .value = 0 };
        }
        pub fn one() Self {
            return .{ .value = 1 };
        }
        pub fn fromInt(x: u256) Self {
            return .{ .value = @intCast(x % modulus) };
        }
        pub fn toInt(self: Self) u64 {
            return self.value;
        }
        pub fn eql(a: Self, b: Self) bool {
            return a.value == b.value;
        }
        pub fn add(a: Self, b: Self) Self {
            return fromInt(a.value + b.value);
        }
        pub fn sub(a: Self, b: Self) Self {
            return fromInt(a.value + (modulus - b.value % modulus));
        }
        pub fn neg(a: Self) Self {
            return if (a.value == 0) zero() else fromInt(modulus - a.value);
        }
        pub fn mul(a: Self, b: Self) Self {
            return fromInt(a.value * b.value);
        }
        /// Legacy total inverse: `inv(0) == zero()`. Zero is not an inverse;
        /// new code that requires invertibility must call `invChecked`.
        pub fn inv(a: Self) Self {
            if (a.isZero()) return zero();
            return pow(a, modulus - 2);
        }
        pub fn invChecked(a: Self) error{InverseOfZero}!Self {
            if (a.isZero()) return error.InverseOfZero;
            return pow(a, modulus - 2);
        }
        pub const inverse = inv;
        /// Legacy total division: `x / 0 == zero()`. Zero is not a quotient;
        /// new code that requires an invertible divisor must call `divChecked`.
        pub fn div(a: Self, b: Self) Self {
            return mul(a, inv(b));
        }
        pub fn divChecked(a: Self, b: Self) error{InverseOfZero}!Self {
            return mul(a, try b.invChecked());
        }
        pub fn pow(base: Self, exp: u64) Self {
            var r = one();
            var b = base;
            var e = exp;
            while (e > 0) {
                if ((e & 1) == 1) r = mul(r, b);
                b = mul(b, b);
                e >>= 1;
            }
            return r;
        }
        pub fn lexicographicCmp(a: Self, b: Self) i8 {
            return if (a.value < b.value) -1 else if (a.value > b.value) 1 else 0;
        }
        pub fn isZero(self: Self) bool {
            return self.value == 0;
        }
        pub fn random() Self {
            return fromInt(1);
        }
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{}", .{self.value});
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Vector basic operations" {
    const F7 = F7Type();
    const V3 = Vector(F7, 3);
    const a = V3.fromArray(.{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) });
    const b = V3.fromArray(.{ F7.fromInt(4), F7.fromInt(5), F7.fromInt(6) });

    try std.testing.expect(a.add(b).eql(V3.fromArray(.{ F7.fromInt(5), F7.fromInt(0), F7.fromInt(2) })));
    try std.testing.expect(a.sub(b).eql(V3.fromArray(.{ F7.fromInt(4), F7.fromInt(4), F7.fromInt(4) })));
    try std.testing.expect(a.neg().eql(V3.fromArray(.{ F7.fromInt(6), F7.fromInt(5), F7.fromInt(4) })));
    try std.testing.expect(a.scale(F7.fromInt(2)).eql(V3.fromArray(.{ F7.fromInt(2), F7.fromInt(4), F7.fromInt(6) })));
    try std.testing.expect(a.dot(b).eql(F7.fromInt(4))); // 1*4 + 2*5 + 3*6 = 4+3+4 = 11 = 4 (mod 7)
    try std.testing.expect(a.norm2().eql(F7.fromInt(0))); // 1+4+2 = 7 = 0
}

test "Matrix basic operations" {
    const F7 = F7Type();
    const M2 = Matrix(F7, 2, 2);
    const A = M2.fromArray(.{
        .{ F7.fromInt(1), F7.fromInt(2) },
        .{ F7.fromInt(3), F7.fromInt(4) },
    });
    const B = M2.fromArray(.{
        .{ F7.fromInt(5), F7.fromInt(6) },
        .{ F7.fromInt(0), F7.fromInt(1) },
    });

    // Addition
    try std.testing.expect(A.add(B).eql(M2.fromArray(.{
        .{ F7.fromInt(6), F7.fromInt(1) },
        .{ F7.fromInt(3), F7.fromInt(5) },
    })));

    // Subtraction
    try std.testing.expect(A.sub(B).eql(M2.fromArray(.{
        .{ F7.fromInt(3), F7.fromInt(3) },
        .{ F7.fromInt(3), F7.fromInt(3) },
    })));

    // Scalar multiplication
    try std.testing.expect(A.scale(F7.fromInt(2)).eql(M2.fromArray(.{
        .{ F7.fromInt(2), F7.fromInt(4) },
        .{ F7.fromInt(6), F7.fromInt(1) },
    })));

    // Matrix multiplication
    try std.testing.expect(A.mul(2, B).eql(M2.fromArray(.{
        .{ F7.fromInt(5), F7.fromInt(1) },
        .{ F7.fromInt(1), F7.fromInt(1) },
    })));

    // Transpose
    try std.testing.expect(A.transpose().eql(M2.fromArray(.{
        .{ F7.fromInt(1), F7.fromInt(3) },
        .{ F7.fromInt(2), F7.fromInt(4) },
    })));

    // Trace
    try std.testing.expect((try A.trace()).eql(F7.fromInt(5)));

    // Determinant
    try std.testing.expect((try A.determinant()).eql(F7.fromInt(5))); // 1*4 - 2*3 = 4 - 6 = -2 = 5 (mod 7)
}

test "Matrix identity" {
    const F7 = F7Type();
    const M3 = Matrix(F7, 3, 3);
    const I = try M3.identity();
    for (0..3) |i| {
        for (0..3) |j| {
            try std.testing.expect(I.data[i][j].eql(if (i == j) F7.one() else F7.zero()));
        }
    }
}

test "Matrix-vector multiplication" {
    const F7 = F7Type();
    const M2 = Matrix(F7, 2, 2);
    const V2 = Vector(F7, 2);
    const A = M2.fromArray(.{
        .{ F7.fromInt(1), F7.fromInt(2) },
        .{ F7.fromInt(3), F7.fromInt(4) },
    });
    const v = V2.fromArray(.{ F7.fromInt(5), F7.fromInt(6) });

    const result = A.mulVec(v);
    // [1*5 + 2*6, 3*5 + 4*6] = [5+12, 15+24] = [17, 39] = [3, 4] (mod 7)
    try std.testing.expect(result.data[0].eql(F7.fromInt(3)));
    try std.testing.expect(result.data[1].eql(F7.fromInt(4)));
}

test "LU decomposition and solve" {
    const F7 = F7Type();
    const M2 = Matrix(F7, 2, 2);
    const V2 = Vector(F7, 2);

    // A = [[2, 1], [1, 2]], det = 4-1=3
    const A = M2.fromArray(.{
        .{ F7.fromInt(2), F7.fromInt(1) },
        .{ F7.fromInt(1), F7.fromInt(2) },
    });

    // b = [1, 2]
    const b = V2.fromArray(.{ F7.fromInt(1), F7.fromInt(2) });

    // x = A^{-1} b
    const x = try A.solve(b) orelse unreachable;

    // Verify A * x = b
    const Ax = A.mulVec(x);
    try std.testing.expect(Ax.eql(b));

    // Also test LU decomposition
    const lu_decomp = try A.lu();
    // P * A = L * U
    const PA = lu_decomp.P.mul(2, A);
    const LU_prod = lu_decomp.L.mul(2, lu_decomp.U);
    try std.testing.expect(PA.eql(LU_prod));
}

test "Matrix 3x3 operations" {
    const F7 = F7Type();
    const M3 = Matrix(F7, 3, 3);
    const A = M3.fromArray(.{
        .{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) },
        .{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(4) },
        .{ F7.fromInt(5), F7.fromInt(6), F7.fromInt(0) },
    });

    // Determinant
    const det = try A.determinant();
    try std.testing.expect(!det.isZero());

    // Solve system
    const V3 = Vector(F7, 3);
    const b = V3.fromArray(.{ F7.fromInt(1), F7.fromInt(0), F7.fromInt(1) });
    const x = try A.solve(b) orelse unreachable;
    const Ax = A.mulVec(x);
    try std.testing.expect(Ax.eql(b));

    // Inverse via solve
    var inv = M3.zero();
    for (0..3) |i| {
        var e = V3.zero();
        e.data[i] = F7.one();
        const col = try A.solve(e) orelse unreachable;
        for (0..3) |j| inv.data[j][i] = col.data[j];
    }
    const I = A.mul(3, inv);
    for (0..3) |i| {
        for (0..3) |j| {
            try std.testing.expect(I.data[i][j].eql(if (i == j) F7.one() else F7.zero()));
        }
    }
}

test "Singular matrix detection" {
    const F7 = F7Type();
    const M2 = Matrix(F7, 2, 2);
    const V2 = Vector(F7, 2);

    // Singular matrix: [[1, 2], [2, 4]] (row 2 = 2 * row 1)
    const A = M2.fromArray(.{
        .{ F7.fromInt(1), F7.fromInt(2) },
        .{ F7.fromInt(2), F7.fromInt(4) },
    });

    try std.testing.expect((try A.determinant()).isZero());
    try std.testing.expect(try A.solve(V2.fromArray(.{ F7.fromInt(1), F7.fromInt(1) })) == null);
}

test "LU decomposition with partial pivoting" {
    const F7 = F7Type();
    const M3 = Matrix(F7, 3, 3);

    // Matrix that needs pivoting: zero in (0,0)
    const A = M3.fromArray(.{
        .{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(1) },
        .{ F7.fromInt(1), F7.fromInt(0), F7.fromInt(1) },
        .{ F7.fromInt(1), F7.fromInt(1), F7.fromInt(0) },
    });

    const lu_decomp = try A.lu();
    const PA = lu_decomp.P.mul(3, A);
    const LU_prod = lu_decomp.L.mul(3, lu_decomp.U);
    try std.testing.expect(PA.eql(LU_prod));

    // Test solve with this matrix
    const V3 = Vector(F7, 3);
    const b = V3.fromArray(.{ F7.fromInt(1), F7.fromInt(1), F7.fromInt(1) });
    const x = try A.solve(b) orelse unreachable;
    const Ax = A.mulVec(x);
    try std.testing.expect(Ax.eql(b));
}

test "Matrix with real field (Goldilocks)" {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;

    const M2 = Matrix(Goldilocks, 2, 2);
    const A = M2.fromArray(.{
        .{ Goldilocks.fromInt(1), Goldilocks.fromInt(2) },
        .{ Goldilocks.fromInt(3), Goldilocks.fromInt(4) },
    });
    const B = M2.fromArray(.{
        .{ Goldilocks.fromInt(5), Goldilocks.fromInt(6) },
        .{ Goldilocks.fromInt(7), Goldilocks.fromInt(8) },
    });

    try std.testing.expect(A.mul(2, B).eql(M2.fromArray(.{
        .{ Goldilocks.fromInt(19), Goldilocks.fromInt(22) },
        .{ Goldilocks.fromInt(43), Goldilocks.fromInt(50) },
    })));

    // Determinant: 1*4 - 2*3 = -2
    const det = try A.determinant();
    try std.testing.expect(!det.isZero());
}

test "Non-square matrices reject identity/trace/determinant/lu/solve" {
    const F7 = F7Type();
    const V2 = Vector(F7, 2);
    const Rect = Matrix(F7, 2, 3);
    const A = Rect.zero();
    const v2 = V2.fromArray(.{ F7.fromInt(1), F7.fromInt(2) });
    try std.testing.expectError(error.NotSquare, Rect.identity());
    try std.testing.expectError(error.NotSquare, A.trace());
    try std.testing.expectError(error.NotSquare, A.determinant());
    try std.testing.expectError(error.NotSquare, A.lu());
    try std.testing.expectError(error.NotSquare, A.solve(v2));

    // A row-vector shape fails the same way, in the other direction.
    const Wide = Matrix(F7, 3, 2);
    try std.testing.expectError(error.NotSquare, Wide.identity());
}

test "F7 legacy inv/div are total and the checked variants reject zero" {
    const F7 = F7Type();
    try std.testing.expect(F7.inv(F7.zero()).isZero());
    try std.testing.expect(F7.div(F7.one(), F7.zero()).isZero());
    try std.testing.expectError(error.InverseOfZero, F7.invChecked(F7.zero()));
    try std.testing.expectError(error.InverseOfZero, F7.divChecked(F7.one(), F7.zero()));
    // Non-zero inverse is the real inverse.
    for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |v| {
        const a = F7.fromInt(v);
        try std.testing.expect((try a.invChecked()).mul(a).eql(F7.one()));
        try std.testing.expect((try a.divChecked(F7.fromInt(3))).eql(a.mul(try F7.fromInt(3).invChecked())));
    }
}

// Example program
pub fn main() !void {
    const zf = @import("zig-field");
    const Goldilocks = zf.Goldilocks;

    const M3 = Matrix(Goldilocks, 3, 3);
    const V3 = Vector(Goldilocks, 3);

    var A = M3.fromArray(.{
        .{ Goldilocks.fromInt(2), Goldilocks.fromInt(1), Goldilocks.fromInt(1) },
        .{ Goldilocks.fromInt(1), Goldilocks.fromInt(3), Goldilocks.fromInt(2) },
        .{ Goldilocks.fromInt(1), Goldilocks.fromInt(0), Goldilocks.fromInt(4) },
    });

    const b = V3.fromArray(.{
        Goldilocks.fromInt(4),
        Goldilocks.fromInt(5),
        Goldilocks.fromInt(6),
    });

    const x = (try A.solve(b)) orelse {
        std.debug.print("No solution\n", .{});
        return;
    };

    std.debug.print("Solution: {}\n", .{x});
    std.debug.print("Verification A*x: {}\n", .{A.mulVec(x)});
}

// The expected values come from Python doing exact arithmetic over the same
// prime -- 7 for the local test field, the Goldilocks prime for the one case
// that uses a real field -- so they are properties of the algebra, not a
// transcript of this code.
//
// What is deliberately *not* compared: the entries of L and U. Pivoting is a
// convention, and a valid decomposition with a different pivot choice would
// still satisfy the identities below, so pinning the entries would pin the
// algorithm instead of the mathematics. What is compared: L*U == P*A, and
// that solving A x = b returns an x with A x = b.
test "linalg agrees with exact Python arithmetic on the properties, not the convention" {
    const F7 = F7Type();
    const V4 = Vector(F7, 4);
    const V3 = Vector(F7, 3);

    const Vec = struct { a: []const u64, b: []const u64, dot: u64, norm2: u64 };
    const vectors = [_]Vec{
        .{ .a = &.{ 1, 2, 3, 4 }, .b = &.{ 4, 5, 6, 0 }, .dot = 4, .norm2 = 2 },
        .{ .a = &.{ 6, 6, 6, 6 }, .b = &.{ 1, 0, 1, 0 }, .dot = 5, .norm2 = 4 },
        .{ .a = &.{ 2, 0, 0, 0 }, .b = &.{ 5, 0, 0, 0 }, .dot = 3, .norm2 = 4 },
        .{ .a = &.{ 3, 1, 4, 1 }, .b = &.{ 5, 3, 2, 1 }, .dot = 6, .norm2 = 6 },
    };
    for (vectors) |c| {
        const av = [4]F7{ F7.fromInt(c.a[0]), F7.fromInt(c.a[1]), F7.fromInt(c.a[2]), F7.fromInt(c.a[3]) };
        const bv = [4]F7{ F7.fromInt(c.b[0]), F7.fromInt(c.b[1]), F7.fromInt(c.b[2]), F7.fromInt(c.b[3]) };
        const a = V4.fromArray(av);
        const b = V4.fromArray(bv);
        try testing.expectEqual(c.dot, a.dot(b).toInt());
        try testing.expectEqual(c.norm2, a.norm2().toInt());
    }

    const Mat = struct { a: []const []const u64, at: []const []const u64, avec: []const u64, det: u64 };
    const matrices = [_]Mat{
        .{ .a = &[_][]const u64{ &.{ 1, 2, 0 }, &.{ 0, 1, 1 }, &.{ 2, 1, 1 } }, .at = &[_][]const u64{ &.{ 1, 0, 2 }, &.{ 2, 1, 1 }, &.{ 0, 1, 1 } }, .avec = &.{ 1, 0, 4 }, .det = 4 },
        .{ .a = &[_][]const u64{ &.{ 3, 1, 4 }, &.{ 1, 5, 2 }, &.{ 2, 6, 5 } }, .at = &[_][]const u64{ &.{ 3, 1, 2 }, &.{ 1, 5, 6 }, &.{ 4, 2, 5 } }, .avec = &.{ 4, 4, 0 }, .det = 1 },
        .{ .a = &[_][]const u64{ &.{ 0, 0, 0 }, &.{ 1, 2, 3 }, &.{ 4, 5, 6 } }, .at = &[_][]const u64{ &.{ 0, 1, 4 }, &.{ 0, 2, 5 }, &.{ 0, 3, 6 } }, .avec = &.{ 0, 6, 5 }, .det = 0 },
    };
    for (matrices) |c| {
        const M3 = Matrix(F7, 3, 3);
        var a: M3 = undefined;
        for (0..3) |i| {
            for (0..3) |j| a.data[i][j] = F7.fromInt(c.a[i][j]);
        }
        for (0..3) |i| {
            for (0..3) |j| {
                try testing.expectEqual(c.at[i][j], a.transpose().data[i][j].toInt());
            }
        }
        // The vector multiplied in is fixed; `avec` in the fixture is the
        // expected product, not the input.
        const av3 = [3]F7{ F7.fromInt(2), F7.fromInt(3), F7.fromInt(4) };
        const mv = a.mulVec(V3.fromArray(av3));
        for (0..3) |i| try testing.expectEqual(c.avec[i], mv.data[i].toInt());
        try testing.expectEqual(c.det, (try a.determinant()).toInt());
    }

    // Solves: a known x with b = A x, and the returned solution has to
    // reproduce it. The property, not the pivoting.
    const Sol = struct { a: []const []const u64, x: []const u64, b: []const u64 };
    const solves = [_]Sol{
        .{ .a = &[_][]const u64{ &.{ 1, 2, 3 }, &.{ 0, 1, 4 }, &.{ 5, 6, 0 } }, .x = &.{ 1, 2, 3 }, .b = &.{ 0, 0, 3 } },
        .{ .a = &[_][]const u64{ &.{ 2, 1, 0 }, &.{ 1, 3, 1 }, &.{ 0, 1, 4 } }, .x = &.{ 4, 5, 6 }, .b = &.{ 6, 4, 1 } },
        .{ .a = &[_][]const u64{ &.{ 1, 0, 2 }, &.{ 0, 1, 0 }, &.{ 3, 0, 1 } }, .x = &.{ 2, 0, 5 }, .b = &.{ 5, 0, 4 } },
        // A zero in the top-left forces a row swap during the first column, so
        // P is not the identity and `L*U == P*A` is not a tautology here.
        .{ .a = &[_][]const u64{ &.{ 0, 1, 0 }, &.{ 1, 0, 1 }, &.{ 0, 1, 1 } }, .x = &.{ 1, 2, 3 }, .b = &.{ 2, 4, 5 } },
    };
    for (solves) |c| {
        const M3 = Matrix(F7, 3, 3);
        var a: M3 = undefined;
        for (0..3) |i| {
            for (0..3) |j| a.data[i][j] = F7.fromInt(c.a[i][j]);
        }
        var bv: [3]F7 = undefined;
        var xv: [3]F7 = undefined;
        for (0..3) |i| {
            bv[i] = F7.fromInt(c.b[i]);
            xv[i] = F7.fromInt(c.x[i]);
        }
        const got = (try a.solve(V3.fromArray(bv))).?;
        for (0..3) |i| try testing.expectEqual(c.x[i], got.data[i].toInt());
        // And the returned vector really solves the system.
        const check = a.mulVec(got);
        for (0..3) |i| try testing.expectEqual(c.b[i], check.data[i].toInt());

        // L * U == P * A. Any correct decomposition with row pivoting
        // satisfies this; the entries of L and U do not have to match
        // anything, which is the point.
        const lu = try a.lu();
        const lhs = lu.L.mul(3, lu.U);
        const rhs = lu.P.mul(3, a);
        for (0..3) |i| {
            for (0..3) |j| try testing.expectEqual(rhs.data[i][j].toInt(), lhs.data[i][j].toInt());
        }
    }
}

// One case over a real prime rather than the mod-7 test field, so the
// Montgomery-backed paths are in the comparison too. The solution is again a
// property: b was computed as A x, and the returned x has to reproduce it.
test "linalg over Goldilocks agrees with exact Python arithmetic" {
    const zf = @import("zig-field");
    const G = zf.Goldilocks;
    const M2 = Matrix(G, 2, 2);
    var a: M2 = undefined;
    const rows = [_][2]u64{
        .{ 12345678901234567890, 9876543210987654321 },
        .{ 5555555555555555555, 1111111111111111111 },
    };
    for (0..2) |i| {
        for (0..2) |j| a.data[i][j] = G.fromInt(rows[i][j]);
    }
    const x = [_]u64{ 42, 7 };
    const b_expected = [_]u64{ 15805250176913317676, 1303438208721514914 };
    try testing.expectEqual(@as(u64, 7479327909597309152), (try a.determinant()).toU64());

    var bv: [2]G = undefined;
    for (0..2) |i| bv[i] = G.fromInt(b_expected[i]);
    const got = (try a.solve(Vector(G, 2).fromArray(bv))).?;
    for (0..2) |i| try testing.expectEqual(x[i], got.data[i].toU64());
}
