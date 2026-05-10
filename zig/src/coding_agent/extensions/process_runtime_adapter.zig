const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const tools_common = @import("../tools/common.zig");
const workflow_event_bridge = @import("workflow_event_bridge.zig");

const DiagnosticCategory = runtime_adapter.DiagnosticCategory;
const ExtensionUiRequest = runtime_adapter.ExtensionUiRequest;
pub const ProcessJsonlOptions = runtime_adapter.ProcessJsonlOptions;
pub const Registry = runtime_adapter.Registry;
const RegistryCallback = runtime_adapter.RegistryCallback;
const RuntimeAdapter = runtime_adapter.RuntimeAdapter;

fn deinitAgentTool(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    tools_common.deinitJsonValue(allocator, tool.parameters);
    if (tool.deinit_execute_context) |deinit_context| deinit_context(allocator, tool.execute_context);
    tool.* = undefined;
}

pub fn startProcessJsonl(allocator: std.mem.Allocator, io: std.Io, options: ProcessJsonlOptions) !RuntimeAdapter {
    const host = try extension_host.HostProcess.start(allocator, io, options);
    return .{
        .ptr = @ptrCast(host),
        .vtable = &process_jsonl_vtable,
        .kind = .process_jsonl,
    };
}

pub fn processHost(ptr: *anyopaque) *extension_host.HostProcess {
    return @ptrCast(@alignCast(ptr));
}

fn processWaitForReady(ptr: *anyopaque, timeout_ms: u64) !void {
    try processHost(ptr).waitForReady(timeout_ms);
}

fn processPendingCount(ptr: *anyopaque) usize {
    return processHost(ptr).pendingCount();
}

fn processDiagnosticCount(ptr: *anyopaque) usize {
    return processHost(ptr).diagnosticCount();
}

fn processDiagnosticCategoryCount(ptr: *anyopaque, category: DiagnosticCategory) usize {
    return processHost(ptr).diagnosticCategoryCount(category);
}

fn processHasShutdownComplete(ptr: *anyopaque) bool {
    return processHost(ptr).hasShutdownComplete();
}

fn processRegistryFramesApplied(ptr: *anyopaque) usize {
    return processHost(ptr).registryFramesApplied();
}

fn processHasRegisteredCommand(ptr: *anyopaque, name: []const u8) bool {
    return processHost(ptr).hasRegisteredCommand(name);
}

fn processHasRegisteredHook(ptr: *anyopaque, event_name: []const u8) bool {
    return processHost(ptr).hasRegisteredHook(event_name);
}

fn processSnapshotRegistryJson(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return try processHost(ptr).snapshotRegistryJson(allocator);
}

fn processWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: RegistryCallback) !void {
    try processHost(ptr).withRegistry(context, callback);
}

fn processApplyCliFlagValues(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    try processHost(ptr).applyCliFlagValues(entries);
}

const ProcessAgentToolContext = workflow_event_bridge.ProcessAgentToolContext;

pub fn attachWorkflowDispatchAdapters(
    allocator: std.mem.Allocator,
    tools: []agent.AgentTool,
    adapters: []const RuntimeAdapter,
) !void {
    try workflow_event_bridge.attachWorkflowDispatchAdapters(allocator, tools, adapters, processAgentToolExecute);
}

fn processAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    const host = processHost(ptr);
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    for (host.state.registry.tools.items) |tool| {
        if (!std.mem.eql(u8, tool.name, name)) continue;
        const context = try allocator.create(ProcessAgentToolContext);
        errdefer allocator.destroy(context);
        context.* = .{
            .host = host,
            .tool_name = try allocator.dupe(u8, tool.name),
            .extension_path = try allocator.dupe(u8, tool.extension_path),
            .workflow_id = if (host.state.registry.workflowForToolName(tool.name)) |workflow| try allocator.dupe(u8, workflow.id) else null,
        };
        errdefer allocator.free(context.tool_name);
        errdefer allocator.free(context.extension_path);
        errdefer if (context.workflow_id) |workflow_id| allocator.free(workflow_id);
        return .{
            .name = tool.name,
            .description = tool.description,
            .label = tool.label,
            .parameters = try tools_common.cloneJsonValue(allocator, tool.parameters),
            .source = .extension,
            .invalid_arguments_result = processAgentToolInvalidArguments,
            .execute = processAgentToolExecute,
            .execute_context = context,
            .deinit_execute_context = deinitProcessAgentToolContext,
            .execution_mode = parseExecutionMode(tool.execution_mode),
        };
    }
    return null;
}

fn processAgentToolInvalidArguments(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    failure: agent.types.ToolArgumentValidationFailure,
) !agent.AgentToolResult {
    const context: *ProcessAgentToolContext = @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
    return try workflow_event_bridge.processToolValidationErrorResultWithContext(
        allocator,
        context,
        tool_call_id,
        params,
        failure,
    );
}

const deinitProcessAgentToolContext = workflow_event_bridge.deinitProcessAgentToolContext;

fn parseExecutionMode(mode: ?[]const u8) ?agent.types.ToolExecutionMode {
    const value = mode orelse return null;
    if (std.mem.eql(u8, value, "sequential")) return .sequential;
    if (std.mem.eql(u8, value, "parallel")) return .parallel;
    return null;
}

fn processAgentToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    _ = on_update_context;
    _ = on_update;
    const context: *ProcessAgentToolContext = @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
    if (context.workflow_id != null) {
        const self_adapter = RuntimeAdapter{
            .ptr = @ptrCast(context.host),
            .vtable = &process_jsonl_vtable,
            .kind = .process_jsonl,
        };
        return try workflow_event_bridge.processWorkflowToolExecute(allocator, context, tool_call_id, params, signal, self_adapter);
    }
    workflow_event_bridge.validateProcessToolArguments(context.host, context.tool_name, params) catch |err| {
        return workflow_event_bridge.processToolErrorResultWithContext(allocator, context, tool_call_id, params, @errorName(err), @errorName(err));
    };
    const response = context.host.executeTool(
        allocator,
        context.tool_name,
        tool_call_id,
        params,
        30_000,
    ) catch |err| {
        return workflow_event_bridge.processToolErrorResultWithContext(allocator, context, tool_call_id, params, @errorName(err), @errorName(err));
    };
    defer {
        var owned_response = response;
        owned_response.deinit(allocator);
    }
    return .{
        .content = try cloneAgentContentBlocks(allocator, response.content),
        .details = try workflow_event_bridge.processToolResultDetails(
            allocator,
            context,
            tool_call_id,
            params,
            response.details,
        ),
        .is_error = response.is_error,
    };
}

pub const WorkflowSurfaceKind = workflow_event_bridge.WorkflowSurfaceKind;
pub const WorkflowSurfaceExecutionOptions = workflow_event_bridge.WorkflowSurfaceExecutionOptions;
pub const WorkflowCapabilityDispatchContext = workflow_event_bridge.WorkflowCapabilityDispatchContext;
pub const SingleRuntimeWorkflowCapabilityDispatchContext = workflow_event_bridge.SingleRuntimeWorkflowCapabilityDispatchContext;
pub const dispatchWorkflowCapabilityFromAdapters = workflow_event_bridge.dispatchWorkflowCapabilityFromAdapters;
pub const dispatchWorkflowCapabilityFromAdapter = workflow_event_bridge.dispatchWorkflowCapabilityFromAdapter;
pub const executeRegisteredWorkflowSurface = workflow_event_bridge.executeRegisteredWorkflowSurface;
pub const workflowExecutionResultDataJson = workflow_event_bridge.workflowExecutionResultDataJson;

fn cloneAgentContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]const ai.ContentBlock {
    const cloned = try allocator.alloc(ai.ContentBlock, blocks.len);
    errdefer allocator.free(cloned);
    for (blocks, 0..) |block, index| {
        cloned[index] = cloneAgentContentBlock(allocator, block) catch |err| {
            deinitAgentContentBlockFields(allocator, cloned[0..index]);
            allocator.free(cloned);
            return err;
        };
    }
    return cloned;
}

fn cloneAgentContentBlock(allocator: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
        .image => |image| .{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| .{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .thinking_signature = if (thinking.thinking_signature) |signature| try allocator.dupe(u8, signature) else null,
            .signature = if (thinking.signature) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
        .tool_call => |tool_call| .{ .tool_call = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try tools_common.cloneJsonValue(allocator, tool_call.arguments),
            .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
    };
}

fn deinitAgentContentBlockFields(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.thinking_signature) |signature| allocator.free(signature);
                if (thinking.signature) |signature| allocator.free(signature);
            },
            .tool_call => |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                if (tool_call.thought_signature) |signature| allocator.free(signature);
                tools_common.deinitJsonValue(allocator, tool_call.arguments);
            },
        }
    }
}

fn processTakeUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
    return try processHost(ptr).takeUiRequests(allocator);
}

fn processSendExtensionUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    try processHost(ptr).sendExtensionUiResponse(id, payload_json);
}

fn processSendExtensionEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    processHost(ptr).sendExtensionEventFrame(frame_json);
}

fn processInvokeExtensionEvent(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    return try processHost(ptr).invokeExtensionEvent(allocator, event_name, event, timeout_ms);
}

fn processShutdown(ptr: *anyopaque) !void {
    try processHost(ptr).shutdown();
}

fn processDeinit(ptr: *anyopaque) void {
    processHost(ptr).deinit();
}

const process_jsonl_vtable: RuntimeAdapter.VTable = .{
    .wait_for_ready = processWaitForReady,
    .pending_count = processPendingCount,
    .diagnostic_count = processDiagnosticCount,
    .diagnostic_category_count = processDiagnosticCategoryCount,
    .has_shutdown_complete = processHasShutdownComplete,
    .registry_frames_applied = processRegistryFramesApplied,
    .has_registered_command = processHasRegisteredCommand,
    .has_registered_hook = processHasRegisteredHook,
    .snapshot_registry_json = processSnapshotRegistryJson,
    .with_registry = processWithRegistry,
    .apply_cli_flag_values = processApplyCliFlagValues,
    .agent_tool = processAgentTool,
    .take_ui_requests = processTakeUiRequests,
    .send_extension_ui_response = processSendExtensionUiResponse,
    .send_extension_event_frame = processSendExtensionEventFrame,
    .invoke_extension_event = processInvokeExtensionEvent,
    .shutdown = processShutdown,
    .deinit = processDeinit,
};
