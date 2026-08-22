const std = @import("std");
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

    const x = A.solve(b) orelse {
        std.debug.print("No solution\n", .{});
        return;
    };

    std.debug.print("Solution: {}\n", .{x});
    std.debug.print("Verification A*x: {}\n", .{A.mulVec(x)});
}
