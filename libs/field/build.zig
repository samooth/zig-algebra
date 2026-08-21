const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bigint_dep = b.dependency("zig_bigint", .{
        .target = target,
        .optimize = optimize,
    });
    const bigint_mod = bigint_dep.module("zig-bigint");

    const lib = b.addModule("zig-field", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addImport("zig-bigint", bigint_mod);

    const test_step = b.step("test", "Run library tests");
    const lib_tests = b.addTest(.{
        .name = "zig-field-tests",
        .root_module = lib,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    const field_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/field_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    const field_tests = b.addTest(.{
        .name = "field-tests",
        .root_module = field_test_mod,
    });
    const run_field_tests = b.addRunArtifact(field_tests);
    test_step.dependOn(&run_field_tests.step);

    const ext_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/extension_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    const ext_tests = b.addTest(.{
        .name = "extension-tests",
        .root_module = ext_test_mod,
    });
    const run_ext_tests = b.addRunArtifact(ext_tests);
    test_step.dependOn(&run_ext_tests.step);

    const merkle_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/merkle_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    const merkle_tests = b.addTest(.{
        .name = "merkle-tests",
        .root_module = merkle_test_mod,
    });
    const run_merkle_tests = b.addRunArtifact(merkle_tests);
    test_step.dependOn(&run_merkle_tests.step);

    const ipa_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ipa_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    const ipa_tests = b.addTest(.{
        .name = "ipa-tests",
        .root_module = ipa_test_mod,
    });
    const run_ipa_tests = b.addRunArtifact(ipa_tests);
    test_step.dependOn(&run_ipa_tests.step);

    const simd_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/simd_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    const simd_tests = b.addTest(.{
        .name = "simd-tests",
        .root_module = simd_test_mod,
    });
    const run_simd_tests = b.addRunArtifact(simd_tests);
    test_step.dependOn(&run_simd_tests.step);

    const ext_quick_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ext_quick.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    const ext_quick_tests = b.addTest(.{
        .name = "ext_quick-tests",
        .root_module = ext_quick_test_mod,
    });
    const run_ext_quick_tests = b.addRunArtifact(ext_quick_tests);
    test_step.dependOn(&run_ext_quick_tests.step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("tests/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-field", .module = lib },
        },
    });
    bench_module.linkSystemLibrary("c", .{});
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_module,
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run field benchmarks (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-field", .module = lib },
            },
        }),
    });
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run randomized field property fuzz");
    fuzz_step.dependOn(&run_fuzz.step);

    _ = b.step("docs", "Build API documentation (not implemented)");

    const fmt_check = b.addFmt(.{ .paths = &.{"."}, .check = true });
    const fmt_step = b.step("fmt", "Check code formatting (zig fmt --check)");
    fmt_step.dependOn(&fmt_check.step);
}
