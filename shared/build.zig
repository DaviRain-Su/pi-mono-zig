const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_mod = b.addModule("shared", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const shared_tests = b.addTest(.{ .root_module = shared_mod });
    const run_shared_tests = b.addRunArtifact(shared_tests);

    const test_step = b.step("test", "Run shared tests");
    test_step.dependOn(&run_shared_tests.step);

    _ = optimize;
}
