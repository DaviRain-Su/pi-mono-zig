const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ai_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "pi",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const ai_tests = b.addTest(.{
        .root_module = ai_mod,
    });
    const run_ai_tests = b.addRunArtifact(ai_tests);
    test_step.dependOn(&run_ai_tests.step);

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("ai", ai_mod);

    const agent_tests = b.addTest(.{
        .root_module = agent_mod,
    });
    const run_agent_tests = b.addRunArtifact(agent_tests);
    test_step.dependOn(&run_agent_tests.step);

    const agent_test_step = b.step("test-agent", "Run agent unit tests only");
    agent_test_step.dependOn(&run_agent_tests.step);

    const coding_agent_mod = b.createModule(.{
        .root_source_file = b.path("src/coding_agent/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    coding_agent_mod.addImport("ai", ai_mod);
    coding_agent_mod.addImport("agent", agent_mod);

    const coding_agent_tests = b.addTest(.{
        .root_module = coding_agent_mod,
    });
    const run_coding_agent_tests = b.addRunArtifact(coding_agent_tests);
    test_step.dependOn(&run_coding_agent_tests.step);

    const coding_agent_test_step = b.step("test-coding-agent", "Run coding-agent unit tests only");
    coding_agent_test_step.dependOn(&run_coding_agent_tests.step);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);
}
