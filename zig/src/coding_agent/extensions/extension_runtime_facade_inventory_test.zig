const std = @import("std");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const extension_events = @import("extension_events.zig");
const extension_registry = @import("extension_registry.zig");
const extension_runtime = @import("extension_runtime.zig");
const resources_mod = @import("../resources/resources.zig");
const tools_common = @import("../tools/common.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");

test "extension runtime public facade inventory remains source-compatible" {
    _ = extension_runtime.RuntimeKind;
    _ = extension_runtime.RuntimeOptions;
    _ = extension_runtime.WasmOptions;
    _ = extension_runtime.UnsupportedRuntimeOptions;
    _ = extension_runtime.RuntimeSetupErrorEvent;
    _ = extension_runtime.RuntimeSetupEvent;
    _ = extension_runtime.RuntimeSetupEventStream;
    _ = extension_runtime.RuntimeAdapter;
    _ = extension_runtime.WasmManifestHandoff;
    _ = extension_runtime.RuntimeHookDefinition;
    _ = extension_runtime.NativeDescriptor;
    _ = extension_runtime.NativeHostApi;
    _ = extension_runtime.NativeOptions;
    _ = extension_runtime.NativeResourceLimits;
    _ = extension_runtime.NativeHookDefinition;
    _ = extension_runtime.NativeToolDefinition;
    _ = extension_runtime.LockedWasmRuntimeSet;
    _ = extension_runtime.LockedNativeRuntimeSet;
    _ = extension_runtime.NativePackageLoader;
    _ = extension_runtime.TypeScriptPolicyLookupOptions;
    _ = extension_runtime.WasmManifestPolicyLookupOptions;
    _ = extension_runtime.ProcessJsonlOptions;
    _ = extension_runtime.InitializeFrame;
    _ = extension_runtime.ExtensionUiRequest;
    _ = extension_runtime.DiagnosticCategory;
    _ = extension_runtime.Registry;
    _ = extension_runtime.RegistryCallback;
    _ = extension_runtime.LifecycleSupportRuntime;
    _ = extension_runtime.LifecycleSupportEntry;

    _ = extension_runtime.default_extension_handler_timeout_ms;
    _ = extension_runtime.lifecycleSupportMatrix;
    _ = extension_runtime.startRuntime;
    _ = extension_runtime.streamRuntimeSetup;
    _ = extension_runtime.startRuntimeAdapter;
    _ = extension_runtime.startWasm;
    _ = extension_runtime.startNative;
    _ = extension_runtime.native_vtable;
    _ = extension_runtime.startLockedWasmPackageRuntimes;
    _ = extension_runtime.startLockedNativePackageRuntimes;
    _ = extension_runtime.startLockedNativePackageRuntimesWithLoader;
    _ = extension_runtime.typeScriptPolicyLookupKey;
    _ = extension_runtime.wasmManifestPolicyLookupKey;
    _ = extension_runtime.wasmPolicyLookupKey;
    _ = extension_runtime.nativePolicyLookupKey;
    _ = extension_runtime.processJsonlPolicyLookupKey;
    _ = extension_runtime.approvedCapabilitiesFromExtensionPolicy;
    _ = extension_runtime.enforcementResourceLimitsFromExtensionPolicy;
    _ = extension_runtime.nativeResourceLimitsFromExtensionPolicy;
    _ = extension_runtime.deinitAgentTool;

    var setup_stream = extension_runtime.RuntimeSetupEventStream{ .event = null };
    try std.testing.expect(setup_stream.next() == null);
    setup_stream.deinit();
}

test "runtime kind JSON names are byte-stable" {
    const expected = [_]struct {
        kind: extension_runtime.RuntimeKind,
        json_name: []const u8,
    }{
        .{ .kind = .process_jsonl, .json_name = "process_jsonl" },
        .{ .kind = .wasm, .json_name = "wasm" },
        .{ .kind = .native, .json_name = "native" },
        .{ .kind = .remote, .json_name = "remote" },
    };

    try std.testing.expectEqual(expected.len, @typeInfo(extension_runtime.RuntimeKind).@"enum".fields.len);
    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry.json_name, entry.kind.jsonName());
    }
}

const CountingAdapterState = struct {
    deinit_count: usize = 0,
};

fn countingWaitForReady(ptr: *anyopaque, timeout_ms: u64) !void {
    _ = ptr;
    _ = timeout_ms;
}

fn countingPendingCount(ptr: *anyopaque) usize {
    _ = ptr;
    return 0;
}

fn countingDiagnosticCount(ptr: *anyopaque) usize {
    _ = ptr;
    return 0;
}

fn countingDiagnosticCategoryCount(ptr: *anyopaque, category: extension_runtime.DiagnosticCategory) usize {
    _ = ptr;
    _ = category;
    return 0;
}

fn countingHasShutdownComplete(ptr: *anyopaque) bool {
    _ = ptr;
    return true;
}

fn countingRegistryFramesApplied(ptr: *anyopaque) usize {
    _ = ptr;
    return 0;
}

fn countingHasRegisteredCommand(ptr: *anyopaque, name: []const u8) bool {
    _ = ptr;
    _ = name;
    return false;
}

fn countingHasRegisteredHook(ptr: *anyopaque, event_name: []const u8) bool {
    _ = ptr;
    _ = event_name;
    return false;
}

fn countingSnapshotRegistryJson(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    _ = ptr;
    return try allocator.dupe(u8, "{}");
}

fn countingWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: extension_runtime.RegistryCallback) !void {
    _ = ptr;
    var registry = extension_runtime.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try callback(context, &registry);
}

fn countingApplyCliFlagValues(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    _ = ptr;
    _ = entries;
}

fn countingAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    _ = ptr;
    _ = allocator;
    _ = name;
    return null;
}

fn countingTakeUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]extension_runtime.ExtensionUiRequest {
    _ = ptr;
    return try allocator.alloc(extension_runtime.ExtensionUiRequest, 0);
}

fn countingSendExtensionUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    _ = ptr;
    _ = id;
    _ = payload_json;
}

fn countingSendExtensionEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    _ = ptr;
    _ = frame_json;
}

fn countingInvokeExtensionEvent(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    _ = ptr;
    _ = allocator;
    _ = event_name;
    _ = event;
    _ = timeout_ms;
    return null;
}

fn countingShutdown(ptr: *anyopaque) !void {
    _ = ptr;
}

fn countingDeinit(ptr: *anyopaque) void {
    const state: *CountingAdapterState = @ptrCast(@alignCast(ptr));
    state.deinit_count += 1;
}

const counting_vtable: extension_runtime.RuntimeAdapter.VTable = .{
    .wait_for_ready = countingWaitForReady,
    .pending_count = countingPendingCount,
    .diagnostic_count = countingDiagnosticCount,
    .diagnostic_category_count = countingDiagnosticCategoryCount,
    .has_shutdown_complete = countingHasShutdownComplete,
    .registry_frames_applied = countingRegistryFramesApplied,
    .has_registered_command = countingHasRegisteredCommand,
    .has_registered_hook = countingHasRegisteredHook,
    .snapshot_registry_json = countingSnapshotRegistryJson,
    .with_registry = countingWithRegistry,
    .apply_cli_flag_values = countingApplyCliFlagValues,
    .agent_tool = countingAgentTool,
    .take_ui_requests = countingTakeUiRequests,
    .send_extension_ui_response = countingSendExtensionUiResponse,
    .send_extension_event_frame = countingSendExtensionEventFrame,
    .invoke_extension_event = countingInvokeExtensionEvent,
    .shutdown = countingShutdown,
    .deinit = countingDeinit,
};

fn countingAdapter(state: *CountingAdapterState) extension_runtime.RuntimeAdapter {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &counting_vtable,
        .kind = .native,
    };
}

test "runtime setup stream transfers ready adapter ownership exactly once" {
    var unconsumed_state = CountingAdapterState{};
    var unconsumed_stream = extension_runtime.RuntimeSetupEventStream{
        .event = .{ .ready = countingAdapter(&unconsumed_state) },
    };
    unconsumed_stream.deinit();
    try std.testing.expectEqual(@as(usize, 1), unconsumed_state.deinit_count);
    try std.testing.expect(unconsumed_stream.next() == null);
    unconsumed_stream.deinit();
    try std.testing.expectEqual(@as(usize, 1), unconsumed_state.deinit_count);

    var consumed_state = CountingAdapterState{};
    var consumed_stream = extension_runtime.RuntimeSetupEventStream{
        .event = .{ .ready = countingAdapter(&consumed_state) },
    };
    const consumed_event = consumed_stream.next().?;
    try std.testing.expect(consumed_event == .ready);
    consumed_stream.deinit();
    try std.testing.expectEqual(@as(usize, 0), consumed_state.deinit_count);
    consumed_event.ready.deinit();
    try std.testing.expectEqual(@as(usize, 1), consumed_state.deinit_count);

    var error_stream = extension_runtime.RuntimeSetupEventStream{
        .event = .{ .error_event = .{
            .runtime_kind = .remote,
            .extension_id = "remote",
            .error_name = "UnsupportedRuntime",
            .message = "runtime setup failed before extension activation completed",
        } },
    };
    error_stream.deinit();
    try std.testing.expect(error_stream.next() == null);
}

fn nativeSetupFailureStart(api: *extension_runtime.NativeHostApi) !void {
    _ = api;
    return error.FacadeInventoryInjectedFailure;
}

const native_setup_failure_descriptor: extension_runtime.NativeDescriptor = .{
    .id = "com.pi.facade-setup-failure",
    .name = "Facade Setup Failure",
    .version = "0.1.0",
    .description = "Native facade setup failure fixture",
    .start = nativeSetupFailureStart,
};

fn expectSetupErrorEvent(
    stream: *extension_runtime.RuntimeSetupEventStream,
    kind: extension_runtime.RuntimeKind,
    extension_id: []const u8,
    error_name: []const u8,
) !void {
    const event = stream.next().?;
    try std.testing.expect(event == .error_event);
    try std.testing.expectEqual(kind, event.error_event.runtime_kind);
    try std.testing.expectEqualStrings(extension_id, event.error_event.extension_id);
    try std.testing.expectEqualStrings(error_name, event.error_event.error_name);
    try std.testing.expectEqualStrings(
        "runtime setup failed before extension activation completed",
        event.error_event.message,
    );
    try std.testing.expectEqualStrings("error_reason", event.error_event.stop_reason);
    try std.testing.expect(stream.next() == null);
}

test "runtime setup failures are terminal diagnostic events with stable text" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const requested = [_]wasm_manifest.Capability{.file_read};
    var denied_handoff = extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid);
    denied_handoff.requested_capabilities = requested[0..];
    var wasm_stream = try extension_runtime.streamRuntimeSetup(allocator, std.testing.io, .{ .wasm = .{ .manifest = denied_handoff } });
    try expectSetupErrorEvent(
        &wasm_stream,
        .wasm,
        "com.pi.pure-truncate-head",
        "UnsupportedRuntimeCapability",
    );

    var native_stream = try extension_runtime.streamRuntimeSetup(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_setup_failure_descriptor,
    } });
    try expectSetupErrorEvent(
        &native_stream,
        .native,
        "com.pi.facade-setup-failure",
        "FacadeInventoryInjectedFailure",
    );

    var remote_stream = try extension_runtime.streamRuntimeSetup(allocator, std.testing.io, .{ .remote = .{ .label = "remote-facade" } });
    try expectSetupErrorEvent(
        &remote_stream,
        .remote,
        "remote-facade",
        "UnsupportedRuntime",
    );
}

test "policy lookup key edge cases stay byte-stable through facade" {
    const allocator = std.testing.allocator;

    const fallback_inline_source_info = resources_mod.SourceInfo{
        .path = @constCast("<inline:2>"),
        .source = @constCast(""),
        .scope = .temporary,
        .origin = .top_level,
    };
    const inline_key = try extension_runtime.typeScriptPolicyLookupKey(allocator, .{
        .configured_path = "<inline:2>",
        .resolved_path = "<inline:2>",
        .source_info = fallback_inline_source_info,
    });
    defer allocator.free(inline_key);
    try std.testing.expectEqualStrings("typescript:inline:temporary:<inline:2>", inline_key);

    const outside_package_source_info = resources_mod.SourceInfo{
        .path = @constCast("/outside/entry.ts"),
        .source = @constCast("/workspace/pkg"),
        .scope = .user,
        .origin = .package,
        .base_dir = @constCast("/workspace/pkg"),
    };
    const outside_package_key = try extension_runtime.typeScriptPolicyLookupKey(allocator, .{
        .configured_path = "/outside/entry.ts",
        .resolved_path = "/outside/entry.ts",
        .source_info = outside_package_source_info,
    });
    defer allocator.free(outside_package_key);
    try std.testing.expectEqualStrings(
        "typescript:package:user:/workspace/pkg:/outside/entry.ts:/outside/entry.ts",
        outside_package_key,
    );

    const wasm_key = try extension_runtime.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff{
        .policy_scope = "project",
        .schema_version = "pi-extension.v0",
        .id = "com.pi.edge",
        .name = "Edge",
        .version = "0.1.0",
        .description = "Edge",
        .artifact_kind = .wasm_component,
        .artifact_path = "wasm\\plugin.wasm",
        .artifact_absolute_path = "/pkg\\wasm\\plugin.wasm",
        .tool_id = "edge.tool",
        .tool_description = "Edge tool",
        .input_schema_json = "{}",
        .output_schema_json = "{}",
        .manifest_path = "/pkg\\pi-extension.json",
    });
    defer allocator.free(wasm_key);
    try std.testing.expectEqualStrings(
        "wasm:locked:project:pi-extension.v0:com.pi.edge:0.1.0:::/pkg/pi-extension.json:/pkg/wasm/plugin.wasm",
        wasm_key,
    );

    const process_without_optional_fields = try extension_runtime.processJsonlPolicyLookupKey(allocator, .{
        .argv = &.{ "bun", "extensions\\host.ts" },
        .cwd = null,
        .extension_path = null,
        .initialize = .{ .marker = "marker", .cwd = "/ignored", .fixture = "ignored" },
    });
    defer allocator.free(process_without_optional_fields);
    try std.testing.expectEqualStrings(
        "process_jsonl:{\"argv\":[\"bun\",\"extensions/host.ts\"]}",
        process_without_optional_fields,
    );

    const process_with_normalized_fields = try extension_runtime.processJsonlPolicyLookupKey(allocator, .{
        .argv = &.{ "/bin/pi-extension-host", "extensions\\host.ts" },
        .cwd = "/workspace\\project",
        .extension_path = "/workspace\\project\\extensions\\host.ts",
        .initialize = .{ .marker = "marker", .cwd = "/ignored", .fixture = "ignored" },
    });
    defer allocator.free(process_with_normalized_fields);
    try std.testing.expectEqualStrings(
        "process_jsonl:{\"argv\":[\"/bin/pi-extension-host\",\"extensions/host.ts\"],\"extensionPath\":\"/workspace/project/extensions/host.ts\",\"cwd\":\"/workspace/project\"}",
        process_with_normalized_fields,
    );
}

test "policy capability and resource helper semantics stay stable through facade" {
    const allocator = std.testing.allocator;

    const empty_capabilities = try extension_runtime.approvedCapabilitiesFromExtensionPolicy(allocator, .{});
    defer allocator.free(empty_capabilities);
    try std.testing.expectEqual(@as(usize, 0), empty_capabilities.len);

    const approved_grants = [_][]const u8{
        "file.read",
        "not-a-capability",
        "agent.spawn",
        "",
    };
    const policy_tool_scopes = [_][]const u8{ "policy.tool", "policy.other" };
    const policy = config_mod.ExtensionPolicy{
        .approved_grants = &approved_grants,
        .resource_limits = .{
            .max_children = 3,
            .turns = 9,
            .timeout_ms = 100,
            .output_lines = 5,
            .tool_scopes = &policy_tool_scopes,
        },
    };

    const approved_capabilities = try extension_runtime.approvedCapabilitiesFromExtensionPolicy(allocator, policy);
    defer allocator.free(approved_capabilities);
    try std.testing.expectEqual(@as(usize, 2), approved_capabilities.len);
    try std.testing.expectEqual(wasm_manifest.Capability.file_read, approved_capabilities[0]);
    try std.testing.expectEqual(wasm_manifest.Capability.agent_spawn, approved_capabilities[1]);

    const enforcement_limits = extension_runtime.enforcementResourceLimitsFromExtensionPolicy(policy.resource_limits);
    try std.testing.expectEqual(@as(?u64, 3), enforcement_limits.max_children);
    try std.testing.expectEqual(@as(?u64, null), enforcement_limits.depth);
    try std.testing.expectEqual(@as(?u64, 9), enforcement_limits.turns);
    try std.testing.expectEqual(@as(?u64, 100), enforcement_limits.timeout_ms);
    try std.testing.expectEqual(@as(?u64, null), enforcement_limits.output_bytes);
    try std.testing.expectEqual(@as(?u64, 5), enforcement_limits.output_lines);
    try std.testing.expectEqual(@as(usize, 2), enforcement_limits.tool_scopes.len);
    try std.testing.expectEqualStrings("policy.tool", enforcement_limits.tool_scopes[0]);
    try std.testing.expectEqualStrings("policy.other", enforcement_limits.tool_scopes[1]);

    const descriptor_tool_scopes = [_][]const u8{"descriptor.tool"};
    const descriptor_limits = extension_runtime.NativeResourceLimits{
        .max_children = 5,
        .depth = 2,
        .timeout_ms = 50,
        .output_bytes = 1024,
        .tool_scopes = &descriptor_tool_scopes,
    };
    const unchanged_descriptor = extension_runtime.nativeResourceLimitsFromExtensionPolicy(null, descriptor_limits);
    try std.testing.expectEqual(@as(?u64, 5), unchanged_descriptor.max_children);
    try std.testing.expectEqual(@as(?u64, 2), unchanged_descriptor.depth);
    try std.testing.expectEqual(@as(?u64, 50), unchanged_descriptor.timeout_ms);
    try std.testing.expectEqual(@as(?u64, 1024), unchanged_descriptor.output_bytes);
    try std.testing.expectEqualStrings("descriptor.tool", unchanged_descriptor.tool_scopes[0]);

    const narrowed = extension_runtime.nativeResourceLimitsFromExtensionPolicy(policy.resource_limits, descriptor_limits);
    try std.testing.expectEqual(@as(?u64, 3), narrowed.max_children);
    try std.testing.expectEqual(@as(?u64, 2), narrowed.depth);
    try std.testing.expectEqual(@as(?u64, 9), narrowed.turns);
    try std.testing.expectEqual(@as(?u64, 50), narrowed.timeout_ms);
    try std.testing.expectEqual(@as(?u64, 1024), narrowed.output_bytes);
    try std.testing.expectEqual(@as(?u64, 5), narrowed.output_lines);
    try std.testing.expectEqual(@as(usize, 2), narrowed.tool_scopes.len);
    try std.testing.expectEqualStrings("policy.tool", narrowed.tool_scopes[0]);
    try std.testing.expectEqualStrings("policy.other", narrowed.tool_scopes[1]);
}

const DeinitToolContextState = struct {
    expected_allocator: std.mem.Allocator,
    called: bool = false,
    allocator_matched: bool = false,
};

const DeinitToolContext = struct {
    state: *DeinitToolContextState,
};

fn deinitTestExecuteContext(allocator: std.mem.Allocator, tool_context: ?*anyopaque) void {
    const context: *DeinitToolContext = @ptrCast(@alignCast(tool_context.?));
    context.state.called = true;
    context.state.allocator_matched = allocator.ptr == context.state.expected_allocator.ptr and
        allocator.vtable == context.state.expected_allocator.vtable;
    allocator.destroy(context);
}

test "deinitAgentTool owns parameters and original execute context cleanup" {
    const allocator = std.testing.allocator;

    var parameters = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, parameters);
    try parameters.object.put(
        allocator,
        try allocator.dupe(u8, "type"),
        .{ .string = try allocator.dupe(u8, "object") },
    );
    try parameters.object.put(
        allocator,
        try allocator.dupe(u8, "additionalProperties"),
        .{ .bool = false },
    );

    var state = DeinitToolContextState{ .expected_allocator = allocator };
    const context = try allocator.create(DeinitToolContext);
    context.* = .{ .state = &state };
    var tool = agent.AgentTool{
        .name = "facade.deinit",
        .description = "Facade deinit tool",
        .label = "Facade deinit",
        .parameters = parameters,
        .source = .extension,
        .execute_context = context,
        .deinit_execute_context = deinitTestExecuteContext,
    };

    extension_runtime.deinitAgentTool(allocator, &tool);
    try std.testing.expect(state.called);
    try std.testing.expect(state.allocator_matched);
}

test "lifecycle support facade re-exports exact runtime matrix ordering" {
    const matrix = extension_runtime.lifecycleSupportMatrix();
    const canonical_event_surface = extension_events.eventSurfaceNames();
    const expected_runtimes = [_]extension_runtime.LifecycleSupportRuntime{
        .typescript,
        .process_jsonl,
        .wasm,
        .native,
        .zig,
    };

    try std.testing.expectEqual(expected_runtimes.len, matrix.len);
    for (expected_runtimes, 0..) |runtime, index| {
        const entry: extension_runtime.LifecycleSupportEntry = matrix[index];
        try std.testing.expectEqual(runtime, entry.runtime);
        try std.testing.expectEqual(extension_runtime.default_extension_handler_timeout_ms, entry.timeout_default_ms);
        try std.testing.expectEqualStrings("lifecycle-handler-timeout-ms", entry.timeout_source);
        try std.testing.expectEqualStrings("startup", entry.reasons[0]);
        try std.testing.expectEqualStrings("reload", entry.reasons[1]);
        try std.testing.expectEqualStrings("new", entry.reasons[2]);
        try std.testing.expectEqualStrings("resume", entry.reasons[3]);
        try std.testing.expectEqualStrings("fork", entry.reasons[4]);
        try std.testing.expectEqualStrings("none", entry.result_types[0]);
        try std.testing.expectEqualStrings("cancellable", entry.result_types[1]);
        try std.testing.expectEqualStrings("resources", entry.result_types[2]);
        try std.testing.expect(entry.shutdown_supported);
        try std.testing.expect(entry.shutdown_exactly_once);
        try std.testing.expectEqualStrings("ignored", entry.late_results);
        switch (entry.runtime) {
            .typescript, .process_jsonl, .zig => {
                try std.testing.expectEqual(canonical_event_surface.len, entry.event_names.len);
                for (canonical_event_surface, 0..) |event_name, event_index| {
                    try std.testing.expectEqualStrings(event_name, entry.event_names[event_index]);
                }
            },
            .wasm, .native => {
                try std.testing.expectEqual(@as(usize, 3), entry.event_names.len);
                try std.testing.expectEqualStrings("session_start", entry.event_names[0]);
                try std.testing.expectEqualStrings("session_shutdown", entry.event_names[1]);
                try std.testing.expectEqualStrings("resources_discover", entry.event_names[2]);
            },
        }
    }
}
