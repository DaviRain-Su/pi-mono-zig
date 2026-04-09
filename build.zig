const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Load sub-packages via build.zig.zon path dependencies
    const shared_dep = b.dependency("shared", .{});
    const shared_mod = shared_dep.module("shared");

    const ai_dep = b.dependency("ai", .{});
    const ai_mod = ai_dep.module("ai");

    const agent_dep = b.dependency("agent", .{});
    const agent_mod = agent_dep.module("agent");

    // tui module
    const tui_mod = b.addModule("tui", .{
        .root_source_file = b.path("tui/src/root.zig"),
        .target = target,
    });
    tui_mod.addImport("shared", shared_mod);

    // coding-agent executable
    const coding_agent_exe = b.addExecutable(.{
        .name = "pi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("coding-agent/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "ai", .module = ai_mod },
                .{ .name = "agent", .module = agent_mod },
                .{ .name = "tui", .module = tui_mod },
            },
        }),
    });
    b.installArtifact(coding_agent_exe);

    // Run step for coding-agent
    const run_step = b.step("run", "Run pi coding agent");
    const run_cmd = b.addRunArtifact(coding_agent_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Test steps for each module
    const shared_tests = b.addTest(.{ .root_module = shared_mod });
    const ai_tests = b.addTest(.{ .root_module = ai_mod });
    const agent_tests = b.addTest(.{ .root_module = agent_mod });
    const tui_tests = b.addTest(.{ .root_module = tui_mod });
    const coding_agent_tests = b.addTest(.{ .root_module = coding_agent_exe.root_module });

    const run_shared_tests = b.addRunArtifact(shared_tests);
    const run_ai_tests = b.addRunArtifact(ai_tests);
    const run_agent_tests = b.addRunArtifact(agent_tests);
    const run_tui_tests = b.addRunArtifact(tui_tests);
    const run_coding_agent_tests = b.addRunArtifact(coding_agent_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_shared_tests.step);
    test_step.dependOn(&run_ai_tests.step);
    test_step.dependOn(&run_agent_tests.step);
    test_step.dependOn(&run_tui_tests.step);
    test_step.dependOn(&run_coding_agent_tests.step);

    // moms, pods executables (placeholder for now)
    const mom_exe = b.addExecutable(.{
        .name = "pi-mom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("mom/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "ai", .module = ai_mod },
                .{ .name = "agent", .module = agent_mod },
            },
        }),
    });
    b.installArtifact(mom_exe);

    const pods_exe = b.addExecutable(.{
        .name = "pi-pods",
        .root_module = b.createModule(.{
            .root_source_file = b.path("pods/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(pods_exe);

    // Integration test executable for AI provider
    const test_ai_exe = b.addExecutable(.{
        .name = "test-ai",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_ai.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai", .module = ai_mod },
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(test_ai_exe);

    const test_ai_step = b.step("test-ai", "Run AI integration test");
    const test_ai_run = b.addRunArtifact(test_ai_exe);
    test_ai_run.step.dependOn(b.getInstallStep());
    test_ai_step.dependOn(&test_ai_run.step);

    // Integration test executable for Anthropic provider
    const test_anthropic_exe = b.addExecutable(.{
        .name = "test-anthropic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_anthropic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai", .module = ai_mod },
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(test_anthropic_exe);

    const test_anthropic_step = b.step("test-anthropic", "Run Anthropic integration test");
    const test_anthropic_run = b.addRunArtifact(test_anthropic_exe);
    test_anthropic_run.step.dependOn(b.getInstallStep());
    test_anthropic_step.dependOn(&test_anthropic_run.step);
}
