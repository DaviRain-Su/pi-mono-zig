const common = @import("common.zig");
const std = common.std;
const agent = common.agent;
const ai = common.ai;
const extension_runtime = common.extension_runtime;
const interactive_mode = common.interactive_mode;
const print_mode = common.print_mode;
const session_mod = common.session_mod;
const tool_selection_mod = common.tool_selection_mod;
const wasm_manifest = common.wasm_manifest;
const normalConstructionFactory = common.normalConstructionFactory;
const forcedWasmSuccessToolCallFactory = common.forcedWasmSuccessToolCallFactory;
const verifyWasmSuccessResultFactory = common.verifyWasmSuccessResultFactory;
const forcedWasmInvalidInputToolCallFactory = common.forcedWasmInvalidInputToolCallFactory;
const verifyWasmInvalidResultFactory = common.verifyWasmInvalidResultFactory;
const expectLatestToolResult = common.expectLatestToolResult;
const expectLatestGenericToolError = common.expectLatestGenericToolError;
const runNormalConstructionCase = common.runNormalConstructionCase;
const runPackageCommand = common.runPackageCommand;
const loadAuthorRuntimeConfig = common.loadAuthorRuntimeConfig;
const writeAuthorSettings = common.writeAuthorSettings;
const installedPackageSource = common.installedPackageSource;
const copyTemplateToTmp = common.copyTemplateToTmp;
const runTemplateBuild = common.runTemplateBuild;
const readFile = common.readFile;
const absoluteTmpPath = common.absoluteTmpPath;
const expectContains = common.expectContains;

test "VAL-RUNTIME normal agent construction includes installed wasm tools with filters" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer ai.model_registry.resetForTesting();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);

    const package_root = try copyTemplateToTmp(allocator, &tmp, "project/runtime-tool-plugin");
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    var install_result = try runPackageCommand(allocator, &.{ "install", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer install_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const policy_key = try extension_runtime.wasmPolicyLookupKey(
        allocator,
        extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid),
    );
    defer allocator.free(policy_key);
    try writeAuthorSettings(allocator, settings_path, persisted_source, policy_key, "template.echo");

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
    });

    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "default construction", .{
        .include_installed_wasm_tools = true,
    }, .text, "default construction ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "selected builtins", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{ "read", "grep" }),
        .include_installed_wasm_tools = true,
    }, .text, "selected builtins ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "selected wasm", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"template.echo"}),
        .include_installed_wasm_tools = true,
    }, .text, "selected wasm ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "no tools", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{}),
        .include_builtin_tools = false,
        .include_installed_wasm_tools = false,
    }, .text, "no tools ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "no builtins", .{
        .include_builtin_tools = false,
        .include_installed_wasm_tools = true,
    }, .text, "no builtins ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "no tools explicit wasm", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"template.echo"}),
        .include_installed_wasm_tools = true,
    }, .text, "no tools explicit wasm ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "json construction", .{
        .include_installed_wasm_tools = true,
    }, .json, null);
}

test "VAL-RUNTIME installed wasm executes through normal session history and error results" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer ai.model_registry.resetForTesting();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/sessions");
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const session_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project/sessions");
    defer allocator.free(session_dir);

    const package_root = try copyTemplateToTmp(allocator, &tmp, "project/runtime-execution-plugin");
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    var install_result = try runPackageCommand(allocator, &.{ "install", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer install_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const policy_key = try extension_runtime.wasmPolicyLookupKey(
        allocator,
        extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid),
    );
    defer allocator.free(policy_key);
    try writeAuthorSettings(allocator, settings_path, persisted_source, policy_key, "template.echo");

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = forcedWasmSuccessToolCallFactory },
        .{ .factory = verifyWasmSuccessResultFactory },
        .{ .factory = forcedWasmInvalidInputToolCallFactory },
        .{ .factory = verifyWasmInvalidResultFactory },
    });

    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"template.echo"}),
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
    defer built_tools.deinit();
    try std.testing.expect(built_tools.locked_wasm_runtimes != null);
    try std.testing.expectEqual(@as(usize, 1), built_tools.locked_wasm_runtimes.?.entries.len);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = registration.getModel(),
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var success_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer success_stdout.deinit();
    var success_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer success_stderr.deinit();
    const success_exit = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "call installed wasm",
        .{ .mode = .text, .install_signal_handlers = false },
        &success_stdout.writer,
        &success_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), success_exit);
    try std.testing.expectEqualStrings("installed wasm success observed\n", success_stdout.writer.buffered());
    try std.testing.expectEqualStrings("", success_stderr.writer.buffered());

    try expectLatestToolResult(session.agent.getMessages(), .{
        .tool_call_id = "wasm-normal-success",
        .tool_name = "template.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = manifest_result.valid.artifact_sha256,
    });
    try std.testing.expectEqual(@as(usize, 0), built_tools.locked_wasm_runtimes.?.entries[0].adapter.pendingCount());

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    const persisted = try readFile(allocator, session_file);
    defer allocator.free(persisted);
    try expectContains(persisted, "\"toolCallId\":\"wasm-normal-success\"");
    try expectContains(persisted, "\"toolName\":\"template.echo\"");
    try expectContains(persisted, "\"isError\":false");
    try expectContains(persisted, "\"extensionRuntime\"");
    try expectContains(persisted, "\"runtimeKind\":\"wasm\"");
    try expectContains(persisted, manifest_result.valid.artifact_sha256);

    var reopened = try session_mod.AgentSession.open(allocator, std.testing.io, .{
        .session_file = session_file,
        .cwd_override = project_dir,
        .system_prompt = "sys",
        .model = registration.getModel(),
        .tools = built_tools.items,
    });
    defer reopened.deinit();
    try expectLatestToolResult(reopened.agent.getMessages(), .{
        .tool_call_id = "wasm-normal-success",
        .tool_name = "template.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = manifest_result.valid.artifact_sha256,
    });

    var invalid_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_stdout.deinit();
    var invalid_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_stderr.deinit();
    const invalid_exit = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "call installed wasm with invalid input",
        .{ .mode = .text, .install_signal_handlers = false },
        &invalid_stdout.writer,
        &invalid_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), invalid_exit);
    try std.testing.expectEqualStrings("installed wasm invalid input observed\n", invalid_stdout.writer.buffered());
    try std.testing.expectEqualStrings("", invalid_stderr.writer.buffered());
    try expectLatestGenericToolError(session.agent.getMessages(), "wasm-normal-invalid", "template.echo", "InvalidToolArguments");
    try std.testing.expectEqual(@as(usize, 0), built_tools.locked_wasm_runtimes.?.entries[0].adapter.pendingCount());
}
