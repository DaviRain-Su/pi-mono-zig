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

test "extension startup diagnoses optional required and denied policy outcomes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeRegisteringExtensionScript(&tmp, "good.js", "good-tool", "Good Tool");
    try writeHangingExtensionScript(&tmp, "hang.js");
    try writeRegisteringExtensionScript(&tmp, "denied.js", "denied-tool", "Denied Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const good_path = try makeToolAdapterTestPath(allocator, tmp, "good.js");
    defer allocator.free(good_path);
    const hang_path = try makeToolAdapterTestPath(allocator, tmp, "hang.js");
    defer allocator.free(hang_path);
    const denied_path = try makeToolAdapterTestPath(allocator, tmp, "denied.js");
    defer allocator.free(denied_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "50");

    var good = try makeLoadedExtensionForTest(allocator, good_path, .temporary);
    defer good.deinit(allocator);
    var hang = try makeLoadedExtensionForTest(allocator, hang_path, .temporary);
    defer hang.deinit(allocator);
    var denied = try makeLoadedExtensionForTest(allocator, denied_path, .temporary);
    defer denied.deinit(allocator);

    var optional_policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var optional_policy_map_owned = true;
    errdefer if (optional_policy_map_owned) deinitToolAdapterPolicyMap(allocator, &optional_policy_map);
    try putLoadedExtensionPolicy(allocator, &optional_policy_map, good, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &optional_policy_map, hang, .{ .grants = &.{"tool.use"}, .startup_timeout_ms = 50 });
    try putLoadedExtensionPolicy(allocator, &optional_policy_map, denied, .{ .grants = &.{} });
    var optional_runtime = try makeToolAdapterRuntimeConfig(allocator, cwd, optional_policy_map);
    optional_policy_map_owned = false;
    defer optional_runtime.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var optional_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ good, hang, denied },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &optional_runtime,
    });
    defer optional_tools.deinit();

    try std.testing.expect(findBuiltTool(optional_tools.items, "good-tool") != null);
    try std.testing.expect(findBuiltTool(optional_tools.items, "denied-tool") == null);
    try std.testing.expectEqual(@as(usize, 1), optional_tools.extension_hosts.len);
    try std.testing.expect(optional_tools.startup_diagnostics.len >= 2);
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "startup timed out"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "approvedGrants does not include tool.use"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "extensionId="));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "source="));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "severity=error"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "phase=policy"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "phase=startup"));
    try std.testing.expect(!optional_tools.required_startup_failed);

    var required_policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    var required_policy_map_owned = true;
    errdefer if (required_policy_map_owned) deinitToolAdapterPolicyMap(allocator, &required_policy_map);
    try putLoadedExtensionPolicy(allocator, &required_policy_map, hang, .{ .grants = &.{"tool.use"}, .required = true, .startup_timeout_ms = 50 });
    var required_runtime = try makeToolAdapterRuntimeConfig(allocator, cwd, required_policy_map);
    required_policy_map_owned = false;
    defer required_runtime.deinit();

    var required_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{hang},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &required_runtime,
    });
    defer required_tools.deinit();
    try std.testing.expect(required_tools.required_startup_failed);
    try std.testing.expectEqual(@as(usize, 0), required_tools.extension_hosts.len);
    try std.testing.expect(startupDiagnosticContains(required_tools.startup_diagnostics, "required=true"));
    try std.testing.expect(startupDiagnosticContains(required_tools.startup_diagnostics, "phase=startup"));
    try std.testing.expect(startupDiagnosticContains(required_tools.startup_diagnostics, hang_path));

    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    try writeStartupDiagnostics(&stderr_capture.writer, required_tools.startup_diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Error: extension failed:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "startup timed out") != null);
}
