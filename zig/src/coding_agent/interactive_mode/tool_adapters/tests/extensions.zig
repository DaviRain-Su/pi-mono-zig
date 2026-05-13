const t = @import("common.zig");

const std = t.std;
const ai = t.ai;
const agent = t.agent;
const tools = t.tools;
const common = t.common;
const config_mod = t.config_mod;
const extension_registry = t.extension_registry;
const extension_runtime = t.extension_runtime;
const provider_config = t.provider_config;
const resources_mod = t.resources_mod;
const system_prompt_mod = t.system_prompt_mod;
const session_mod = t.session_mod;
const session_manager_mod = t.session_manager_mod;
const tool_selection_mod = t.tool_selection_mod;
const AppContext = t.AppContext;
const buildAgentTools = t.buildAgentTools;
const buildAgentToolsWithExtensions = t.buildAgentToolsWithExtensions;
const buildAgentToolsWithExtensionsSelection = t.buildAgentToolsWithExtensionsSelection;
const writeStartupDiagnostics = t.writeStartupDiagnostics;
const registerExtensionProvidersAndCollectResources = t.registerExtensionProvidersAndCollectResources;
const replaceAgentToolsForReload = t.replaceAgentToolsForReload;
const appendLockedWasmTools = t.appendLockedWasmTools;
const BashToolUpdateForwardContext = t.BashToolUpdateForwardContext;
const forwardBashToolUpdate = t.forwardBashToolUpdate;
const pathExists = t.pathExists;
const findBuiltTool = t.findBuiltTool;
const findBuiltToolIndex = t.findBuiltToolIndex;
const countBuiltToolName = t.countBuiltToolName;
const startupDiagnosticContains = t.startupDiagnosticContains;
const writeRegisteringExtensionScript = t.writeRegisteringExtensionScript;
const writeRecordingExtensionScript = t.writeRecordingExtensionScript;
const writeHangingExtensionScript = t.writeHangingExtensionScript;
const writeProviderExtensionScript = t.writeProviderExtensionScript;
const findProviderDiagnostic = t.findProviderDiagnostic;
const makeLoadedExtensionForTest = t.makeLoadedExtensionForTest;
const makePackageLoadedExtensionForTest = t.makePackageLoadedExtensionForTest;
const putLoadedExtensionPolicy = t.putLoadedExtensionPolicy;
const putToolAdapterPolicy = t.putToolAdapterPolicy;
const makeToolAdapterRuntimeConfig = t.makeToolAdapterRuntimeConfig;
const deinitToolAdapterPolicyMap = t.deinitToolAdapterPolicyMap;
const makeToolAdapterTestPath = t.makeToolAdapterTestPath;

test "buildAgentToolsWithExtensions exposes process_jsonl tools and preserves call details" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const capture_path = try makeToolAdapterTestPath(allocator, tmp, "extension-tool-capture.jsonl");
    defer allocator.free(capture_path);
    const script_body = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"ext-echo\",\"label\":\"Ext Echo\",\"description\":\"Process echo\",\"parameters\":{{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{{\"value\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"extensionPath\":\"fixture/ext-echo.js\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  printf '%s\\n' \"$line\" >> {s}\n" ++
            "  case \"$line\" in\n" ++
            "    *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;;\n" ++
            "    *'\"toolCallId\":\"tool-ok\"'*) printf '{{\"type\":\"tool_result\",\"toolCallId\":\"tool-ok\",\"content\":[{{\"type\":\"text\",\"text\":\"ok from extension\"}}],\"details\":{{\"source\":\"fixture\"}}}}\\n';;\n" ++
            "    *'\"toolCallId\":\"tool-bad\"'*) printf '{{\"type\":\"tool_error\",\"toolCallId\":\"tool-bad\",\"message\":\"bad from extension\"}}\\n';;\n" ++
            "    *'\"toolCallId\"'*) id=$(printf '%s\\n' \"$line\" | sed -n 's/.*\"toolCallId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"tool_result\",\"toolCallId\":\"%s\",\"content\":[{{\"type\":\"text\",\"text\":\"ok from faux session\"}}],\"details\":{{\"source\":\"fixture-session\"}}}}\\n' \"$id\";;\n" ++
            "  esac\n" ++
            "done\n",
        .{capture_path},
    );
    defer allocator.free(script_body);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ext-echo.js", .data = script_body });
    const extension_path = try makeToolAdapterTestPath(allocator, tmp, "ext-echo.js");
    defer allocator.free(extension_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    const source_path = try allocator.dupe(u8, extension_path);
    defer allocator.free(source_path);
    const source_name = try allocator.dupe(u8, "test");
    defer allocator.free(source_name);
    const base_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(base_dir);

    var app_context = AppContext.init("/tmp", std.testing.io);
    const loaded_extension = resources_mod.LoadedExtension{
        .path = extension_path,
        .source_info = .{
            .path = source_path,
            .source = source_name,
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    };
    var built_tools = try buildAgentToolsWithExtensions(allocator, &app_context, &[_][]const u8{"ext-echo"}, .{
        .extensions = &.{loaded_extension},
        .env_map = &env_map,
        .cwd = "/tmp",
        .io = std.testing.io,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 1), built_tools.items.len);
    const tool = built_tools.items[0];
    try std.testing.expectEqualStrings("ext-echo", tool.name);
    try std.testing.expectEqualStrings("Ext Echo", tool.label);

    var ok_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"ok\"}", .{});
    defer ok_params.deinit();
    const ok = try tool.execute.?(allocator, "tool-ok", ok_params.value, tool.execute_context, null, null, null);
    defer common.deinitContentBlocks(allocator, ok.content);
    defer if (ok.details) |details| common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), ok.is_error);
    try std.testing.expectEqualStrings("ok from extension", ok.content[0].text.text);
    try std.testing.expectEqualStrings("fixture", ok.details.?.object.get("source").?.string);
    try std.testing.expectEqualStrings("tool-ok", ok.details.?.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("process_jsonl", ok.details.?.object.get("extension").?.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("ok", ok.details.?.object.get("input").?.object.get("value").?.string);

    var bad_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"bad\"}", .{});
    defer bad_params.deinit();
    const bad = try tool.execute.?(allocator, "tool-bad", bad_params.value, tool.execute_context, null, null, null);
    defer common.deinitContentBlocks(allocator, bad.content);
    defer if (bad.details) |details| common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), bad.is_error);
    try std.testing.expectEqualStrings("bad from extension", bad.content[0].text.text);
    try std.testing.expectEqualStrings("process_jsonl_tool_error", bad.details.?.object.get("code").?.string);

    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":42}", .{});
    defer invalid_params.deinit();
    const invalid = try tool.execute.?(allocator, "tool-invalid", invalid_params.value, tool.execute_context, null, null, null);
    defer common.deinitContentBlocks(allocator, invalid.content);
    defer if (invalid.details) |details| common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), invalid.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", invalid.content[0].text.text);

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"toolCallId\":\"tool-ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"toolCallId\":\"tool-bad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "tool-invalid") == null);

    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");
    const session_root = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(session_root);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);
    try env_map.put("PI_FAUX_TOOL_NAME", "ext-echo");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"value\":\"from-faux\"}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "final from faux");
    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = session_root,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try session.prompt("call process extension");

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, session_root);
    defer reopened.deinit();
    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("ext-echo", context.messages[2].tool_result.tool_name);
    try std.testing.expectEqual(@as(?bool, false), context.messages[2].tool_result.is_error);
    try std.testing.expectEqualStrings("ok from faux session", context.messages[2].tool_result.content[0].text.text);
    const persisted = context.messages[2].tool_result.details.?.object;
    try std.testing.expectEqualStrings("fixture-session", persisted.get("source").?.string);
    try std.testing.expectEqualStrings("from-faux", persisted.get("input").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("process_jsonl", persisted.get("extension").?.object.get("runtime").?.string);

    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"value\":42}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "final after invalid");
    var invalid_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer invalid_provider.deinit(allocator);

    var invalid_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = session_root,
        .system_prompt = "sys",
        .model = invalid_provider.model,
        .api_key = invalid_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer invalid_session.deinit();

    try invalid_session.prompt("call process extension with invalid input");

    const invalid_session_file = try allocator.dupe(u8, invalid_session.session_manager.getSessionFile().?);
    defer allocator.free(invalid_session_file);
    var invalid_reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, invalid_session_file, session_root);
    defer invalid_reopened.deinit();
    var invalid_context = try invalid_reopened.buildSessionContext(allocator);
    defer invalid_context.deinit(allocator);

    const invalid_result = invalid_context.messages[2].tool_result;
    try std.testing.expectEqualStrings("ext-echo", invalid_result.tool_name);
    try std.testing.expectEqual(@as(?bool, true), invalid_result.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", invalid_result.content[0].text.text);
    const invalid_details = invalid_result.details.?.object;
    try std.testing.expectEqualStrings("InvalidToolArguments", invalid_details.get("code").?.string);
    try std.testing.expectEqualStrings("ext-echo", invalid_details.get("toolName").?.string);
    try std.testing.expectEqualStrings(invalid_result.tool_call_id, invalid_details.get("toolCallId").?.string);
    try std.testing.expectEqual(@as(i64, 42), invalid_details.get("input").?.object.get("value").?.integer);
    try std.testing.expectEqualStrings("process_jsonl", invalid_details.get("extension").?.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("ext-echo", invalid_details.get("extension").?.object.get("toolName").?.string);
    try std.testing.expectEqualStrings("fixture/ext-echo.js", invalid_details.get("extension").?.object.get("extensionPath").?.string);
    try std.testing.expectEqualStrings("$.value", invalid_details.get("fieldPath").?.string);
    try std.testing.expectEqualStrings("$.value", invalid_details.get("validation").?.object.get("fieldPath").?.string);
    try std.testing.expectEqualStrings("expected string", invalid_details.get("validation").?.object.get("message").?.string);

    const capture_after_invalid = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture_after_invalid);
    try std.testing.expect(std.mem.indexOf(u8, capture_after_invalid, invalid_result.tool_call_id) == null);
}

test "buildAgentToolsWithExtensionsSelection filters extension tools with CLI semantics" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"read\",\"label\":\"Ext Read\",\"description\":\"Extension colliding read\",\"parameters\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}},\"extensionPath\":\"fixture/ext-read.js\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"ext-echo\",\"label\":\"Ext Echo\",\"description\":\"Process echo\",\"parameters\":{\"type\":\"object\",\"properties\":{}},\"extensionPath\":\"fixture/ext-echo.js\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"ext-other\",\"label\":\"Ext Other\",\"description\":\"Other process tool\",\"parameters\":{\"type\":\"object\",\"properties\":{}},\"extensionPath\":\"fixture/ext-other.js\"}\\n'\n" ++
        "while IFS= read -r line; do\n" ++
        "  case \"$line\" in\n" ++
        "    *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;;\n" ++
        "  esac\n" ++
        "done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ext-tools.js", .data = script_body });
    const extension_path = try makeToolAdapterTestPath(allocator, tmp, "ext-tools.js");
    defer allocator.free(extension_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    const source_path = try allocator.dupe(u8, extension_path);
    defer allocator.free(source_path);
    const source_name = try allocator.dupe(u8, "test");
    defer allocator.free(source_name);
    const base_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(base_dir);

    const loaded_extension = resources_mod.LoadedExtension{
        .path = extension_path,
        .source_info = .{
            .path = source_path,
            .source = source_name,
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    };

    var app_context = AppContext.init("/tmp", std.testing.io);

    var allowlisted = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(false, false, &.{ "read", "ext-echo" }),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
        },
    );
    defer allowlisted.deinit();
    try std.testing.expectEqual(@as(usize, 3), allowlisted.items.len);
    try std.testing.expectEqual(@as(usize, 2), countBuiltToolName(allowlisted.items, "read"));
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(allowlisted.items, "ext-echo"));
    try std.testing.expectEqual(@as(usize, 0), countBuiltToolName(allowlisted.items, "ext-other"));
    try std.testing.expectEqual(@as(usize, 0), countBuiltToolName(allowlisted.items, "bash"));

    var no_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
        },
    );
    defer no_tools.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), no_tools.extension_hosts.len);

    var no_builtin = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(false, true, null),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
        },
    );
    defer no_builtin.deinit();
    try std.testing.expectEqual(@as(usize, 3), no_builtin.items.len);
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(no_builtin.items, "read"));
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(no_builtin.items, "ext-echo"));
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(no_builtin.items, "ext-other"));
    try std.testing.expectEqual(agent.types.AgentToolSource.extension, findBuiltTool(no_builtin.items, "read").?.source);

    const no_builtin_prompt = try system_prompt_mod.buildSystemPrompt(allocator, .{
        .cwd = "/tmp",
        .current_date = "2026-05-08",
        .tool_selection = tool_selection_mod.ToolSelection.fromCli(false, true, null),
        .active_tools = no_builtin.items,
    });
    defer allocator.free(no_builtin_prompt);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- read: Extension colliding read") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "\"value\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- ext-echo: Process echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- ext-other: Other process tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "\"properties\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- read: Read file contents") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "Available tools:\n(none)") == null);
}

test "extension provider and resource registry contributions feed bootstrap registries" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_provider\",\"name\":\"ext-local-provider\",\"displayName\":\"Extension Local\",\"api\":\"openai-completions\",\"baseUrl\":\"http://localhost:4321/v1\",\"models\":[{\"id\":\"ext-local-model\",\"name\":\"Extension Local Model\"}],\"extensionPath\":\"fixture/provider.js\"}\\n'\n" ++
        "printf '{\"type\":\"resources_discover\",\"skillPaths\":[\"ext-skills\"],\"promptPaths\":[\"ext-prompts\"],\"themePaths\":[\"ext-themes\"],\"extensionPath\":\"fixture/provider.js\"}\\n'\n" ++
        "while IFS= read -r line; do\n" ++
        "  case \"$line\" in\n" ++
        "    *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;;\n" ++
        "  esac\n" ++
        "done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "provider.js", .data = script_body });
    const extension_path = try makeToolAdapterTestPath(allocator, tmp, "provider.js");
    defer allocator.free(extension_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    const source_path = try allocator.dupe(u8, extension_path);
    defer allocator.free(source_path);
    const source_name = try allocator.dupe(u8, "test");
    defer allocator.free(source_name);
    const base_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(base_dir);

    const loaded_extension = resources_mod.LoadedExtension{
        .path = extension_path,
        .source_info = .{
            .path = source_path,
            .source = source_name,
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    };

    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
            .start_without_tools = true,
        },
    );
    defer built_tools.deinit();

    var contributions = try registerExtensionProvidersAndCollectResources(allocator, &built_tools, &.{loaded_extension});
    defer contributions.deinit();

    const provider = ai.model_registry.getProviderConfig("ext-local-provider").?;
    try std.testing.expectEqualStrings("openai-completions", provider.api);
    try std.testing.expectEqualStrings("http://localhost:4321/v1", provider.base_url);
    try std.testing.expectEqualStrings("ext-local-model", provider.default_model_id.?);
    const model = ai.model_registry.find("ext-local-provider", "ext-local-model").?;
    try std.testing.expectEqualStrings("Extension Local Model", model.name);
    try std.testing.expectEqual(@as(usize, 1), contributions.provider_names.len);
    try std.testing.expectEqual(@as(usize, 1), contributions.resource_discoveries.len);
    try std.testing.expectEqualStrings("ext-skills", contributions.resource_discoveries[0].skill_paths[0]);
    try std.testing.expectEqualStrings("ext-prompts", contributions.resource_discoveries[0].prompt_paths[0]);
    try std.testing.expectEqualStrings("ext-themes", contributions.resource_discoveries[0].theme_paths[0]);

    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");
    const session_root = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(session_root);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);
    try env_map.put("PI_FAUX_FORCE", "ext-local-provider");
    try env_map.put("PI_FAUX_RESPONSE", "extension provider streamed response");

    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        std.testing.io,
        &env_map,
        "ext-local-provider",
        "ext-local-model",
        null,
        null,
    );
    defer current_provider.deinit(allocator);
    try std.testing.expectEqualStrings("ext-local-provider", current_provider.model.provider);
    try std.testing.expectEqualStrings("ext-local-model", current_provider.model.id);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = session_root,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = &.{},
    });
    defer session.deinit();

    try session.prompt("stream through extension provider");
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, session_root);
    defer reopened.deinit();
    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("extension provider streamed response", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("ext-local-provider", context.messages[1].assistant.provider);
    try std.testing.expectEqualStrings("ext-local-provider", context.model.?.provider);
    try std.testing.expectEqualStrings("ext-local-model", context.model.?.model_id);
}

test "extension provider collisions are diagnosed and excluded from active registry" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const valid_path = try makeToolAdapterTestPath(allocator, tmp, "valid-provider.js");
    defer allocator.free(valid_path);
    const duplicate_a_path = try makeToolAdapterTestPath(allocator, tmp, "duplicate-a-provider.js");
    defer allocator.free(duplicate_a_path);
    const duplicate_b_path = try makeToolAdapterTestPath(allocator, tmp, "duplicate-b-provider.js");
    defer allocator.free(duplicate_b_path);
    const builtin_path = try makeToolAdapterTestPath(allocator, tmp, "builtin-provider.js");
    defer allocator.free(builtin_path);

    try writeProviderExtensionScript(&tmp, allocator, "valid-provider.js", valid_path, "ext-valid-provider", "Valid Extension Provider", "ext-valid-model", "Valid Extension Model", "http://localhost:4321/v1");
    try writeProviderExtensionScript(&tmp, allocator, "duplicate-a-provider.js", duplicate_a_path, "ext-colliding-provider", "Duplicate Provider A", "dup-a-model", "Duplicate A Model", "http://localhost:4322/v1");
    try writeProviderExtensionScript(&tmp, allocator, "duplicate-b-provider.js", duplicate_b_path, "ext-colliding-provider", "Duplicate Provider B", "dup-b-model", "Duplicate B Model", "http://localhost:4323/v1");
    try writeProviderExtensionScript(&tmp, allocator, "builtin-provider.js", builtin_path, "openai", "Builtin Collision", "shadow-gpt", "Shadow GPT", "http://localhost:4324/v1");

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    var valid_extension = try makeLoadedExtensionForTest(allocator, valid_path, .temporary);
    defer valid_extension.deinit(allocator);
    var duplicate_a_extension = try makeLoadedExtensionForTest(allocator, duplicate_a_path, .temporary);
    defer duplicate_a_extension.deinit(allocator);
    var duplicate_b_extension = try makeLoadedExtensionForTest(allocator, duplicate_b_path, .temporary);
    defer duplicate_b_extension.deinit(allocator);
    var builtin_extension = try makeLoadedExtensionForTest(allocator, builtin_path, .temporary);
    defer builtin_extension.deinit(allocator);

    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .{
            .extensions = &.{ valid_extension, duplicate_a_extension, duplicate_b_extension, builtin_extension },
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
            .start_without_tools = true,
        },
    );
    defer built_tools.deinit();

    var contributions = try registerExtensionProvidersAndCollectResources(
        allocator,
        &built_tools,
        &.{ valid_extension, duplicate_a_extension, duplicate_b_extension, builtin_extension },
    );
    defer contributions.deinit();

    const valid_provider = ai.model_registry.getProviderConfig("ext-valid-provider").?;
    try std.testing.expectEqualStrings("openai-completions", valid_provider.api);
    try std.testing.expectEqualStrings("http://localhost:4321/v1", valid_provider.base_url);
    try std.testing.expectEqualStrings("ext-valid-model", valid_provider.default_model_id.?);
    try std.testing.expect(ai.model_registry.find("ext-valid-provider", "ext-valid-model") != null);

    try std.testing.expect(ai.model_registry.getProviderConfig("ext-colliding-provider") == null);
    try std.testing.expect(ai.model_registry.find("ext-colliding-provider", "dup-a-model") == null);
    try std.testing.expect(ai.model_registry.find("ext-colliding-provider", "dup-b-model") == null);

    const builtin_provider = ai.model_registry.getProviderConfig("openai").?;
    try std.testing.expectEqualStrings("https://api.openai.com/v1", builtin_provider.base_url);
    try std.testing.expect(ai.model_registry.find("openai", "shadow-gpt") == null);
    try std.testing.expect(ai.model_registry.find("openai", "gpt-5.4") != null);

    try std.testing.expectEqual(@as(usize, 1), contributions.provider_names.len);
    try std.testing.expectEqualStrings("ext-valid-provider", contributions.provider_names[0]);
    try std.testing.expectEqual(@as(usize, 3), contributions.provider_diagnostics.len);

    const duplicate_a = findProviderDiagnostic(contributions.provider_diagnostics, "extension_provider.duplicate_id", "ext-colliding-provider", duplicate_a_path).?;
    try std.testing.expectEqualStrings("duplicate_extension_provider", duplicate_a.conflict_kind);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_a.conflict_with, duplicate_a_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_a.conflict_with, duplicate_b_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_a.message, "skipped provider activation") != null);

    const duplicate_b = findProviderDiagnostic(contributions.provider_diagnostics, "extension_provider.duplicate_id", "ext-colliding-provider", duplicate_b_path).?;
    try std.testing.expectEqualStrings("duplicate_extension_provider", duplicate_b.conflict_kind);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_b.conflict_with, duplicate_a_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_b.conflict_with, duplicate_b_path) != null);

    const builtin = findProviderDiagnostic(contributions.provider_diagnostics, "extension_provider.builtin_collision", "openai", builtin_path).?;
    try std.testing.expectEqualStrings("builtin_provider", builtin.conflict_kind);
    try std.testing.expectEqualStrings("openai", builtin.conflict_with);
    try std.testing.expectEqualStrings(builtin_path, builtin.extension_path);
    try std.testing.expectEqualStrings(builtin_path, builtin.source_path);
}

test "extension startup loads approved explicit project and global extensions in deterministic order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/.pi/extensions/project-ext");
    try tmp.dir.createDirPath(std.testing.io, "agent/extensions/global-ext");

    try writeRegisteringExtensionScript(&tmp, "explicit.js", "explicit-tool", "Explicit Tool");
    try writeRegisteringExtensionScript(&tmp, "project/.pi/extensions/project-ext/index.js", "project-tool", "Project Tool");
    try writeRegisteringExtensionScript(&tmp, "agent/extensions/global-ext/index.js", "global-tool", "Global Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, "project");
    defer allocator.free(cwd);
    const agent_dir = try makeToolAdapterTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const explicit_path = try makeToolAdapterTestPath(allocator, tmp, "explicit.js");
    defer allocator.free(explicit_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var bundle = try resources_mod.loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .cli_extensions = &.{explicit_path},
        .env_map = &env_map,
    });
    defer bundle.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    for (bundle.extensions) |extension| {
        const key = try extension_runtime.typeScriptPolicyLookupKey(allocator, .{
            .configured_path = extension.source_info.path,
            .resolved_path = extension.path,
            .source_info = extension.source_info,
        });
        defer allocator.free(key);
        try putToolAdapterPolicy(allocator, &policy_map, key, .{ .grants = &.{"tool.use"} });
    }

    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, agent_dir, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = bundle.extensions,
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 3), built_tools.extension_hosts.len);
    try std.testing.expectEqual(@as(usize, 0), built_tools.startup_diagnostics.len);
    const explicit_index = findBuiltToolIndex(built_tools.items, "explicit-tool") orelse return error.TestUnexpectedMissingTool;
    const project_index = findBuiltToolIndex(built_tools.items, "project-tool") orelse return error.TestUnexpectedMissingTool;
    const global_index = findBuiltToolIndex(built_tools.items, "global-tool") orelse return error.TestUnexpectedMissingTool;
    try std.testing.expect(explicit_index < project_index);
    try std.testing.expect(project_index < global_index);
}

test "extension startup resolves manifest graph before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "provider");
    try tmp.dir.createDirPath(std.testing.io, "consumer");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "provider/index.js", "provider-tool", "Provider Tool", order_log, "provider");
    try writeRecordingExtensionScript(&tmp, "consumer/index.js", "consumer-tool", "Consumer Tool", order_log, "consumer");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "provider/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"provider.pkg\",\"name\":\"Provider\",\"version\":\"0.2.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"capabilities\":{\"exports\":[{\"id\":\"cap.startup\",\"kind\":\"tool\",\"version\":\"0.2.0\"}]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "consumer/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"consumer.pkg\",\"name\":\"Consumer\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"capabilities\":{\"imports\":[{\"id\":\"cap.startup\",\"kind\":\"tool\",\"version\":\"^0.2.0\"}]}}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const provider_path = try makeToolAdapterTestPath(allocator, tmp, "provider/index.js");
    defer allocator.free(provider_path);
    const consumer_path = try makeToolAdapterTestPath(allocator, tmp, "consumer/index.js");
    defer allocator.free(consumer_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var provider = try makeLoadedExtensionForTest(allocator, provider_path, .temporary);
    defer provider.deinit(allocator);
    var consumer = try makeLoadedExtensionForTest(allocator, consumer_path, .temporary);
    defer consumer.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, provider, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, consumer, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ consumer, provider },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.extension_hosts.len);
    const order = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, order_log, allocator, .unlimited);
    defer allocator.free(order);
    try std.testing.expectEqualStrings("provider\nconsumer\n", order);
    const provider_index = findBuiltToolIndex(built_tools.items, "provider-tool") orelse return error.TestUnexpectedMissingTool;
    const consumer_index = findBuiltToolIndex(built_tools.items, "consumer-tool") orelse return error.TestUnexpectedMissingTool;
    try std.testing.expect(provider_index < consumer_index);
}

test "package-origin extension startup resolves package-root manifest graph before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "pkg-provider/extensions/provider");
    try tmp.dir.createDirPath(std.testing.io, "pkg-consumer/extensions/consumer");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "package-startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "pkg-provider/extensions/provider/index.js", "package-provider-tool", "Package Provider Tool", order_log, "package-provider");
    try writeRecordingExtensionScript(&tmp, "pkg-consumer/extensions/consumer/index.js", "package-consumer-tool", "Package Consumer Tool", order_log, "package-consumer");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-provider/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.provider\",\"name\":\"Package Provider\",\"version\":\"0.2.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/provider/index.js\"},\"capabilities\":{\"exports\":[{\"id\":\"cap.package-startup\",\"kind\":\"tool\",\"version\":\"0.2.0\"}]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-consumer/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.consumer\",\"name\":\"Package Consumer\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/consumer/index.js\"},\"capabilities\":{\"imports\":[{\"id\":\"cap.package-startup\",\"kind\":\"tool\",\"version\":\"^0.2.0\"}]}}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const provider_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-provider");
    defer allocator.free(provider_root);
    const consumer_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-consumer");
    defer allocator.free(consumer_root);
    const provider_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-provider/extensions/provider/index.js");
    defer allocator.free(provider_path);
    const consumer_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-consumer/extensions/consumer/index.js");
    defer allocator.free(consumer_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var provider = try makePackageLoadedExtensionForTest(allocator, provider_path, provider_root, .project);
    defer provider.deinit(allocator);
    var consumer = try makePackageLoadedExtensionForTest(allocator, consumer_path, consumer_root, .project);
    defer consumer.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, provider, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, consumer, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ consumer, provider },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.extension_hosts.len);
    const order = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, order_log, allocator, .unlimited);
    defer allocator.free(order);
    try std.testing.expectEqualStrings("package-provider\npackage-consumer\n", order);
    const provider_index = findBuiltToolIndex(built_tools.items, "package-provider-tool") orelse return error.TestUnexpectedMissingTool;
    const consumer_index = findBuiltToolIndex(built_tools.items, "package-consumer-tool") orelse return error.TestUnexpectedMissingTool;
    try std.testing.expect(provider_index < consumer_index);
}

test "extension startup rejects invalid manifest graphs before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "cycle-a");
    try tmp.dir.createDirPath(std.testing.io, "cycle-b");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "cycle-startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "cycle-a/index.js", "cycle-a-tool", "Cycle A Tool", order_log, "cycle-a");
    try writeRecordingExtensionScript(&tmp, "cycle-b/index.js", "cycle-b-tool", "Cycle B Tool", order_log, "cycle-b");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cycle-a/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"cycle.a\",\"name\":\"Cycle A\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"dependencies\":[{\"id\":\"cycle.b\",\"version\":\"^1.0.0\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cycle-b/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"cycle.b\",\"name\":\"Cycle B\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"dependencies\":[{\"id\":\"cycle.a\",\"version\":\"^1.0.0\"}]}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const cycle_a_path = try makeToolAdapterTestPath(allocator, tmp, "cycle-a/index.js");
    defer allocator.free(cycle_a_path);
    const cycle_b_path = try makeToolAdapterTestPath(allocator, tmp, "cycle-b/index.js");
    defer allocator.free(cycle_b_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var cycle_a = try makeLoadedExtensionForTest(allocator, cycle_a_path, .temporary);
    defer cycle_a.deinit(allocator);
    var cycle_b = try makeLoadedExtensionForTest(allocator, cycle_b_path, .temporary);
    defer cycle_b.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_a, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_b, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ cycle_a, cycle_b },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 0), built_tools.extension_hosts.len);
    try std.testing.expect(findBuiltTool(built_tools.items, "cycle-a-tool") == null);
    try std.testing.expect(findBuiltTool(built_tools.items, "cycle-b-tool") == null);
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.cyclic_dependency"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.inactive_package"));
    try std.testing.expect(!pathExists(std.testing.io, order_log));
}

test "package-origin extension startup rejects invalid package-root manifest graphs before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "pkg-cycle-a/extensions/cycle-a");
    try tmp.dir.createDirPath(std.testing.io, "pkg-cycle-b/extensions/cycle-b");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "package-cycle-startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "pkg-cycle-a/extensions/cycle-a/index.js", "package-cycle-a-tool", "Package Cycle A Tool", order_log, "package-cycle-a");
    try writeRecordingExtensionScript(&tmp, "pkg-cycle-b/extensions/cycle-b/index.js", "package-cycle-b-tool", "Package Cycle B Tool", order_log, "package-cycle-b");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-cycle-a/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.cycle.a\",\"name\":\"Package Cycle A\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/cycle-a/index.js\"},\"dependencies\":[{\"id\":\"package.cycle.b\",\"version\":\"^1.0.0\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-cycle-b/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.cycle.b\",\"name\":\"Package Cycle B\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/cycle-b/index.js\"},\"dependencies\":[{\"id\":\"package.cycle.a\",\"version\":\"^1.0.0\"}]}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const cycle_a_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-a");
    defer allocator.free(cycle_a_root);
    const cycle_b_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-b");
    defer allocator.free(cycle_b_root);
    const cycle_a_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-a/extensions/cycle-a/index.js");
    defer allocator.free(cycle_a_path);
    const cycle_b_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-b/extensions/cycle-b/index.js");
    defer allocator.free(cycle_b_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var cycle_a = try makePackageLoadedExtensionForTest(allocator, cycle_a_path, cycle_a_root, .project);
    defer cycle_a.deinit(allocator);
    var cycle_b = try makePackageLoadedExtensionForTest(allocator, cycle_b_path, cycle_b_root, .project);
    defer cycle_b.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_a, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_b, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ cycle_a, cycle_b },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 0), built_tools.extension_hosts.len);
    try std.testing.expect(findBuiltTool(built_tools.items, "package-cycle-a-tool") == null);
    try std.testing.expect(findBuiltTool(built_tools.items, "package-cycle-b-tool") == null);
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.cyclic_dependency"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.inactive_package"));
    try std.testing.expect(!pathExists(std.testing.io, order_log));
}
