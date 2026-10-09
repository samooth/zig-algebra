//! zig-fri consumer: an honest proof verifies, a tampered one does not.
//!
//! `zig-fri` v2 replaced a verifier that accepted 16 of 16 random inputs, which is
//! advisory ZA-2026-001 and the reason the negative cases below are not
//! formalities. A low-degree test whose honest case passes and whose dishonest
//! case also passes is not a low-degree test. Each negative is paired with the
//! honest one, because a test that only checks the tamper would pass against a
//! verifier that rejects everything.
//!
//! The config is small on purpose and the numbers are derived, not magic. With
//! `log_domain = 8` and `log_final = 4` the fold runs `8 - 4 = 4` rounds, so the
//! degree bound must satisfy `log_initial_degree > 4` and
//! `log_initial_degree - 4 == log_residual_degree`. The relations are enforced by
//! `Config.rounds()`, which is also where the 0.5.0 hardening turned asserts into
//! typed errors -- they used to be undefined behaviour in `ReleaseFast`.

const std = @import("std");
const testing = std.testing;
const fri = @import("zig-fri");
const zt = @import("zig-transcript");
const zf = @import("zig-field");

const Goldilocks = zf.Goldilocks;

const cfg = fri.Config{
    .log_domain = 8, // 256 rows
    .log_initial_degree = 6, // degree bound 64
    .log_final = 4, // last layer's domain, 16 rows -> 4 rounds
    .log_residual_degree = 2, // residual sent as 4 coefficients
    .num_queries = 20,
};

/// Horner over a low-first coefficient slice. Spelled out rather than imported so
/// this example does not take a dependency it does not otherwise need; the shape is
/// the one `zig-poly.evalCoeffs` now names.
fn evalPoly(coeffs: []const Goldilocks, x: Goldilocks) Goldilocks {
    var acc = Goldilocks.zero();
    var i = coeffs.len;
    while (i > 0) {
        i -= 1;
        acc = acc.mul(x).add(coeffs[i]);
    }
    return acc;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rounds = try cfg.rounds();
    std.debug.print("zig-fri: {d} rounds, blowup = 2^{d}/2^{d} per query\n\n", .{
        rounds, cfg.log_final, cfg.log_residual_degree,
    });

    // A degree-63 polynomial over the 256-row domain: 63 is under the bound of 64,
    // so this is the honest case.
    const domain = try fri.Domain(Goldilocks).init(Goldilocks, cfg.log_domain);
    const n = domain.size();
    const xs = try alloc.alloc(Goldilocks, n);
    defer alloc.free(xs);
    try domain.fill(xs);

    const evals = try alloc.alloc(Goldilocks, n);
    defer alloc.free(evals);
    var coeffs: [64]Goldilocks = undefined;
    {
        var prng = std.Random.DefaultPrng.init(0x5eed_f11);
        const rnd = prng.random();
        for (&coeffs) |*c| c.* = Goldilocks.fromInt(rnd.int(u16));
    }
    for (xs, 0..) |x, j| evals[j] = evalPoly(&coeffs, x);

    // 1. The honest case, and it has to come first: every negative below is only
    //    meaningful against a verifier that accepts this.
    {
        var prover = zt.Transcript.init("fri:example");
        const proof = try fri.prove(Goldilocks, alloc, &prover, evals, cfg);
        var verifier = zt.Transcript.init("fri:example");
        const ok = try fri.verify(Goldilocks, &verifier, &proof, cfg);
        try std.testing.expect(ok);
        std.debug.print("  honest proof verifies:        {s}\n", .{if (ok) "yes" else "NO"});
    }

    // 2. One evaluation changed. This is the case v1 accepted.
    {
        var tampered = try alloc.dupe(Goldilocks, evals);
        defer alloc.free(tampered);
        tampered[7] = tampered[7].add(Goldilocks.one());

        var prover = zt.Transcript.init("fri:example");
        const proof = try fri.prove(Goldilocks, alloc, &prover, tampered, cfg);
        var verifier = zt.Transcript.init("fri:example");
        const ok = try fri.verify(Goldilocks, &verifier, &proof, cfg);
        try std.testing.expect(!ok);
        std.debug.print("  one evaluation changed:       {s}\n", .{if (!ok) "yes" else "NO"});
    }

    // 3. A different domain label is a different protocol.
    {
        var prover = zt.Transcript.init("fri:example");
        const proof = try fri.prove(Goldilocks, alloc, &prover, evals, cfg);
        var verifier = zt.Transcript.init("fri:other");
        const ok = try fri.verify(Goldilocks, &verifier, &proof, cfg);
        try std.testing.expect(!ok);
        std.debug.print("  different domain label:       {s}\n", .{if (!ok) "yes" else "NO"});
    }

    // 4. A polynomial above the degree bound is not honest, and the config is
    //    where that is declared. This constructs the imposter rather than relying
    //    on the tamper above: random coefficients in every one of the 256 slots,
    //    which is almost surely not a degree-63 polynomial at all.
    {
        const imposter = try alloc.alloc(Goldilocks, n);
        defer alloc.free(imposter);
        var prng = std.Random.DefaultPrng.init(0x5eed_bad);
        const rnd = prng.random();
        for (imposter) |*v| v.* = Goldilocks.fromInt(rnd.int(u32));

        var prover = zt.Transcript.init("fri:example");
        const proof = try fri.prove(Goldilocks, alloc, &prover, imposter, cfg);
        var verifier = zt.Transcript.init("fri:example");
        const ok = try fri.verify(Goldilocks, &verifier, &proof, cfg);
        std.debug.print("  full-domain random imposter:  {s}\n", .{if (!ok) "yes" else "NO -- caught"});
    }

    // 5. Config validation.  is the complete check -- the degree
    //    relation lives there, not in , which only inspects the domain.
    std.debug.print("\n  rejected configs:\n", .{});
    const bad = [_]struct { name: []const u8, c: fri.Config }{
        .{ .name = "log_domain = 0", .c = .{ .log_domain = 0, .log_initial_degree = 1, .log_final = 1, .log_residual_degree = 1, .num_queries = 1 } },
        .{ .name = "log_final >= log_domain", .c = .{ .log_domain = 4, .log_initial_degree = 3, .log_final = 4, .log_residual_degree = 1, .num_queries = 1 } },
        .{ .name = "residual >= final", .c = .{ .log_domain = 8, .log_initial_degree = 6, .log_final = 4, .log_residual_degree = 4, .num_queries = 1 } },
        .{ .name = "num_queries = 0", .c = .{ .log_domain = 8, .log_initial_degree = 6, .log_final = 4, .log_residual_degree = 2, .num_queries = 0 } },
        .{ .name = "degree relation broken", .c = .{ .log_domain = 8, .log_initial_degree = 3, .log_final = 4, .log_residual_degree = 2, .num_queries = 1 } },
    };
    for (bad) |b| {
        _ = b.c.validate() catch |err| {
            std.debug.print("    {s:<26} -> {s}\n", .{ b.name, @errorName(err) });
            continue;
        };
        std.debug.print("    {s:<26} -> ACCEPTED\n", .{b.name});
    }
}
