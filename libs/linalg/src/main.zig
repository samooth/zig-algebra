//! zig-linalg example: solve A x = b over Goldilocks, and *verify the solution*.
//!
//! Printing `A*x` shows the reader a residual; asserting it shows the build.
//! `lu` does not report singularity, so a system this example believed
//! invertible could silently produce a `x` with a wrong residual -- which is
//! exactly what a print cannot tell you from a correct one.

const std = @import("std");
const testing = std.testing;
const linalg = @import("zig-linalg");
const zf = @import("zig-field");

const Goldilocks = zf.Goldilocks;
const M3 = linalg.Matrix(Goldilocks, 3, 3);
const V3 = linalg.Vector(Goldilocks, 3);

pub fn main() !void {
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
        return error.NoSolution;
    };

    std.debug.print("Solution: {}\n", .{x});

    // The residual is the property: A*x must equal b, and it is compared
    // element by element against the right-hand side that was given, not
    // against anything the solver produced.
    const residual = A.mulVec(x);
    std.debug.print("Verification A*x: {}\n", .{residual});
    for (residual.data, b.data) |got, want| {
        try testing.expect(got.eql(want));
    }
    std.debug.print("A*x == b: verified\n", .{});
}
