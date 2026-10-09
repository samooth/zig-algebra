//! zig-ntt consumer: transform, invert, and check the answer is the input.
//!
//! A round trip is the obvious property and it is the weak one -- it is
//! consistent with the transform being the wrong transform. So this also checks
//! the output against the definition: for each index k the coefficient must
//! equal sum_j x[j] * root^(j*k). That sum is computable without the algorithm
//! under test, so a Cooley-Tukey with its twiddles backwards would round-trip
//! and still fail here.

const std = @import("std");
const testing = std.testing;
const ntt = @import("zig-ntt");
const zf = @import("zig-field");

const Goldilocks = zf.Goldilocks;

pub fn main() !void {
    const log_ns = [_]usize{ 1, 2, 3, 4, 8, 12 };

    std.debug.print("zig-ntt: round trip and definition, per log_n\n\n", .{});
    std.debug.print("  log_n |     n | round trip | matches definition | ok\n", .{});

    var prng = std.Random.DefaultPrng.init(0x5eed_1277);
    const rnd = prng.random();
    var failures: usize = 0;

    for (log_ns) |log_n| {
        const n = @as(usize, 1) << @intCast(log_n);
        var data: [4096]Goldilocks = undefined;
        const buf = data[0..n];
        for (buf) |*v| v.* = Goldilocks.fromInt(rnd.int(u32));

        const original = try std.heap.page_allocator.dupe(Goldilocks, buf);
        defer std.heap.page_allocator.free(original);

        const root = try Goldilocks.primitiveRootOfUnity(log_n);
        try ntt.ntt(Goldilocks, buf, log_n, root);

        // The definition, evaluated independently of Cooley-Tukey.
        var matches = true;
        for (0..n) |k| {
            var acc = Goldilocks.zero();
            for (0..n) |j| {
                acc = acc.add(original[j].mul(root.pow(@as(u32, @intCast(j * k)))));
            }
            if (!acc.eql(buf[k])) matches = false;
        }

        try ntt.intt(Goldilocks, buf, log_n, root);
        var round_trips = true;
        for (buf, original) |got, want| {
            if (!got.eql(want)) round_trips = false;
        }

        const ok = round_trips and matches;
        if (!ok) failures += 1;
        try testing.expect(round_trips);
        try testing.expect(matches);
        std.debug.print("  {d:>5} | {d:>5} | {s:>10} | {s:>17} | {s}\n", .{
            log_n,                            n,
            if (round_trips) "yes" else "NO", if (matches) "yes" else "NO",
            if (ok) "yes" else "NO",
        });
    }

    std.debug.print("\n{d} failure(s)\n", .{failures});
}
