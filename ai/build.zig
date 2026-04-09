const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const shared_dep = b.dependency("shared", .{});
    const shared_mod = shared_dep.module("shared");

    const ai_mod = b.addModule("ai", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    ai_mod.addImport("shared", shared_mod);

    const ai_tests = b.addTest(.{ .root_module = ai_mod });
    const run_ai_tests = b.addRunArtifact(ai_tests);

    const test_step = b.step("test", "Run ai tests");
    test_step.dependOn(&run_ai_tests.step);
}
