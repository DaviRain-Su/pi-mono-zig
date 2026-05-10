const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const tools_common = @import("../tools/common.zig");
const workflow_execution = @import("workflow_execution.zig");

pub const Registry = runtime_adapter.Registry;
const RuntimeAdapter = runtime_adapter.RuntimeAdapter;

fn deinitAgentTool(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    tools_common.deinitJsonValue(allocator, tool.parameters);
    if (tool.deinit_execute_context) |deinit_context| deinit_context(allocator, tool.execute_context);
    tool.* = undefined;
}

fn processHost(ptr: *anyopaque) *extension_host.HostProcess {
    return @ptrCast(@alignCast(ptr));
}

pub const ProcessAgentToolContext = struct {
    host: *extension_host.HostProcess,
    tool_name: []u8,
    extension_path: []u8,
    workflow_id: ?[]u8 = null,
    dispatch_adapters: []RuntimeAdapter = &.{},

    fn deinit(self: *ProcessAgentToolContext, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.extension_path);
        if (self.workflow_id) |workflow_id| allocator.free(workflow_id);
        if (self.dispatch_adapters.len > 0) allocator.free(self.dispatch_adapters);
        allocator.destroy(self);
    }
};

const AgentToolExecuteFn = *const fn (
    std.mem.Allocator,
    []const u8,
    std.json.Value,
    ?*anyopaque,
    ?*const std.atomic.Value(bool),
    ?*anyopaque,
    ?agent.types.AgentToolUpdateCallback,
) anyerror!agent.AgentToolResult;

pub fn attachWorkflowDispatchAdapters(
    allocator: std.mem.Allocator,
    tools: []agent.AgentTool,
    adapters: []const RuntimeAdapter,
    process_agent_tool_execute: AgentToolExecuteFn,
) !void {
    for (tools) |tool| {
        if (tool.source != .extension) continue;
        if (tool.execute == null or tool.execute.? != process_agent_tool_execute) continue;
        const context: *ProcessAgentToolContext = @ptrCast(@alignCast(tool.execute_context orelse continue));
        if (context.workflow_id == null) continue;
        if (context.dispatch_adapters.len > 0) allocator.free(context.dispatch_adapters);
        context.dispatch_adapters = try allocator.dupe(RuntimeAdapter, adapters);
    }
}

pub fn deinitProcessAgentToolContext(allocator: std.mem.Allocator, tool_context: ?*anyopaque) void {
    const context: *ProcessAgentToolContext = @ptrCast(@alignCast(tool_context orelse return));
    context.deinit(allocator);
}

pub const WorkflowSurfaceKind = enum {
    command,
    tool,
    preset,
};

pub const WorkflowSurfaceExecutionOptions = struct {
    cancel_signal: ?*const std.atomic.Value(bool) = null,
    capability_dispatch: ?workflow_execution.CapabilityDispatchFn = null,
    capability_dispatch_context: ?*anyopaque = null,
};

pub const WorkflowCapabilityDispatchContext = struct {
    adapters: []const RuntimeAdapter,
    timeout_ms: u64 = 30_000,
};

pub const SingleRuntimeWorkflowCapabilityDispatchContext = struct {
    adapter: RuntimeAdapter,
    timeout_ms: u64 = 30_000,
};

pub fn dispatchWorkflowCapabilityFromAdapters(
    allocator: std.mem.Allocator,
    capability_id: []const u8,
    input: std.json.Value,
    context: ?*anyopaque,
) !std.json.Value {
    const dispatch_context: *WorkflowCapabilityDispatchContext = @ptrCast(@alignCast(context orelse return error.InvalidWorkflowCapabilityDispatchContext));
    for (dispatch_context.adapters) |adapter| {
        const maybe_output = dispatchWorkflowCapabilityFromAdapterValue(allocator, adapter, capability_id, input, dispatch_context.timeout_ms) catch |err| switch (err) {
            error.WorkflowCapabilityNotRegistered => continue,
            else => return err,
        };
        if (maybe_output) |output| {
            return output;
        }
    }
    return error.WorkflowCapabilityNotRegistered;
}

pub fn dispatchWorkflowCapabilityFromAdapter(
    allocator: std.mem.Allocator,
    capability_id: []const u8,
    input: std.json.Value,
    context: ?*anyopaque,
) !std.json.Value {
    const dispatch_context: *SingleRuntimeWorkflowCapabilityDispatchContext = @ptrCast(@alignCast(context orelse return error.InvalidWorkflowCapabilityDispatchContext));
    return try dispatchWorkflowCapabilityFromAdapterValue(
        allocator,
        dispatch_context.adapter,
        capability_id,
        input,
        dispatch_context.timeout_ms,
    ) orelse error.WorkflowCapabilityNotRegistered;
}

fn dispatchWorkflowCapabilityFromAdapterValue(
    allocator: std.mem.Allocator,
    adapter: RuntimeAdapter,
    capability_id: []const u8,
    input: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    if (adapter.kind == .process_jsonl) {
        const host = processHost(adapter.ptr);
        validateProcessToolArguments(host, capability_id, input) catch |err| switch (err) {
            error.ToolNotRegistered => return null,
            else => return err,
        };
        const tool_call_id = try std.fmt.allocPrint(allocator, "workflow-{s}", .{capability_id});
        defer allocator.free(tool_call_id);
        const response = try host.executeTool(allocator, capability_id, tool_call_id, input, timeout_ms);
        defer {
            var owned_response = response;
            owned_response.deinit(allocator);
        }
        return try workflowCapabilityJsonFromResponse(allocator, response.content, response.details, response.is_error);
    }

    var tool = (try adapter.agentTool(allocator, capability_id)) orelse return null;
    defer deinitAgentTool(allocator, &tool);
    const result = try tool.execute.?(allocator, capability_id, input, tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, result.content);
    defer if (result.details) |details| tools_common.deinitJsonValue(allocator, details);
    return try workflowCapabilityJsonFromResponse(allocator, result.content, result.details, result.is_error);
}

fn workflowCapabilityJsonFromResponse(
    allocator: std.mem.Allocator,
    content: []const ai.ContentBlock,
    details: ?std.json.Value,
    is_error: ?bool,
) !std.json.Value {
    if (is_error orelse false) return error.WorkflowCapabilityExecutionFailed;
    if (content.len > 0 and content[0] == .text) {
        if (std.json.parseFromSlice(std.json.Value, allocator, content[0].text.text, .{})) |parsed| {
            defer parsed.deinit();
            return try tools_common.cloneJsonValue(allocator, parsed.value);
        } else |_| {
            if (details) |value| return try tools_common.cloneJsonValue(allocator, value);
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer tools_common.deinitJsonValue(allocator, .{ .object = object });
            try tools_common.putString(allocator, &object, "text", content[0].text.text);
            return .{ .object = object };
        }
    }
    if (details) |value| return try tools_common.cloneJsonValue(allocator, value);
    return try tools_common.cloneJsonValue(allocator, .null);
}

pub fn executeRegisteredWorkflowSurface(
    allocator: std.mem.Allocator,
    registry: *const Registry,
    kind: WorkflowSurfaceKind,
    name: []const u8,
    input: std.json.Value,
    options: WorkflowSurfaceExecutionOptions,
) !?workflow_execution.ExecutionResult {
    const workflow = switch (kind) {
        .command => registry.workflowForCommandName(name),
        .tool => registry.workflowForToolName(name),
        .preset => registry.workflowForPresetId(name),
    } orelse return null;

    const descriptor_id = try allocator.dupe(u8, workflow.id);
    defer allocator.free(descriptor_id);
    const descriptor_extension_path = try allocator.dupe(u8, workflow.extension_path);
    defer allocator.free(descriptor_extension_path);
    const descriptor_input_schema = try tools_common.cloneJsonValue(allocator, workflow.input_schema);
    defer tools_common.deinitJsonValue(allocator, descriptor_input_schema);
    const descriptor_output_schema = try tools_common.cloneJsonValue(allocator, workflow.output_schema);
    defer tools_common.deinitJsonValue(allocator, descriptor_output_schema);
    const descriptor_permissions = try tools_common.cloneJsonValue(allocator, workflow.permissions);
    defer tools_common.deinitJsonValue(allocator, descriptor_permissions);
    var descriptor_child_agent_limits = workflow_execution.ChildAgentLimits.fromJson(workflow.child_agent_limits);
    descriptor_child_agent_limits.workflow_permissions_json = descriptor_permissions;
    const descriptor = workflow_execution.WorkflowDescriptor{
        .id = descriptor_id,
        .extension_path = descriptor_extension_path,
        .input_schema = descriptor_input_schema,
        .output_schema = descriptor_output_schema,
        .permissions = descriptor_permissions,
        .timeout_ms = workflow.timeout_ms,
        .child_agent_limits = descriptor_child_agent_limits,
    };
    var steps = try workflowStepsFromJson(allocator, workflow.steps);
    defer steps.deinit(allocator);
    var replay_metadata = try workflowReplayMetadataFromInput(allocator, input);
    defer replay_metadata.deinit(allocator);
    return try workflow_execution.executeWorkflow(
        allocator,
        descriptor,
        input,
        steps.items,
        .{
            .cancel_signal = options.cancel_signal,
            .replay = replay_metadata.replay,
            .recorded_steps = replay_metadata.recorded_steps,
            .recorded_terminal_state = replay_metadata.terminal_state,
            .recorded_permissions = replay_metadata.permissions,
            .recorded_child_agent_limits = replay_metadata.child_agent_limits,
            .capability_dispatch = options.capability_dispatch,
            .capability_dispatch_context = options.capability_dispatch_context,
        },
    );
}

pub fn processWorkflowToolExecute(
    allocator: std.mem.Allocator,
    context: *ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    signal: ?*const std.atomic.Value(bool),
    self_adapter: RuntimeAdapter,
) !agent.AgentToolResult {
    var dispatch_context = WorkflowCapabilityDispatchContext{
        .adapters = if (context.dispatch_adapters.len > 0) context.dispatch_adapters else @as([]const RuntimeAdapter, &.{self_adapter}),
    };
    var fallback_dispatch_context = SingleRuntimeWorkflowCapabilityDispatchContext{
        .adapter = self_adapter,
    };

    var result = (try executeRegisteredWorkflowSurface(
        allocator,
        &context.host.state.registry,
        .tool,
        context.tool_name,
        params,
        .{
            .cancel_signal = signal,
            .capability_dispatch = if (context.dispatch_adapters.len > 0) dispatchWorkflowCapabilityFromAdapters else dispatchWorkflowCapabilityFromAdapter,
            .capability_dispatch_context = if (context.dispatch_adapters.len > 0) @as(?*anyopaque, &dispatch_context) else @as(?*anyopaque, &fallback_dispatch_context),
        },
    )) orelse return try processToolErrorResultWithContext(
        allocator,
        context,
        tool_call_id,
        params,
        "workflow.not_registered",
        "workflow tool is no longer registered",
    );
    defer result.deinit(allocator);

    return try workflowToolResult(allocator, context, tool_call_id, params, result);
}

const WorkflowSteps = struct {
    items: []workflow_execution.StepSpec,
    runtime_work: []workflow_execution.ActiveRuntimeWork,

    fn deinit(self: *WorkflowSteps, allocator: std.mem.Allocator) void {
        for (self.items) |*item| {
            allocator.free(@constCast(item.id));
            tools_common.deinitJsonValue(allocator, item.input);
            tools_common.deinitJsonValue(allocator, item.output);
            if (item.selected_capability) |selected_capability| allocator.free(@constCast(selected_capability));
            if (item.child_delta.permission) |permission| allocator.free(@constCast(permission));
        }
        allocator.free(self.items);
        allocator.free(self.runtime_work);
        self.* = undefined;
    }
};

fn workflowStepsFromJson(allocator: std.mem.Allocator, value: std.json.Value) !WorkflowSteps {
    if (value != .array or value.array.items.len == 0) {
        return .{
            .items = try allocator.alloc(workflow_execution.StepSpec, 0),
            .runtime_work = try allocator.alloc(workflow_execution.ActiveRuntimeWork, 0),
        };
    }

    var runtime_work_count: usize = 0;
    for (value.array.items) |item| {
        if (item == .object and (jsonBool(item.object, "runtimeWork") orelse false)) runtime_work_count += 1;
    }

    var items = try allocator.alloc(workflow_execution.StepSpec, value.array.items.len);
    errdefer allocator.free(items);
    var runtime_work = try allocator.alloc(workflow_execution.ActiveRuntimeWork, runtime_work_count);
    errdefer allocator.free(runtime_work);
    for (runtime_work) |*work| work.* = .{};

    var runtime_index: usize = 0;
    for (value.array.items, 0..) |item, index| {
        if (item != .object) {
            items[index] = .{
                .id = try allocator.dupe(u8, ""),
                .input = try tools_common.cloneJsonValue(allocator, .null),
                .output = try tools_common.cloneJsonValue(allocator, .null),
            };
            continue;
        }
        const object = item.object;
        var child_delta = parseWorkflowChildDelta(object.get("childDelta") orelse object.get("child_delta") orelse .null);
        if (child_delta.permission) |permission| child_delta.permission = try allocator.dupe(u8, permission);
        items[index] = .{
            .id = try allocator.dupe(u8, jsonString(object, "id") orelse "step"),
            .kind = parseWorkflowStepKind(jsonString(object, "kind")),
            .input = try tools_common.cloneJsonValue(allocator, object.get("input") orelse .null),
            .output = try tools_common.cloneJsonValue(allocator, object.get("output") orelse .null),
            .elapsed_ms = jsonU64(object, "elapsedMs") orelse jsonU64(object, "elapsed_ms") orelse 0,
            .replay_mode = parseWorkflowReplayMode(jsonString(object, "replayMode") orelse jsonString(object, "replay_mode")),
            .selected_capability = if (jsonString(object, "selectedCapability") orelse jsonString(object, "selected_capability")) |selected_capability| try allocator.dupe(u8, selected_capability) else null,
            .child_delta = child_delta,
            .runtime_work = if (jsonBool(object, "runtimeWork") orelse false) blk: {
                const work = &runtime_work[runtime_index];
                runtime_index += 1;
                break :blk work;
            } else null,
            .cancel_after_start = jsonBool(object, "cancelAfterStart") orelse jsonBool(object, "cancel_after_start") orelse false,
        };
    }

    return .{ .items = items, .runtime_work = runtime_work };
}

fn parseWorkflowStepKind(value: ?[]const u8) workflow_execution.StepKind {
    const name = value orelse return .deterministic;
    if (std.mem.eql(u8, name, "side_effect") or std.mem.eql(u8, name, "sideEffect")) return .side_effect;
    if (std.mem.eql(u8, name, "child_agent") or std.mem.eql(u8, name, "childAgent")) return .child_agent;
    return .deterministic;
}

fn parseWorkflowReplayMode(value: ?[]const u8) workflow_execution.StepReplayMode {
    const name = value orelse return .deterministic;
    if (std.mem.eql(u8, name, "recorded")) return .recorded;
    if (std.mem.eql(u8, name, "stubbed")) return .stubbed;
    if (std.mem.eql(u8, name, "blocked")) return .blocked;
    return .deterministic;
}

fn parseWorkflowChildDelta(value: std.json.Value) workflow_execution.ChildAgentDelta {
    if (value != .object) return .{};
    return .{
        .children_started = jsonU64(value.object, "childrenStarted") orelse jsonU64(value.object, "children_started") orelse 0,
        .turns = jsonU64(value.object, "turns") orelse 0,
        .tool_calls = jsonU64(value.object, "toolCalls") orelse jsonU64(value.object, "tool_calls") orelse 0,
        .tokens = jsonU64(value.object, "tokens") orelse 0,
        .elapsed_ms = jsonU64(value.object, "elapsedMs") orelse jsonU64(value.object, "elapsed_ms") orelse 0,
        .permission = jsonString(value.object, "permission"),
    };
}

fn workflowReplayRequested(input: std.json.Value) bool {
    if (input != .object) return false;
    return jsonBool(input.object, "__workflowReplay") orelse jsonBool(input.object, "workflowReplay") orelse false;
}

const WorkflowReplayMetadataInput = struct {
    replay: bool = false,
    recorded_steps: []workflow_execution.RecordedReplayStep = &.{},
    terminal_state: ?workflow_execution.ExecutionState = null,
    permissions: ?std.json.Value = null,
    child_agent_limits: ?workflow_execution.ChildAgentLimits = null,

    fn deinit(self: *WorkflowReplayMetadataInput, allocator: std.mem.Allocator) void {
        allocator.free(self.recorded_steps);
        self.* = undefined;
    }
};

fn workflowReplayMetadataFromInput(allocator: std.mem.Allocator, input: std.json.Value) !WorkflowReplayMetadataInput {
    var metadata = WorkflowReplayMetadataInput{
        .replay = workflowReplayRequested(input),
        .recorded_steps = try allocator.alloc(workflow_execution.RecordedReplayStep, 0),
    };
    errdefer metadata.deinit(allocator);

    const metadata_value = workflowReplayMetadataValue(input) orelse return metadata;
    metadata.replay = true;
    if (metadata_value != .object) return metadata;
    const object = metadata_value.object;
    metadata.terminal_state = parseWorkflowExecutionState(jsonString(object, "terminalState") orelse jsonString(object, "terminal_state"));
    metadata.permissions = object.get("permissions");
    if (object.get("childAgentLimits")) |limits| {
        metadata.child_agent_limits = workflow_execution.ChildAgentLimits.fromJson(limits);
    } else if (object.get("child_agent_limits")) |limits| {
        metadata.child_agent_limits = workflow_execution.ChildAgentLimits.fromJson(limits);
    }
    const steps_value = object.get("steps") orelse return metadata;
    if (steps_value != .array) return metadata;
    allocator.free(metadata.recorded_steps);
    metadata.recorded_steps = try allocator.alloc(workflow_execution.RecordedReplayStep, steps_value.array.items.len);
    for (metadata.recorded_steps, 0..) |*recorded, index| {
        recorded.* = .{
            .step_id = "",
            .mode = .deterministic,
        };
        const step_value = steps_value.array.items[index];
        if (step_value != .object) continue;
        const step_object = step_value.object;
        const selected_capability_value = step_object.get("selectedCapability") orelse step_object.get("selected_capability");
        recorded.* = .{
            .step_id = jsonString(step_object, "stepId") orelse jsonString(step_object, "step_id") orelse "",
            .mode = parseWorkflowReplayMode(jsonString(step_object, "mode") orelse jsonString(step_object, "replayMode") orelse jsonString(step_object, "replay_mode")),
            .output = step_object.get("output"),
            .order = jsonUsize(step_object, "order"),
            .kind = parseOptionalWorkflowStepKind(jsonString(step_object, "kind")),
            .input = step_object.get("input"),
            .selected_capability_present = selected_capability_value != null,
            .selected_capability = optionalJsonString(selected_capability_value),
            .child_agent_limits = parseOptionalChildAgentLimits(step_object.get("childAgentLimits") orelse step_object.get("child_agent_limits")),
            .permissions = step_object.get("permissions"),
        };
    }
    return metadata;
}

fn workflowReplayMetadataValue(input: std.json.Value) ?std.json.Value {
    if (input != .object) return null;
    return input.object.get("__workflowReplayMetadata") orelse
        input.object.get("workflowReplayMetadata") orelse
        input.object.get("replayMetadata") orelse
        input.object.get("replay_metadata");
}

fn parseWorkflowExecutionState(value: ?[]const u8) ?workflow_execution.ExecutionState {
    const name = value orelse return null;
    if (std.mem.eql(u8, name, "completed")) return .completed;
    if (std.mem.eql(u8, name, "failed")) return .failed;
    if (std.mem.eql(u8, name, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, name, "timed_out")) return .timed_out;
    if (std.mem.eql(u8, name, "replay_blocked")) return .replay_blocked;
    return null;
}

fn parseOptionalWorkflowStepKind(value: ?[]const u8) ?workflow_execution.StepKind {
    const name = value orelse return null;
    return parseWorkflowStepKind(name);
}

fn parseOptionalChildAgentLimits(value: ?std.json.Value) ?workflow_execution.ChildAgentLimits {
    const json_value = value orelse return null;
    return workflow_execution.ChildAgentLimits.fromJson(json_value);
}

fn workflowToolResult(
    allocator: std.mem.Allocator,
    context: *const ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    result: workflow_execution.ExecutionResult,
) !agent.AgentToolResult {
    const content_text = if (result.output) |output|
        try std.json.Stringify.valueAlloc(allocator, output, .{})
    else
        try allocator.dupe(u8, result.state.jsonName());
    defer allocator.free(content_text);

    return .{
        .content = try tools_common.makeTextContent(allocator, content_text),
        .details = try workflowToolDetails(allocator, context, tool_call_id, params, result),
        .is_error = result.state != .completed,
    };
}

fn workflowToolDetails(
    allocator: std.mem.Allocator,
    context: *const ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    result: workflow_execution.ExecutionResult,
) !std.json.Value {
    var details = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, details);

    try tools_common.putString(allocator, &details.object, "code", "workflow.execution");
    try tools_common.putString(allocator, &details.object, "state", result.state.jsonName());
    try tools_common.putValue(allocator, &details.object, "extension", try processToolExtensionDetails(allocator, context));
    try tools_common.putString(allocator, &details.object, "toolName", context.tool_name);
    try tools_common.putString(allocator, &details.object, "toolCallId", tool_call_id);
    try tools_common.putValue(allocator, &details.object, "input", try tools_common.cloneJsonValue(allocator, params));
    try tools_common.putValue(allocator, &details.object, "workflow", try workflowMetadataJson(allocator, result));
    try tools_common.putValue(allocator, &details.object, "diagnostics", try workflowDiagnosticsJson(allocator, result.diagnostics.items));
    return details;
}

pub fn workflowExecutionResultDataJson(allocator: std.mem.Allocator, result: workflow_execution.ExecutionResult) ![]u8 {
    var data = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, data);

    try tools_common.putString(allocator, &data.object, "kind", "workflow");
    try tools_common.putString(allocator, &data.object, "state", result.state.jsonName());
    if (result.output) |output| {
        try tools_common.putValue(allocator, &data.object, "output", try tools_common.cloneJsonValue(allocator, output));
    } else {
        try tools_common.putNull(allocator, &data.object, "output");
    }
    try tools_common.putValue(allocator, &data.object, "workflow", try workflowMetadataJson(allocator, result));
    try tools_common.putValue(allocator, &data.object, "diagnostics", try workflowDiagnosticsJson(allocator, result.diagnostics.items));

    const json = try std.json.Stringify.valueAlloc(allocator, data, .{});
    tools_common.deinitJsonValue(allocator, data);
    return json;
}

fn workflowMetadataJson(allocator: std.mem.Allocator, result: workflow_execution.ExecutionResult) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = object });
    try tools_common.putString(allocator, &object, "id", result.replay_metadata.workflow_id);
    try tools_common.putString(allocator, &object, "terminalState", result.replay_metadata.terminal_state.jsonName());
    try tools_common.putValue(allocator, &object, "cancellationPoint", optionalStringValue(allocator, result.replay_metadata.cancellation_point));
    try tools_common.putValue(allocator, &object, "permissions", try tools_common.cloneJsonValue(allocator, result.replay_metadata.permissions));
    try tools_common.putValue(allocator, &object, "childAgentLimits", try workflowChildAgentLimitsJson(allocator, result.replay_metadata.child_agent_limits));

    var steps = std.json.Array.init(allocator);
    for (result.replay_metadata.steps.items) |step| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try tools_common.putString(allocator, &entry, "stepId", step.step_id);
        try tools_common.putInt(allocator, &entry, "order", @intCast(step.order));
        try tools_common.putString(allocator, &entry, "kind", step.kind);
        try tools_common.putString(allocator, &entry, "mode", step.mode);
        try tools_common.putString(allocator, &entry, "state", step.state);
        try tools_common.putValue(allocator, &entry, "input", try tools_common.cloneJsonValue(allocator, step.input));
        try tools_common.putBool(allocator, &entry, "sideEffect", step.side_effect);
        try tools_common.putValue(allocator, &entry, "selectedCapability", optionalStringValue(allocator, step.selected_capability));
        try steps.append(.{ .object = entry });
    }
    try tools_common.putValue(allocator, &object, "steps", .{ .array = steps });

    var usage = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try tools_common.putInt(allocator, &usage, "childrenStarted", @intCast(result.child_usage.children_started));
    try tools_common.putInt(allocator, &usage, "turns", @intCast(result.child_usage.turns));
    try tools_common.putInt(allocator, &usage, "toolCalls", @intCast(result.child_usage.tool_calls));
    try tools_common.putInt(allocator, &usage, "tokens", @intCast(result.child_usage.tokens));
    try tools_common.putInt(allocator, &usage, "elapsedMs", @intCast(result.child_usage.elapsed_ms));
    try tools_common.putValue(allocator, &object, "childUsage", .{ .object = usage });
    return .{ .object = object };
}

fn workflowChildAgentLimitsJson(allocator: std.mem.Allocator, limits: workflow_execution.ChildAgentLimits) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = object });
    try tools_common.putValue(allocator, &object, "maxChildren", optionalIntegerValue(limits.max_children));
    try tools_common.putValue(allocator, &object, "maxTurns", optionalIntegerValue(limits.max_turns));
    try tools_common.putValue(allocator, &object, "maxToolCalls", optionalIntegerValue(limits.max_tool_calls));
    try tools_common.putValue(allocator, &object, "maxTokens", optionalIntegerValue(limits.max_tokens));
    try tools_common.putValue(allocator, &object, "timeoutMs", optionalIntegerValue(limits.timeout_ms));
    if (limits.permission_grants_json) |permissions| {
        try tools_common.putValue(allocator, &object, "permissionGrants", try tools_common.cloneJsonValue(allocator, permissions));
    } else if (limits.workflow_permissions_json) |permissions| {
        try tools_common.putValue(allocator, &object, "permissionGrants", try tools_common.cloneJsonValue(allocator, permissions));
    } else {
        var grants = std.json.Array.init(allocator);
        for (limits.permission_grants) |grant| {
            try grants.append(.{ .string = try allocator.dupe(u8, grant) });
        }
        try tools_common.putValue(allocator, &object, "permissionGrants", .{ .array = grants });
    }
    return .{ .object = object };
}

fn optionalIntegerValue(value: ?u64) std.json.Value {
    if (value) |number| return .{ .integer = @intCast(number) };
    return .null;
}

fn workflowDiagnosticsJson(allocator: std.mem.Allocator, diagnostics: []const workflow_execution.Diagnostic) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (diagnostics) |diagnostic| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try tools_common.putString(allocator, &entry, "code", diagnostic.code);
        try tools_common.putString(allocator, &entry, "workflowId", diagnostic.workflow_id);
        try tools_common.putValue(allocator, &entry, "stepId", optionalStringValue(allocator, diagnostic.step_id));
        try tools_common.putString(allocator, &entry, "path", diagnostic.path);
        try tools_common.putString(allocator, &entry, "message", diagnostic.message);
        try array.append(.{ .object = entry });
    }
    return .{ .array = array };
}

fn optionalStringValue(allocator: std.mem.Allocator, value: ?[]const u8) std.json.Value {
    if (value) |text| return .{ .string = allocator.dupe(u8, text) catch return .null };
    return .null;
}

fn jsonString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return optionalJsonString(value);
}

fn optionalJsonString(value: ?std.json.Value) ?[]const u8 {
    const json_value = value orelse return null;
    return switch (json_value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonU64(object: std.json.ObjectMap, field: []const u8) ?u64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn jsonUsize(object: std.json.ObjectMap, field: []const u8) ?usize {
    const number = jsonU64(object, field) orelse return null;
    return @intCast(number);
}

pub fn processToolResultDetails(
    allocator: std.mem.Allocator,
    context: *const ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    response_details: ?std.json.Value,
) !std.json.Value {
    var details: std.json.Value = if (response_details) |value|
        try tools_common.cloneJsonValue(allocator, value)
    else
        .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, details);

    if (details != .object) {
        const original = details;
        var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer {
            const failed = std.json.Value{ .object = object };
            tools_common.deinitJsonValue(allocator, failed);
        }
        try object.put(
            allocator,
            try allocator.dupe(u8, "resultDetails"),
            original,
        );
        details = .{ .object = object };
    }

    try details.object.put(
        allocator,
        try allocator.dupe(u8, "extension"),
        try processToolExtensionDetails(allocator, context),
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "toolName"),
        .{ .string = try allocator.dupe(u8, context.tool_name) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "toolCallId"),
        .{ .string = try allocator.dupe(u8, tool_call_id) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "input"),
        try tools_common.cloneJsonValue(allocator, params),
    );

    return details;
}

fn processToolExtensionDetails(
    allocator: std.mem.Allocator,
    context: *const ProcessAgentToolContext,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const value = std.json.Value{ .object = object };
        tools_common.deinitJsonValue(allocator, value);
    }
    try object.put(
        allocator,
        try allocator.dupe(u8, "runtime"),
        .{ .string = try allocator.dupe(u8, "process_jsonl") },
    );
    try object.put(
        allocator,
        try allocator.dupe(u8, "toolName"),
        .{ .string = try allocator.dupe(u8, context.tool_name) },
    );
    try object.put(
        allocator,
        try allocator.dupe(u8, "extensionPath"),
        .{ .string = try allocator.dupe(u8, context.extension_path) },
    );
    return .{ .object = object };
}

pub fn validateProcessToolArguments(host: *extension_host.HostProcess, tool_name: []const u8, params: std.json.Value) anyerror!void {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    for (host.state.registry.tools.items) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name)) {
            try validateRuntimeJsonSchemaValue(tool.parameters, params);
            return;
        }
    }
    return error.ToolNotRegistered;
}

fn validateRuntimeJsonSchemaValue(schema: std.json.Value, value: std.json.Value) anyerror!void {
    if (schema != .object) return;
    if (schema.object.get("type")) |type_value| {
        if (type_value == .string) try validateRuntimeJsonSchemaType(type_value.string, schema, value);
    }
}

fn validateRuntimeJsonSchemaType(type_name: []const u8, schema: std.json.Value, value: std.json.Value) anyerror!void {
    if (std.mem.eql(u8, type_name, "object")) {
        if (value != .object) return error.InvalidToolArguments;
        if (schema.object.get("required")) |required| {
            if (required == .array) {
                for (required.array.items) |item| {
                    if (item == .string and !value.object.contains(item.string)) return error.InvalidToolArguments;
                }
            }
        }
        const properties = if (schema.object.get("properties")) |properties_value| switch (properties_value) {
            .object => |properties_object| properties_object,
            else => null,
        } else null;
        if (properties) |properties_object| {
            var property_iterator = properties_object.iterator();
            while (property_iterator.next()) |entry| {
                if (value.object.get(entry.key_ptr.*)) |property_value| try validateRuntimeJsonSchemaValue(entry.value_ptr.*, property_value);
            }
            if (schema.object.get("additionalProperties")) |additional_properties| {
                if (additional_properties == .bool and !additional_properties.bool) {
                    var value_iterator = value.object.iterator();
                    while (value_iterator.next()) |entry| {
                        if (!properties_object.contains(entry.key_ptr.*)) return error.InvalidToolArguments;
                    }
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, type_name, "string")) {
        if (value != .string) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "boolean")) {
        if (value != .bool) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "integer")) {
        if (value != .integer) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "number")) {
        if (value != .integer and value != .float and value != .number_string) return error.InvalidToolArguments;
        return;
    }
    if (std.mem.eql(u8, type_name, "array")) {
        if (value != .array) return error.InvalidToolArguments;
        if (schema.object.get("items")) |items_schema| {
            for (value.array.items) |item| try validateRuntimeJsonSchemaValue(items_schema, item);
        }
    }
}

pub fn processToolErrorResultWithContext(
    allocator: std.mem.Allocator,
    context: *const ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    code: []const u8,
    message: []const u8,
) !agent.AgentToolResult {
    var details = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, details);

    try details.object.put(
        allocator,
        try allocator.dupe(u8, "code"),
        .{ .string = try allocator.dupe(u8, code) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "message"),
        .{ .string = try allocator.dupe(u8, message) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "extension"),
        try processToolExtensionDetails(allocator, context),
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "toolCallId"),
        .{ .string = try allocator.dupe(u8, tool_call_id) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "input"),
        try tools_common.cloneJsonValue(allocator, params),
    );

    return .{
        .content = try tools_common.makeTextContent(allocator, message),
        .details = details,
        .is_error = true,
    };
}

pub fn processToolValidationErrorResultWithContext(
    allocator: std.mem.Allocator,
    context: *const ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    failure: agent.types.ToolArgumentValidationFailure,
) !agent.AgentToolResult {
    var details = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, details);

    try details.object.put(
        allocator,
        try allocator.dupe(u8, "code"),
        .{ .string = try allocator.dupe(u8, "InvalidToolArguments") },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "message"),
        .{ .string = try allocator.dupe(u8, "InvalidToolArguments") },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "extension"),
        try processToolExtensionDetails(allocator, context),
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "toolName"),
        .{ .string = try allocator.dupe(u8, context.tool_name) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "toolCallId"),
        .{ .string = try allocator.dupe(u8, tool_call_id) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "input"),
        try tools_common.cloneJsonValue(allocator, params),
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "fieldPath"),
        .{ .string = try allocator.dupe(u8, failure.path) },
    );

    var validation = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, validation);
    try validation.object.put(
        allocator,
        try allocator.dupe(u8, "code"),
        .{ .string = try allocator.dupe(u8, failure.code) },
    );
    try validation.object.put(
        allocator,
        try allocator.dupe(u8, "message"),
        .{ .string = try allocator.dupe(u8, failure.message) },
    );
    try validation.object.put(
        allocator,
        try allocator.dupe(u8, "fieldPath"),
        .{ .string = try allocator.dupe(u8, failure.path) },
    );
    try details.object.put(
        allocator,
        try allocator.dupe(u8, "validation"),
        validation,
    );

    return .{
        .content = try tools_common.makeTextContent(allocator, "InvalidToolArguments"),
        .details = details,
        .is_error = true,
    };
}
