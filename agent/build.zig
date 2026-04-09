const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const shared_dep = b.dependency("shared", .{});
    const shared_mod = shared_dep.module("shared");
    const ai_dep = b.dependency("ai", .{});
    const ai_mod = ai_dep.module("ai");

    const agent_mod = b.addModule("agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    agent_mod.addImport("shared", shared_mod);
    agent_mod.addImport("ai", ai_mod);

    const agent_tests = b.addTest(.{ .root_module = agent_mod });
    const run_agent_tests = b.addRunArtifact(agent_tests);

    const test_step = b.step("test", "Run agent tests");
    test_step.dependOn(&run_agent_tests.step);
}
