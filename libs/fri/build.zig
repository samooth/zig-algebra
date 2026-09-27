const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Declared dependencies, resolved through the package manager. Before
    // 0.3.0 these modules were hand-wired from `../transcript/src/root.zig`
    // and friends while build.zig.zon declared `.dependencies = .{}`. That
    // combination made the package unusable outside this monorepo: a consumer
    // resolving `zig_fri` got no dependencies, and the relative paths it would
    // have needed do not exist in a package cache.
    const transcript_dep = b.dependency("zig_transcript", .{
        .target = target,
        .optimize = optimize,
    });
    const transcript_mod = transcript_dep.module("zig-transcript");

    const merkle_dep = b.dependency("zig_merkle", .{
        .target = target,
        .optimize = optimize,
    });
    const merkle_mod = merkle_dep.module("zig-merkle");

    const field_dep = b.dependency("zig_field", .{
        .target = target,
        .optimize = optimize,
    });
    const field_mod = field_dep.module("zig-field");

    _ = b.addModule("zig-fri", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-transcript", .module = transcript_mod },
            .{ .name = "zig-merkle", .module = merkle_mod },
            .{ .name = "zig-field", .module = field_mod },
        },
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-transcript", .module = transcript_mod },
            .{ .name = "zig-merkle", .module = merkle_mod },
            .{ .name = "zig-field", .module = field_mod },
        },
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
