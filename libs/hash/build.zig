const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const traits_dep = b.dependency("zig_algebra_traits", .{
        .target = target,
        .optimize = optimize,
    });
    const traits_mod = traits_dep.module("zig-algebra-traits");

    // `zig-hash`'s own examples and tests used to hand-roll a minimal field
    // interface, because the library did not depend on `zig-field` and nobody
    // decided that a consumer should. Two copies existed -- one in `root.zig`
    // for the tests, one in `main.zig` for the demo -- neither built by the root
    // build, and one of them carried an `invChecked` that has never been
    // executed. Importing the field is requirement 14, in the library that
    // writes it.
    const field_dep = b.dependency("zig_field", .{
        .target = target,
        .optimize = optimize,
    });
    const field_mod = field_dep.module("zig-field");

    const hash_mod = b.addModule("zig-hash", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_mod.addImport("zig-algebra-traits", traits_mod);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zig-algebra-traits", traits_mod);
    test_module.addImport("zig-field", field_mod);
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
    example_module.addImport("zig-hash", hash_mod);
    example_module.addImport("zig-algebra-traits", traits_mod);
    example_module.addImport("zig-field", field_mod);
    const example = b.addExecutable(.{
        .name = "hash-example",
        .root_module = example_module,
    });
    b.installArtifact(example);
}
