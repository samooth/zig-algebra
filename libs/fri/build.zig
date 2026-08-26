const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Local transcript dependency
    const transcript_mod = b.addModule("zig-transcript", .{
        .root_source_file = b.path("../transcript/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Local merkle dependency
    const hash_mod = b.addModule("zig-hash", .{
        .root_source_file = b.path("../hash/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const merkle_mod = b.addModule("zig-merkle", .{
        .root_source_file = b.path("../merkle/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-hash", .module = hash_mod },
        },
    });

    _ = b.addModule("zig-fri", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-transcript", .module = transcript_mod },
            .{ .name = "zig-merkle", .module = merkle_mod },
        },
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig-transcript", .module = transcript_mod },
            .{ .name = "zig-merkle", .module = merkle_mod },
        },
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
