const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const traits_dep = b.dependency("zig_algebra_traits", .{
        .target = target,
        .optimize = optimize,
    });
    const traits_mod = traits_dep.module("zig-algebra-traits");

    const hash_dep = b.dependency("zig_hash", .{
        .target = target,
        .optimize = optimize,
    });
    const hash_mod = hash_dep.module("zig-hash");

    const merkle_mod = b.addModule("zig-merkle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    merkle_mod.addImport("zig-algebra-traits", traits_mod);
    merkle_mod.addImport("zig-hash", hash_mod);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zig-algebra-traits", traits_mod);
    test_module.addImport("zig-hash", hash_mod);
    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("zig-merkle", merkle_mod);
    const example = b.addExecutable(.{
        .name = "merkle-example",
        .root_module = example_module,
    });
    b.installArtifact(example);
}
