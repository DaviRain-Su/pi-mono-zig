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

test "extension reload swaps tool registry and shuts down removed hosts" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const shutdown_capture = try makeToolAdapterTestPath(allocator, tmp, "old-shutdown.jsonl");
    defer allocator.free(shutdown_capture);
    const old_script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"old-tool\",\"label\":\"Old Tool\",\"description\":\"old description\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}},\"extensionPath\":\"old.js\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in *'\"shutdown\"'*) printf '%s\\n' \"$line\" >> {s}; printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac\n" ++
            "done\n",
        .{shutdown_capture},
    );
    defer allocator.free(old_script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old.js", .data = old_script });
    try writeRegisteringExtensionScript(&tmp, "new.js", "new-tool", "New Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const old_path = try makeToolAdapterTestPath(allocator, tmp, "old.js");
    defer allocator.free(old_path);
    const new_path = try makeToolAdapterTestPath(allocator, tmp, "new.js");
    defer allocator.free(new_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var old_extension = try makeLoadedExtensionForTest(allocator, old_path, .temporary);
    defer old_extension.deinit(allocator);
    var new_extension = try makeLoadedExtensionForTest(allocator, new_path, .temporary);
    defer new_extension.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, old_extension, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, new_extension, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{old_extension},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();
    try std.testing.expect(findBuiltTool(built_tools.items, "old-tool") != null);
    try std.testing.expect(findBuiltTool(built_tools.items, "new-tool") == null);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = cwd,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try replaceAgentToolsForReload(allocator, &app_context, &session, &built_tools, .{}, .{
        .extensions = &.{new_extension},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });

    try std.testing.expect(findBuiltTool(session.agent.getTools(), "old-tool") == null);
    try std.testing.expect(findBuiltTool(session.agent.getTools(), "new-tool") != null);

    const shutdown_log = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, shutdown_capture, allocator, .unlimited);
    defer allocator.free(shutdown_log);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_log, "\"type\":\"shutdown\"") != null);
}

test "extension reload diagnostics distinguish parse policy and runtime failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parse_script =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf 'not-json\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "parse.js", .data = parse_script });
    const runtime_script =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"diagnostic\",\"category\":\"host_error\",\"severity\":\"error\",\"message\":\"runtime failed\"}\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "runtime.js", .data = runtime_script });
    try writeRegisteringExtensionScript(&tmp, "denied.js", "denied-tool", "Denied Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const parse_path = try makeToolAdapterTestPath(allocator, tmp, "parse.js");
    defer allocator.free(parse_path);
    const runtime_path = try makeToolAdapterTestPath(allocator, tmp, "runtime.js");
    defer allocator.free(runtime_path);
    const denied_path = try makeToolAdapterTestPath(allocator, tmp, "denied.js");
    defer allocator.free(denied_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var parse_extension = try makeLoadedExtensionForTest(allocator, parse_path, .temporary);
    defer parse_extension.deinit(allocator);
    var runtime_extension = try makeLoadedExtensionForTest(allocator, runtime_path, .temporary);
    defer runtime_extension.deinit(allocator);
    var denied_extension = try makeLoadedExtensionForTest(allocator, denied_path, .temporary);
    defer denied_extension.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var policy_map_owned = true;
    errdefer if (policy_map_owned) deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, parse_extension, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, runtime_extension, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, denied_extension, .{ .grants = &.{} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    policy_map_owned = false;
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ parse_extension, denied_extension, runtime_extension },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "phase=parse"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "category=malformed_json"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "phase=policy"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "phase=runtime"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "category=host_error"));
}
