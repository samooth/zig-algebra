const std = @import("std");

/// Create the module for a library, register its unit-test binary, and wire a
/// run step into `test_step` so `zig build test` actually executes the tests
/// (not merely compiles them).
fn lib(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime module_name: []const u8,
    root_source: []const u8,
    imports: []const struct { []const u8, *std.Build.Module },
) *std.Build.Module {
    const mod = b.addModule(module_name, .{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    const test_module = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |imp| {
        mod.addImport(imp[0], imp[1]);
        test_module.addImport(imp[0], imp[1]);
    }
    const tests = b.addTest(.{
        .name = module_name ++ "-tests",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Test step that runs all library tests
    const test_step = b.step("test", "Run all library tests");

    // algebra-traits (no deps)
    const traits_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-algebra-traits",
        "libs/algebra-traits/src/root.zig",
        &.{},
    );

    // bigint -> algebra-traits
    const bigint_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-bigint",
        "libs/bigint/src/root.zig",
        &.{.{ "zig-algebra-traits", traits_mod }},
    );

    // hash -> algebra-traits
    const hash_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-hash",
        "libs/hash/src/root.zig",
        &.{.{ "zig-algebra-traits", traits_mod }},
    );

    // rng -> algebra-traits, hash
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-rng",
        "libs/rng/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // field -> bigint
    const field_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-field",
        "libs/field/src/lib.zig",
        &.{.{ "zig-bigint", bigint_mod }},
    );

    // binary-field -> algebra-traits, hash
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-binary-field",
        "libs/binary-field/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // curve -> field, hash
    const curve_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-curve",
        "libs/curve/src/root.zig",
        &.{
            .{ "zig-field", field_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // merkle -> algebra-traits, hash
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-merkle",
        "libs/merkle/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-hash", hash_mod },
        },
    );

    // ntt -> algebra-traits, field
    const ntt_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-ntt",
        "libs/ntt/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-field", field_mod },
        },
    );

    // poly -> algebra-traits
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-poly",
        "libs/poly/src/root.zig",
        &.{.{ "zig-algebra-traits", traits_mod }},
    );

    // linalg -> algebra-traits, field
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-linalg",
        "libs/linalg/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-field", field_mod },
        },
    );

    // parallel (no deps)
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-parallel",
        "libs/parallel/src/root.zig",
        &.{},
    );

    // serialization (no deps)
    _ = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-serialization",
        "libs/serialization/src/root.zig",
        &.{},
    );

    // pairing -> algebra-traits, field, curve
    const pairing_mod = lib(
        b,
        test_step,
        target,
        optimize,
        "zig-pairing",
        "libs/pairing/src/root.zig",
        &.{
            .{ "zig-algebra-traits", traits_mod },
            .{ "zig-field", field_mod },
            .{ "zig-curve", curve_mod },
        },
    );

    // Benchmark step (always ReleaseFast regardless of -Doptimize)
    const bench_step = b.step("bench", "Run benchmarks (ReleaseFast)");
    const bench_optimize = .ReleaseFast;
    const bench_module = b.createModule(.{
        .root_source_file = b.path("libs/pairing/src/bench.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_module.addImport("zig-field", field_mod);
    bench_module.addImport("zig-curve", curve_mod);
    bench_module.addImport("zig-algebra-traits", traits_mod);
    bench_module.addImport("zig-bigint", bigint_mod);
    bench_module.addImport("zig-ntt", ntt_mod);
    const bench_exe = b.addExecutable(.{
        .name = "pairing-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Example: Schnorr signature over BLS12-381
    const example_step = b.step("example", "Run BLS12-381 Schnorr signature example");
    const ex_mod = b.createModule(.{
        .root_source_file = b.path("examples/schnorr_signature.zig"),
        .target = target,
        .optimize = optimize,
    });
    ex_mod.addImport("zig-field", field_mod);
    ex_mod.addImport("zig-curve", curve_mod);
    ex_mod.addImport("zig-pairing", pairing_mod);
    ex_mod.addImport("zig-algebra-traits", traits_mod);
    ex_mod.addImport("zig-bigint", bigint_mod);
    const example_exe = b.addExecutable(.{
        .name = "schnorr-example",
        .root_module = ex_mod,
    });
    const run_example = b.addRunArtifact(example_exe);
    example_step.dependOn(&run_example.step);
}
