const std = @import("std");
const agent = @import("agent");
const extension_registry = @import("extension_registry.zig");
const native_runtime = @import("native_runtime.zig");
const runtime_adapter = @import("runtime_adapter.zig");

const DiagnosticCategory = runtime_adapter.DiagnosticCategory;
const ExtensionUiRequest = runtime_adapter.ExtensionUiRequest;
const NativeOptions = runtime_adapter.NativeOptions;
const RegistryCallback = runtime_adapter.RegistryCallback;
const RuntimeAdapter = runtime_adapter.RuntimeAdapter;

pub fn startNative(allocator: std.mem.Allocator, io: std.Io, options: NativeOptions) !RuntimeAdapter {
    const runtime = try native_runtime.NativeRuntime.start(allocator, io, options);
    return .{
        .ptr = @ptrCast(runtime),
        .vtable = &native_vtable,
        .kind = .native,
    };
}

pub fn nativeRuntime(ptr: *anyopaque) *native_runtime.NativeRuntime {
    return @ptrCast(@alignCast(ptr));
}

fn nativeWaitForReady(ptr: *anyopaque, timeout_ms: u64) !void {
    try nativeRuntime(ptr).waitForReady(timeout_ms);
}

fn nativePendingCount(ptr: *anyopaque) usize {
    return nativeRuntime(ptr).pendingCount();
}

fn nativeDiagnosticCount(ptr: *anyopaque) usize {
    return nativeRuntime(ptr).diagnosticCount();
}

fn nativeDiagnosticCategoryCount(ptr: *anyopaque, category: DiagnosticCategory) usize {
    return nativeRuntime(ptr).diagnosticCategoryCount(category);
}

fn nativeHasShutdownComplete(ptr: *anyopaque) bool {
    return nativeRuntime(ptr).hasShutdownComplete();
}

fn nativeRegistryFramesApplied(ptr: *anyopaque) usize {
    return nativeRuntime(ptr).registryFramesApplied();
}

fn nativeHasRegisteredCommand(ptr: *anyopaque, name: []const u8) bool {
    return nativeRuntime(ptr).hasRegisteredCommand(name);
}

fn nativeHasRegisteredHook(ptr: *anyopaque, event_name: []const u8) bool {
    return nativeRuntime(ptr).hasRegisteredHook(event_name);
}

fn nativeSnapshotRegistryJson(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return try nativeRuntime(ptr).snapshotRegistryJson(allocator);
}

fn nativeWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: RegistryCallback) !void {
    try nativeRuntime(ptr).withRegistry(context, callback);
}

fn nativeApplyCliFlagValues(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    try nativeRuntime(ptr).applyCliFlagValues(entries);
}

fn nativeAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    return try nativeRuntime(ptr).agentTool(allocator, name);
}

fn nativeTakeUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
    return try nativeRuntime(ptr).takeUiRequests(allocator);
}

fn nativeSendExtensionUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    try nativeRuntime(ptr).sendExtensionUiResponse(id, payload_json);
}

fn nativeSendExtensionEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    nativeRuntime(ptr).sendExtensionEventFrame(frame_json);
}

fn nativeInvokeExtensionEvent(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    return try nativeRuntime(ptr).invokeExtensionEvent(allocator, event_name, event, timeout_ms);
}

fn nativeShutdown(ptr: *anyopaque) !void {
    try nativeRuntime(ptr).shutdown();
}

fn nativeDeinit(ptr: *anyopaque) void {
    nativeRuntime(ptr).deinit();
}

pub const native_vtable: RuntimeAdapter.VTable = .{
    .wait_for_ready = nativeWaitForReady,
    .pending_count = nativePendingCount,
    .diagnostic_count = nativeDiagnosticCount,
    .diagnostic_category_count = nativeDiagnosticCategoryCount,
    .has_shutdown_complete = nativeHasShutdownComplete,
    .registry_frames_applied = nativeRegistryFramesApplied,
    .has_registered_command = nativeHasRegisteredCommand,
    .has_registered_hook = nativeHasRegisteredHook,
    .snapshot_registry_json = nativeSnapshotRegistryJson,
    .with_registry = nativeWithRegistry,
    .apply_cli_flag_values = nativeApplyCliFlagValues,
    .agent_tool = nativeAgentTool,
    .take_ui_requests = nativeTakeUiRequests,
    .send_extension_ui_response = nativeSendExtensionUiResponse,
    .send_extension_event_frame = nativeSendExtensionEventFrame,
    .invoke_extension_event = nativeInvokeExtensionEvent,
    .shutdown = nativeShutdown,
    .deinit = nativeDeinit,
};
