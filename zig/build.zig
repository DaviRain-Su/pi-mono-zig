const std = @import("std");

const RequiredExternalTool = struct {
    names: []const []const u8,
    display_name: []const u8,
    reason: []const u8,
};

const required_external_tools = [_]RequiredExternalTool{
    .{
        .names = &[_][]const u8{"rg"},
        .display_name = "ripgrep (rg)",
        .reason = "required by the coding-agent grep tool",
    },
    .{
        .names = &[_][]const u8{"fd"},
        .display_name = "fd",
        .reason = "required by the coding-agent find tool",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const external_tool_check_step = addExternalToolCheckStep(b);
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

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

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("ai", ai_mod);

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tui_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

    mod.addImport("ai", ai_mod);
    mod.addImport("agent", agent_mod);
    mod.addImport("tui", tui_mod);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "pi",
        .root_module = mod,
    });
    b.installArtifact(exe);
    b.getInstallStep().dependOn(external_tool_check_step);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(external_tool_check_step);
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(external_tool_check_step);

    const ts_rpc_prompt_concurrency_fixture_diff = b.addSystemCommand(&.{"bash"});
    ts_rpc_prompt_concurrency_fixture_diff.addFileArg(b.path("test/ts-rpc-prompt-concurrency-fixture-diff.sh"));
    ts_rpc_prompt_concurrency_fixture_diff.step.dependOn(b.getInstallStep());
    test_step.dependOn(&ts_rpc_prompt_concurrency_fixture_diff.step);

    const ai_tests = b.addTest(.{
        .root_module = ai_mod,
    });
    const run_ai_tests = b.addRunArtifact(ai_tests);
    test_step.dependOn(&run_ai_tests.step);

    const agent_tests = b.addTest(.{
        .root_module = agent_mod,
    });
    const run_agent_tests = b.addRunArtifact(agent_tests);
    test_step.dependOn(&run_agent_tests.step);

    const agent_test_step = b.step("test-agent", "Run agent unit tests only");
    agent_test_step.dependOn(external_tool_check_step);
    agent_test_step.dependOn(&run_agent_tests.step);

    const coding_agent_mod = b.createModule(.{
        .root_source_file = b.path("src/coding_agent/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    coding_agent_mod.addImport("ai", ai_mod);
    coding_agent_mod.addImport("agent", agent_mod);
    coding_agent_mod.addImport("tui", tui_mod);

    const coding_agent_tests = b.addTest(.{
        .root_module = coding_agent_mod,
    });
    const run_coding_agent_tests = b.addRunArtifact(coding_agent_tests);
    test_step.dependOn(&run_coding_agent_tests.step);

    const coding_agent_test_step = b.step("test-coding-agent", "Run coding-agent unit tests only");
    coding_agent_test_step.dependOn(external_tool_check_step);
    coding_agent_test_step.dependOn(&run_coding_agent_tests.step);

    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_mod.addImport("ai", ai_mod);
    main_test_mod.addImport("agent", agent_mod);
    main_test_mod.addImport("tui", tui_mod);

    const main_tests = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_main_tests.step);

    if (target.result.os.tag != .windows) {
        const cross_area_tests = b.addSystemCommand(&.{"bash"});
        cross_area_tests.addFileArg(b.path("test/cross-area-flows.sh"));
        cross_area_tests.step.dependOn(b.getInstallStep());

        const cross_area_test_step = b.step("test-cross-area", "Run compiled-binary cross-area integration tests");
        cross_area_test_step.dependOn(external_tool_check_step);
        cross_area_test_step.dependOn(&cross_area_tests.step);

        const vaxis_m8_tests = b.addSystemCommand(&.{"bash"});
        vaxis_m8_tests.addFileArg(b.path("test/vaxis-m8-e2e.sh"));
        vaxis_m8_tests.step.dependOn(b.getInstallStep());

        const vaxis_m8_test_step = b.step("test-vaxis-m8-e2e", "Run vaxis M8 tuistory integration tests");
        vaxis_m8_test_step.dependOn(external_tool_check_step);
        vaxis_m8_test_step.dependOn(&vaxis_m8_tests.step);
    } else {
        _ = b.step("test-cross-area", "Skipped on Windows target");
        _ = b.step("test-vaxis-m8-e2e", "Skipped on Windows target");
    }

    const coding_agent_rendering_mod = b.createModule(.{
        .root_source_file = b.path("src/coding_agent/interactive_mode_rendering_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    coding_agent_rendering_mod.addImport("ai", ai_mod);
    coding_agent_rendering_mod.addImport("agent", agent_mod);
    coding_agent_rendering_mod.addImport("tui", tui_mod);

    const coding_agent_rendering_tests = b.addTest(.{
        .root_module = coding_agent_rendering_mod,
    });
    const run_coding_agent_rendering_tests = b.addRunArtifact(coding_agent_rendering_tests);

    const tui_tests = b.addTest(.{
        .root_module = tui_mod,
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);
    test_step.dependOn(&run_tui_tests.step);

    const tui_test_step = b.step("test-tui", "Run TUI unit tests only");
    tui_test_step.dependOn(external_tool_check_step);
    tui_test_step.dependOn(&run_tui_tests.step);
    tui_test_step.dependOn(&run_coding_agent_rendering_tests.step);
}

fn addExternalToolCheckStep(b: *std.Build) *std.Build.Step {
    const step = b.step(
        "check-external-tools",
        "Verify required external CLI tools are available in PATH",
    );

    var missing_tools = std.ArrayList([]const u8).empty;
    defer missing_tools.deinit(b.allocator);

    for (required_external_tools) |tool| {
        _ = b.findProgram(tool.names, &.{}) catch |err| switch (err) {
            error.FileNotFound => missing_tools.append(
                b.allocator,
                b.fmt("- {s}: {s}", .{ tool.display_name, tool.reason }),
            ) catch @panic("OOM"),
        };
    }

    if (missing_tools.items.len > 0) {
        const missing_summary = std.mem.join(b.allocator, "\n", missing_tools.items) catch @panic("OOM");
        const fail_step = b.addFail(b.fmt(
            "Missing required external tools:\n{s}\n\nInstall them and ensure they are on PATH before running `zig build` or `zig build test`.\nHomebrew: `brew install ripgrep fd`.",
            .{missing_summary},
        ));
        step.dependOn(&fail_step.step);
    }

    return step;
}
