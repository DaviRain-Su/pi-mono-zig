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

test "buildAgentTools threads app context into execute callbacks" {
    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentTools(std.testing.allocator, &app_context, &[_][]const u8{ "read", "bash" });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.items.len);
    for (built_tools.items) |tool| {
        try std.testing.expect(tool.execute != null);
        try std.testing.expect(tool.execute_context == @as(?*anyopaque, @ptrCast(&app_context)));
    }
}

test "installed wasm tool conflicts with built-ins emit diagnostic and skip duplicate" {
    const allocator = std.testing.allocator;

    var items = std.ArrayList(agent.AgentTool).empty;
    defer {
        for (items.items) |*item| common.deinitJsonValue(allocator, item.parameters);
        items.deinit(allocator);
    }
    try items.append(allocator, .{
        .name = "read",
        .description = "built-in read",
        .label = "read",
        .parameters = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        .execute = null,
        .execute_context = null,
    });

    var runtime_set = extension_runtime.LockedWasmRuntimeSet{
        .allocator = allocator,
        .entries = try allocator.alloc(extension_runtime.LockedWasmRuntimeEntry, 1),
        .diagnostics = &.{},
    };
    defer runtime_set.deinit();
    runtime_set.entries[0] = .{
        .package_root = try allocator.dupe(u8, "/tmp/conflicting-package"),
        .manifest_path = try allocator.dupe(u8, "/tmp/conflicting-package/pi-extension.json"),
        .tool_id = try allocator.dupe(u8, "read"),
        .policy_lookup_key = try allocator.dupe(u8, "wasm:conflicting-package"),
        .adapter = .{
            .ptr = @ptrFromInt(1),
            .vtable = &conflict_test_vtable,
            .kind = .wasm,
        },
    };

    try appendLockedWasmTools(allocator, &items, &runtime_set, tool_selection_mod.ToolSelection.fromAllowlist(&.{"read"}));

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("read", items.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), runtime_set.diagnostics.len);
    try std.testing.expectEqualStrings("builtin_wasm_tool_conflict", runtime_set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "conflicting-package") != null);
}

const conflict_test_vtable: extension_runtime.RuntimeAdapter.VTable = .{
    .wait_for_ready = conflictTestWaitForReady,
    .pending_count = conflictTestPendingCount,
    .diagnostic_count = conflictTestPendingCount,
    .diagnostic_category_count = conflictTestDiagnosticCategoryCount,
    .has_shutdown_complete = conflictTestHasShutdownComplete,
    .registry_frames_applied = conflictTestPendingCount,
    .has_registered_command = conflictTestHasRegisteredCommand,
    .has_registered_hook = conflictTestHasRegisteredHook,
    .snapshot_registry_json = conflictTestSnapshotRegistryJson,
    .with_registry = conflictTestWithRegistry,
    .apply_cli_flag_values = conflictTestApplyCliFlagValues,
    .agent_tool = conflictTestAgentTool,
    .take_ui_requests = conflictTestTakeUiRequests,
    .send_extension_ui_response = conflictTestSendExtensionUiResponse,
    .send_extension_event_frame = conflictTestSendExtensionEventFrame,
    .invoke_extension_event = conflictTestInvokeExtensionEvent,
    .shutdown = conflictTestShutdown,
    .deinit = conflictTestDeinit,
};

fn conflictTestWaitForReady(_: *anyopaque, _: u64) !void {}
fn conflictTestPendingCount(_: *anyopaque) usize {
    return 0;
}
fn conflictTestDiagnosticCategoryCount(_: *anyopaque, _: extension_runtime.DiagnosticCategory) usize {
    return 0;
}
fn conflictTestHasShutdownComplete(_: *anyopaque) bool {
    return true;
}
fn conflictTestHasRegisteredCommand(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn conflictTestHasRegisteredHook(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn conflictTestSnapshotRegistryJson(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{}");
}
fn conflictTestWithRegistry(_: *anyopaque, _: ?*anyopaque, _: extension_runtime.RegistryCallback) !void {}
fn conflictTestApplyCliFlagValues(_: *anyopaque, _: []const extension_registry.ParsedCliFlag) !void {}
fn conflictTestAgentTool(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !?agent.AgentTool {
    return error.UnexpectedBuiltinConflictAgentToolConstruction;
}
fn conflictTestTakeUiRequests(_: *anyopaque, allocator: std.mem.Allocator) ![]extension_runtime.ExtensionUiRequest {
    return allocator.alloc(extension_runtime.ExtensionUiRequest, 0);
}
fn conflictTestSendExtensionUiResponse(_: *anyopaque, _: []const u8, _: []const u8) !void {}
fn conflictTestSendExtensionEventFrame(_: *anyopaque, _: []const u8) void {}
fn conflictTestInvokeExtensionEvent(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: std.json.Value, _: u64) !?std.json.Value {
    return null;
}
fn conflictTestShutdown(_: *anyopaque) !void {}
fn conflictTestDeinit(_: *anyopaque) void {}

test "forwardBashToolUpdate borrows streaming content without freeing it twice" {
    const allocator = std.testing.allocator;

    const Capture = struct {
        allocator: std.mem.Allocator,
        text: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.text) |text| self.allocator.free(text);
        }

        fn collect(context: ?*anyopaque, partial_result: agent.AgentToolResult) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(usize, 1), partial_result.content.len);
            try std.testing.expectEqualStrings("streaming update", partial_result.content[0].text.text);
            self.text = try self.allocator.dupe(u8, partial_result.content[0].text.text);
        }
    };

    var capture = Capture{ .allocator = allocator };
    defer capture.deinit();

    var context = BashToolUpdateForwardContext{
        .allocator = allocator,
        .downstream_context = &capture,
        .downstream = Capture.collect,
    };

    var result = tools.BashExecutionResult{
        .content = try common.makeTextContent(allocator, "streaming update"),
        .details = null,
        .is_error = false,
    };
    defer result.deinit(allocator);

    try forwardBashToolUpdate(&context, result);
    try std.testing.expectEqualStrings("streaming update", capture.text.?);
}

test "buildAgentTools accepts bash timeout alias through the agent adapter" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    try env_map.put("PI_FAUX_TOOL_NAME", "bash");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"command\":\"sleep 5\",\"timeout\":1}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "The command timed out");

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var app_context = AppContext.init(root_dir, std.testing.io);
    var built_tools = try buildAgentTools(allocator, &app_context, &[_][]const u8{"bash"});
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try session.prompt("run bash with alias timeout");

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);

    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, root_dir);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("bash", context.messages[2].tool_result.tool_name);
    try std.testing.expect(context.messages[2].tool_result.details != null);
    const details = context.messages[2].tool_result.details.?.object;
    try std.testing.expectEqual(true, details.get("timed_out").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[2].tool_result.content[0].text.text, "Command timed out after 1 seconds") != null);
}
