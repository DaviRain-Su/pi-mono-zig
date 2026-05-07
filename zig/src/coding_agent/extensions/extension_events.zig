const std = @import("std");

/// Extension event types mirroring TypeScript ExtensionAPI.on() events
pub const ExtensionEventType = enum {
    // Resource events
    resources_discover,
    // Session events
    session_start,
    session_before_switch,
    session_before_fork,
    session_before_compact,
    session_compact,
    session_shutdown,
    session_before_tree,
    session_tree,
    // Agent events
    before_agent_start,
    agent_start,
    agent_end,
    sub_agent_readiness,
    turn_start,
    turn_end,
    // Message events
    message_start,
    message_update,
    message_end,
    // Tool events
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    tool_call,
    tool_result,
    user_bash,
    // Context/Provider events
    context,
    before_provider_request,
    after_provider_response,
    // Model events
    model_select,
    thinking_level_select,
    // Input events
    input,
};

/// Generic extension event
pub const ExtensionEvent = union(ExtensionEventType) {
    resources_discover: ResourcesDiscoverEvent,
    session_start: SessionStartEvent,
    session_before_switch: SessionBeforeSwitchEvent,
    session_before_fork: SessionBeforeForkEvent,
    session_before_compact: SessionBeforeCompactEvent,
    session_compact: SessionCompactEvent,
    session_shutdown: SessionShutdownEvent,
    session_before_tree: SessionBeforeTreeEvent,
    session_tree: SessionTreeEvent,
    before_agent_start: BeforeAgentStartEvent,
    agent_start: AgentStartEvent,
    agent_end: AgentEndEvent,
    sub_agent_readiness: SubAgentReadinessEvent,
    turn_start: TurnStartEvent,
    turn_end: TurnEndEvent,
    message_start: MessageStartEvent,
    message_update: MessageUpdateEvent,
    message_end: MessageEndEvent,
    tool_execution_start: ToolExecutionStartEvent,
    tool_execution_update: ToolExecutionUpdateEvent,
    tool_execution_end: ToolExecutionEndEvent,
    tool_call: ToolCallEvent,
    tool_result: ToolResultEvent,
    user_bash: UserBashEvent,
    context: ContextEvent,
    before_provider_request: BeforeProviderRequestEvent,
    after_provider_response: AfterProviderResponseEvent,
    model_select: ModelSelectEvent,
    thinking_level_select: ThinkingLevelSelectEvent,
    input: InputEvent,
};

// Resource events
pub const ResourcesDiscoverEvent = struct {
    cwd: []const u8,
    reason: []const u8, // "startup" | "reload"
};

// Session events
pub const SessionStartEvent = struct {
    reason: []const u8, // "startup" | "reload" | "new" | "resume" | "fork"
    previous_session_file: ?[]const u8 = null,
};

pub const SessionBeforeSwitchEvent = struct {
    reason: []const u8, // "new" | "resume"
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeForkEvent = struct {
    entry_id: []const u8,
    position: []const u8, // "before" | "at"
};

pub const SessionBeforeCompactEvent = struct {
    custom_instructions: ?[]const u8 = null,
};

pub const SessionCompactEvent = struct {
    from_extension: bool = false,
};

pub const SessionShutdownEvent = struct {
    reason: []const u8, // "quit" | "reload" | "new" | "resume" | "fork"
    target_session_file: ?[]const u8 = null,
};

pub const SessionBeforeTreeEvent = struct {
    target_id: []const u8,
};

pub const SessionTreeEvent = struct {
    target_id: []const u8,
};

// Agent events
pub const BeforeAgentStartEvent = struct {
    prompt: []const u8 = "",
    images: []const []const u8 = &.{},
    system_prompt: []const u8 = "",
    messages: []const []const u8 = &.{},
};

pub const AgentStartEvent = struct {};
pub const AgentEndEvent = struct {
    stop_reason: ?[]const u8 = null,
};

pub const SubAgentReadinessEvent = struct {
    envelope: []const u8,
    phase: []const u8,
    owner: []const u8,
    read_only: bool = true,
};

pub const TurnStartEvent = struct {
    message: []const u8,
};

pub const TurnEndEvent = struct {
    message: []const u8,
};

// Message events
pub const MessageStartEvent = struct {
    message_id: []const u8,
};

pub const MessageUpdateEvent = struct {
    message_id: []const u8,
    delta: []const u8,
};

pub const MessageEndEvent = struct {
    message_id: []const u8,
    role: []const u8 = "",
    final_message: []const u8,
};

// Tool events
pub const ToolExecutionStartEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    input: []const u8,
};

pub const ToolExecutionUpdateEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    update: []const u8,
};

pub const ToolExecutionEndEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    result: []const u8,
};

pub const ToolCallEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    input: []const u8,
};

pub const ToolResultEvent = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    result: []const u8,
    content: []const []const u8 = &.{},
    details: ?[]const u8 = null,
    is_error: bool = false,
};

pub const UserBashEvent = struct {
    command: []const u8,
    exclude_from_context: bool = false,
    cwd: []const u8 = "",
};

// Context/Provider events
pub const ContextEvent = struct {
    messages: []const []const u8,
};

pub const BeforeProviderRequestEvent = struct {
    model: []const u8,
    messages: []const []const u8,
    payload: []const u8 = "",
};

pub const AfterProviderResponseEvent = struct {
    model: []const u8,
    response: []const u8,
};

// Model events
pub const ModelSelectEvent = struct {
    model: []const u8,
    previous_model: ?[]const u8 = null,
};

pub const ThinkingLevelSelectEvent = struct {
    level: []const u8,
    previous_level: ?[]const u8 = null,
};

// Input events
pub const InputEvent = struct {
    data: []const u8,
    images: []const []const u8 = &.{},
};

/// Event handler function type
pub const EventHandler = *const fn (event: ExtensionEvent) anyerror!void;

pub const ResourcesDiscoverResult = struct {
    skill_paths: []const []const u8 = &.{},
    prompt_paths: []const []const u8 = &.{},
    theme_paths: []const []const u8 = &.{},
};

pub const ResourcePathResult = struct {
    path: []u8,
    extension_path: []u8,

    fn deinit(self: *ResourcePathResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ResourcesDiscoverCombinedResult = struct {
    skill_paths: []ResourcePathResult,
    prompt_paths: []ResourcePathResult,
    theme_paths: []ResourcePathResult,

    pub fn deinit(self: *ResourcesDiscoverCombinedResult, allocator: std.mem.Allocator) void {
        for (self.skill_paths) |*path| path.deinit(allocator);
        allocator.free(self.skill_paths);
        for (self.prompt_paths) |*path| path.deinit(allocator);
        allocator.free(self.prompt_paths);
        for (self.theme_paths) |*path| path.deinit(allocator);
        allocator.free(self.theme_paths);
        self.* = undefined;
    }
};

pub const InputAction = enum {
    @"continue",
    transform,
    handled,
};

pub const InputEventResult = struct {
    action: InputAction,
    text: ?[]const u8 = null,
    images: ?[]const []const u8 = null,
};

pub const OwnedInputEventResult = struct {
    action: InputAction,
    text: ?[]u8 = null,
    images: ?[]const []const u8 = null,

    pub fn deinit(self: *OwnedInputEventResult, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.* = undefined;
    }
};

pub const ToolResultPatch = struct {
    content: ?[]const []const u8 = null,
    details: ?[]const u8 = null,
    is_error: ?bool = null,
};

pub const ToolResultCombinedResult = struct {
    content: []const []const u8,
    details: ?[]const u8,
    is_error: bool,
};

pub const SessionBeforeResult = struct {
    cancel: bool = false,
};

pub const MessageEndResult = struct {
    role: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const MessageEndCombinedResult = struct {
    role: []const u8,
    message: []const u8,
};

pub const ContextEventResult = struct {
    messages: ?[]const []const u8 = null,
};

pub const BeforeProviderRequestEventResult = struct {
    payload: ?[]const u8 = null,
};

pub const BeforeAgentStartEventResult = struct {
    message: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
};

pub const BeforeAgentStartCombinedResult = struct {
    messages: []const []const u8,
    system_prompt: ?[]const u8,

    pub fn deinit(self: *BeforeAgentStartCombinedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.messages);
        self.* = undefined;
    }
};

pub const ToolCallEventResult = struct {
    input: ?[]const u8 = null,
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const ToolCallCombinedResult = struct {
    input: []const u8,
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const UserBashEventResult = struct {
    operations: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

pub const SubAgentReadinessEnvelopeKind = enum {
    task_invocation,
    task_result,
};

pub const SubAgentReadinessDiagnostic = struct {
    path: []u8,
    message: []u8,

    pub fn deinit(self: *SubAgentReadinessDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const SubAgentReadinessValidation = union(enum) {
    valid: SubAgentReadinessEnvelopeKind,
    invalid: SubAgentReadinessDiagnostic,

    pub fn deinit(self: *SubAgentReadinessValidation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .invalid => |*diagnostic| diagnostic.deinit(allocator),
            .valid => {},
        }
        self.* = undefined;
    }
};

const subagent_correlation_fields = [_][]const u8{ "agentId", "runId", "taskId", "sessionId" };
const subagent_optional_id_fields = [_][]const u8{ "toolCallId", "parentAgentId", "parentRunId", "parentTaskId", "parentSessionId", "parentId" };
const subagent_limit_fields = [_][]const u8{ "maxChildren", "depth", "turns", "timeoutMs", "outputBytes", "outputLines", "toolScopes" };
const subagent_resource_summary_fields = [_][]const u8{ "turns", "outputBytes", "outputLines", "childrenStarted", "limitDetails" };
const subagent_resource_summary_number_fields = [_][]const u8{ "turns", "outputBytes", "outputLines", "childrenStarted" };
const subagent_limit_detail_fields = [_][]const u8{ "limit", "actual", "truncated", "reason" };
const subagent_forbidden_fields = [_][]const u8{ "ui", "ux", "slashCommand", "spawn", "spawnPolicy", "automaticSpawn", "orchestrationPolicy", "modelSelectionUi", "approvalPolicy" };
const subagent_cancellation_states = [_][]const u8{ "pending", "requested", "propagated", "completed" };
const subagent_result_statuses = [_][]const u8{ "pending", "running", "completed", "failed", "cancelled" };

pub fn validateSubAgentReadinessEnvelope(allocator: std.mem.Allocator, value: std.json.Value) !SubAgentReadinessValidation {
    const object = switch (value) {
        .object => |object| object,
        else => return invalidReadiness(allocator, "$", "expected object"),
    };
    const type_name = getString(object, "type") orelse return invalidReadiness(allocator, "$.type", "missing required field");
    if (std.mem.eql(u8, type_name, "sub_agent_task_invocation")) {
        return validateSubAgentTaskInvocationEnvelope(allocator, object);
    }
    if (std.mem.eql(u8, type_name, "sub_agent_task_result")) {
        return validateSubAgentTaskResultEnvelope(allocator, object);
    }
    const message = try std.fmt.allocPrint(allocator, "unsupported sub-agent readiness envelope \"{s}\"", .{type_name});
    defer allocator.free(message);
    return invalidReadiness(allocator, "$.type", message);
}

pub fn validateSubAgentTaskInvocationEnvelope(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SubAgentReadinessValidation {
    if (try forbiddenFieldDiagnostic(allocator, object, "$")) |diagnostic| return .{ .invalid = diagnostic };
    if (try exactTypeDiagnostic(allocator, object, "sub_agent_task_invocation")) |diagnostic| return .{ .invalid = diagnostic };
    if (try correlationDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };
    if (try optionalIdsDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };
    if (try optionalStringDiagnostic(allocator, object, "$", "route")) |diagnostic| return .{ .invalid = diagnostic };
    const input = object.get("input") orelse return invalidReadiness(allocator, "$.input", "missing required field");
    if (input != .object) return invalidReadiness(allocator, "$.input", "expected object");
    if (object.get("metadata")) |metadata| {
        if (metadata != .object) return invalidReadiness(allocator, "$.metadata", "expected object");
    }
    if (object.get("limits")) |limits| {
        const limits_object = switch (limits) {
            .object => |limits_object| limits_object,
            else => return invalidReadiness(allocator, "$.limits", "expected object"),
        };
        if (try limitsDiagnostic(allocator, limits_object)) |diagnostic| return .{ .invalid = diagnostic };
    }
    if (object.get("cancellation")) |cancellation| {
        const cancellation_object = switch (cancellation) {
            .object => |cancellation_object| cancellation_object,
            else => return invalidReadiness(allocator, "$.cancellation", "expected object"),
        };
        if (try cancellationDiagnostic(allocator, cancellation_object)) |diagnostic| return .{ .invalid = diagnostic };
    }
    return .{ .valid = .task_invocation };
}

pub fn validateSubAgentTaskResultEnvelope(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SubAgentReadinessValidation {
    if (try forbiddenFieldDiagnostic(allocator, object, "$")) |diagnostic| return .{ .invalid = diagnostic };
    if (try exactTypeDiagnostic(allocator, object, "sub_agent_task_result")) |diagnostic| return .{ .invalid = diagnostic };
    if (try correlationDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };
    if (try optionalIdsDiagnostic(allocator, object)) |diagnostic| return .{ .invalid = diagnostic };

    const status = getString(object, "status") orelse return invalidReadiness(allocator, "$.status", "missing required field");
    if (!stringInComptimeTable(status, &subagent_result_statuses)) {
        const message = try std.fmt.allocPrint(allocator, "unsupported task status \"{s}\"", .{status});
        defer allocator.free(message);
        return invalidReadiness(allocator, "$.status", message);
    }
    if (try requiredNonNegativeNumberDiagnostic(allocator, object, "$", "startedAt")) |diagnostic| return .{ .invalid = diagnostic };
    if (try requiredNonNegativeNumberDiagnostic(allocator, object, "$", "completedAt")) |diagnostic| return .{ .invalid = diagnostic };
    if (object.get("details")) |details| {
        if (details != .object) return invalidReadiness(allocator, "$.details", "expected object");
    }
    if (object.get("error")) |error_value| {
        const error_object = switch (error_value) {
            .object => |error_object| error_object,
            else => return invalidReadiness(allocator, "$.error", "expected object"),
        };
        const reason = getString(error_object, "reason") orelse return invalidReadiness(allocator, "$.error.reason", "missing required field");
        if (reason.len == 0) return invalidReadiness(allocator, "$.error.reason", "must not be empty");
        if (try optionalStringDiagnostic(allocator, error_object, "$.error", "message")) |diagnostic| return .{ .invalid = diagnostic };
        if (error_object.get("details")) |details| {
            if (details != .object) return invalidReadiness(allocator, "$.error.details", "expected object");
        }
    }
    if (object.get("usage")) |usage| {
        const usage_object = switch (usage) {
            .object => |usage_object| usage_object,
            else => return invalidReadiness(allocator, "$.usage", "expected object"),
        };
        if (try numericSummaryDiagnostic(allocator, usage_object, "$.usage")) |diagnostic| return .{ .invalid = diagnostic };
    }
    if (object.get("resourceSummary")) |resource_summary| {
        const summary_object = switch (resource_summary) {
            .object => |summary_object| summary_object,
            else => return invalidReadiness(allocator, "$.resourceSummary", "expected object"),
        };
        if (try resourceSummaryDiagnostic(allocator, summary_object)) |diagnostic| return .{ .invalid = diagnostic };
    }
    return .{ .valid = .task_result };
}

fn forbiddenFieldDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (stringInComptimeTable(entry.key_ptr.*, &subagent_forbidden_fields)) {
            const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, entry.key_ptr.* });
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "product UX/spawn policy is not allowed")).invalid;
        }
    }
    return null;
}

fn exactTypeDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, expected: []const u8) !?SubAgentReadinessDiagnostic {
    const type_value = object.get("type") orelse return (try invalidReadiness(allocator, "$.type", "missing required field")).invalid;
    const actual = switch (type_value) {
        .string => |text| text,
        else => return (try invalidReadiness(allocator, "$.type", "expected string")).invalid,
    };
    if (!std.mem.eql(u8, actual, expected)) {
        const message = try std.fmt.allocPrint(allocator, "expected \"{s}\"", .{expected});
        defer allocator.free(message);
        return (try invalidReadiness(allocator, "$.type", message)).invalid;
    }
    return null;
}

fn correlationDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    inline for (subagent_correlation_fields) |field| {
        const path = comptime "$." ++ field;
        const value = object.get(field) orelse return (try invalidReadiness(allocator, path, "missing required field")).invalid;
        const text = switch (value) {
            .string => |text| text,
            else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
        };
        if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
    }
    return null;
}

fn optionalIdsDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    inline for (subagent_optional_id_fields) |field| {
        if (object.get(field)) |value| {
            const path = comptime "$." ++ field;
            const text = switch (value) {
                .string => |text| text,
                else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
            };
            if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
        }
    }
    return null;
}

fn limitsDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_limit_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.limits.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported resource limit")).invalid;
        }
    }
    inline for (subagent_limit_fields[0..6]) |field| {
        if (try optionalNonNegativeIntegerDiagnostic(allocator, object, "$.limits", field)) |diagnostic| return diagnostic;
    }
    if (object.get("toolScopes")) |tool_scopes| {
        const array = switch (tool_scopes) {
            .array => |array| array,
            else => return (try invalidReadiness(allocator, "$.limits.toolScopes", "expected array")).invalid,
        };
        for (array.items, 0..) |scope, index| {
            const path = try std.fmt.allocPrint(allocator, "$.limits.toolScopes[{d}]", .{index});
            defer allocator.free(path);
            const text = switch (scope) {
                .string => |text| text,
                else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
            };
            if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
        }
    }
    return null;
}

fn resourceSummaryDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_resource_summary_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported resource summary field")).invalid;
        }
    }
    inline for (subagent_resource_summary_number_fields) |field| {
        if (object.get(field)) |value| {
            if (try nonNegativeNumberValueDiagnostic(allocator, value, "$.resourceSummary", field)) |diagnostic| return diagnostic;
        }
    }
    if (object.get("limitDetails")) |limit_details| {
        const details_object = switch (limit_details) {
            .object => |details_object| details_object,
            else => return (try invalidReadiness(allocator, "$.resourceSummary.limitDetails", "expected object")).invalid,
        };
        if (try limitDetailsDiagnostic(allocator, details_object)) |diagnostic| return diagnostic;
    }
    return null;
}

fn limitDetailsDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_limit_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported resource limit detail")).invalid;
        }
    }
    inline for (subagent_limit_fields[0..6]) |field| {
        if (object.get(field)) |value| {
            const detail_object = switch (value) {
                .object => |detail_object| detail_object,
                else => {
                    const path = comptime "$.resourceSummary.limitDetails." ++ field;
                    return (try invalidReadiness(allocator, path, "expected object")).invalid;
                },
            };
            if (try limitDetailObjectDiagnostic(allocator, detail_object, field)) |diagnostic| return diagnostic;
        }
    }
    if (object.get("toolScopes")) |tool_scopes| {
        const array = switch (tool_scopes) {
            .array => |array| array,
            else => return (try invalidReadiness(allocator, "$.resourceSummary.limitDetails.toolScopes", "expected array")).invalid,
        };
        for (array.items, 0..) |scope, index| {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.toolScopes[{d}]", .{index});
            defer allocator.free(path);
            const text = switch (scope) {
                .string => |text| text,
                else => return (try invalidReadiness(allocator, path, "expected string")).invalid,
            };
            if (text.len == 0) return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
        }
    }
    return null;
}

fn limitDetailObjectDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) !?SubAgentReadinessDiagnostic {
    const parent_path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.{s}", .{field});
    defer allocator.free(parent_path);

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!stringInComptimeTable(entry.key_ptr.*, &subagent_limit_detail_fields)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceSummary.limitDetails.{s}.{s}", .{ field, entry.key_ptr.* });
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "unsupported limit detail field")).invalid;
        }
    }
    if (try requiredNonNegativeNumberDiagnostic(allocator, object, parent_path, "limit")) |diagnostic| return diagnostic;
    if (try optionalNonNegativeNumberDiagnostic(allocator, object, parent_path, "actual")) |diagnostic| return diagnostic;
    if (try requiredBooleanDiagnostic(allocator, object, parent_path, "truncated")) |diagnostic| return diagnostic;
    if (try optionalStringDiagnostic(allocator, object, parent_path, "reason")) |diagnostic| return diagnostic;
    return null;
}

fn cancellationDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?SubAgentReadinessDiagnostic {
    const state = getString(object, "state") orelse return (try invalidReadiness(allocator, "$.cancellation.state", "missing required field")).invalid;
    if (!stringInComptimeTable(state, &subagent_cancellation_states)) {
        const message = try std.fmt.allocPrint(allocator, "unsupported cancellation state \"{s}\"", .{state});
        defer allocator.free(message);
        return (try invalidReadiness(allocator, "$.cancellation.state", message)).invalid;
    }
    inline for ([_][]const u8{ "signalId", "reason", "parentRunId", "parentTaskId", "propagatedFrom" }) |field| {
        if (try optionalStringDiagnostic(allocator, object, "$.cancellation", field)) |diagnostic| return diagnostic;
    }
    return null;
}

fn numericSummaryDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8) !?SubAgentReadinessDiagnostic {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (try nonNegativeNumberValueDiagnostic(allocator, entry.value_ptr.*, parent_path, entry.key_ptr.*)) |diagnostic| return diagnostic;
    }
    return null;
}

fn requiredNonNegativeNumberDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse {
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
        defer allocator.free(path);
        return (try invalidReadiness(allocator, path, "missing required field")).invalid;
    };
    return nonNegativeNumberValueDiagnostic(allocator, value, parent_path, field);
}

fn optionalNonNegativeIntegerDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse return null;
    const valid = switch (value) {
        .integer => |number| number >= 0,
        else => false,
    };
    if (valid) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "expected non-negative integer")).invalid;
}

fn optionalNonNegativeNumberDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse return null;
    return nonNegativeNumberValueDiagnostic(allocator, value, parent_path, field);
}

fn nonNegativeNumberValueDiagnostic(allocator: std.mem.Allocator, value: std.json.Value, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const valid = switch (value) {
        .integer => |number| number >= 0,
        .float => |number| number >= 0,
        else => false,
    };
    if (valid) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "expected non-negative number")).invalid;
}

fn requiredBooleanDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse {
        const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
        defer allocator.free(path);
        return (try invalidReadiness(allocator, path, "missing required field")).invalid;
    };
    switch (value) {
        .bool => return null,
        else => {},
    }
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "expected boolean")).invalid;
}

fn optionalStringDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field: []const u8) !?SubAgentReadinessDiagnostic {
    const value = object.get(field) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => {
            const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
            defer allocator.free(path);
            return (try invalidReadiness(allocator, path, "expected string")).invalid;
        },
    };
    if (text.len != 0) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
    defer allocator.free(path);
    return (try invalidReadiness(allocator, path, "must not be empty")).invalid;
}

fn getString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn stringInComptimeTable(value: []const u8, comptime table: []const []const u8) bool {
    inline for (table) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn invalidReadiness(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !SubAgentReadinessValidation {
    return .{ .invalid = .{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    } };
}

pub const EventHandlerResult = union(enum) {
    none,
    resources_discover: ResourcesDiscoverResult,
    input: InputEventResult,
    tool_result: ToolResultPatch,
    session_before: SessionBeforeResult,
    message_end: MessageEndResult,
    context: ContextEventResult,
    before_provider_request: BeforeProviderRequestEventResult,
    before_agent_start: BeforeAgentStartEventResult,
    tool_call: ToolCallEventResult,
    user_bash: UserBashEventResult,
};

pub const ExtensionError = struct {
    extension_path: []u8,
    event: []u8,
    @"error": []u8,

    fn deinit(self: *ExtensionError, allocator: std.mem.Allocator) void {
        allocator.free(self.extension_path);
        allocator.free(self.event);
        allocator.free(self.@"error");
        self.* = undefined;
    }
};

pub const ResultEventHandler = *const fn (event: ExtensionEvent) anyerror!EventHandlerResult;

/// Event bus for extension event handling
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),

    const HandlerEntry = struct {
        event_type: ExtensionEventType,
        handler: EventHandler,
        extension_path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
        };
    }

    pub fn deinit(self: *EventBus) void {
        for (self.handlers.items) |*entry| {
            self.allocator.free(entry.extension_path);
        }
        self.handlers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Subscribe to an event type
    pub fn on(self: *EventBus, event_type: ExtensionEventType, handler: EventHandler, extension_path: []const u8) !void {
        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        });
    }

    /// Remove all handlers for a given extension path
    pub fn clearExtensionHandlers(self: *EventBus, extension_path: []const u8) void {
        var i: usize = self.handlers.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.handlers.items[i].extension_path, extension_path)) {
                self.allocator.free(self.handlers.items[i].extension_path);
                _ = self.handlers.orderedRemove(i);
            }
        }
    }

    /// Emit an event to all subscribed handlers
    pub fn emit(self: *EventBus, event: ExtensionEvent) !void {
        const event_type = std.meta.activeTag(event);
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) {
                try entry.handler(event);
            }
        }
    }

    /// Check if there are any handlers for a given event type
    pub fn hasHandlers(self: *const EventBus, event_type: ExtensionEventType) bool {
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) return true;
        }
        return false;
    }
};

/// Result-returning event bus used by low-architecture parity tests and
/// host bridges that need the same observable aggregation contract as the
/// TypeScript extension runner. Handler order is extension registration
/// order, errors are recorded with TypeScript-compatible fields, and
/// successful handlers continue after non-terminal failures.
pub const ResultEventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry),
    errors: std.ArrayList(ExtensionError),

    const HandlerEntry = struct {
        event_type: ExtensionEventType,
        handler: ResultEventHandler,
        extension_path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) ResultEventBus {
        return .{
            .allocator = allocator,
            .handlers = std.ArrayList(HandlerEntry).empty,
            .errors = std.ArrayList(ExtensionError).empty,
        };
    }

    pub fn deinit(self: *ResultEventBus) void {
        for (self.handlers.items) |*entry| {
            self.allocator.free(entry.extension_path);
        }
        self.handlers.deinit(self.allocator);
        for (self.errors.items) |*err| err.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn on(self: *ResultEventBus, event_type: ExtensionEventType, handler: ResultEventHandler, extension_path: []const u8) !void {
        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        });
    }

    pub fn emitLifecycle(self: *ResultEventBus, event: ExtensionEvent) !void {
        const event_type = std.meta.activeTag(event);
        for (self.handlers.items) |entry| {
            if (entry.event_type != event_type) continue;
            _ = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, event_type, err);
                continue;
            };
        }
    }

    pub fn emitSessionBefore(self: *ResultEventBus, event: ExtensionEvent) !?SessionBeforeResult {
        const event_type = std.meta.activeTag(event);
        switch (event_type) {
            .session_before_switch, .session_before_fork, .session_before_compact, .session_before_tree => {},
            else => return null,
        }

        var result: ?SessionBeforeResult = null;
        for (self.handlers.items) |entry| {
            if (entry.event_type != event_type) continue;
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, event_type, err);
                continue;
            };
            switch (handler_result) {
                .session_before => |session_result| {
                    result = session_result;
                    if (session_result.cancel) return session_result;
                },
                else => {},
            }
        }
        return result;
    }

    pub fn emitResourcesDiscover(self: *ResultEventBus, cwd: []const u8, reason: []const u8) !ResourcesDiscoverCombinedResult {
        var skill_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &skill_paths);
        var prompt_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &prompt_paths);
        var theme_paths = std.ArrayList(ResourcePathResult).empty;
        errdefer deinitResourcePathList(self.allocator, &theme_paths);

        const event = ExtensionEvent{ .resources_discover = .{ .cwd = cwd, .reason = reason } };
        for (self.handlers.items) |entry| {
            if (entry.event_type != .resources_discover) continue;
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .resources_discover, err);
                continue;
            };
            switch (handler_result) {
                .resources_discover => |result| {
                    try appendResourcePaths(self.allocator, &skill_paths, result.skill_paths, entry.extension_path);
                    try appendResourcePaths(self.allocator, &prompt_paths, result.prompt_paths, entry.extension_path);
                    try appendResourcePaths(self.allocator, &theme_paths, result.theme_paths, entry.extension_path);
                },
                else => {},
            }
        }

        return .{
            .skill_paths = try skill_paths.toOwnedSlice(self.allocator),
            .prompt_paths = try prompt_paths.toOwnedSlice(self.allocator),
            .theme_paths = try theme_paths.toOwnedSlice(self.allocator),
        };
    }

    pub fn emitInput(self: *ResultEventBus, data: []const u8) !OwnedInputEventResult {
        return self.emitInputWithImages(data, &.{});
    }

    pub fn emitInputWithImages(self: *ResultEventBus, data: []const u8, images: []const []const u8) !OwnedInputEventResult {
        var current = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(current);
        var current_images = images;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .input) continue;
            const event = ExtensionEvent{ .input = .{ .data = current, .images = current_images } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .input, err);
                continue;
            };
            switch (handler_result) {
                .input => |result| switch (result.action) {
                    .handled => {
                        self.allocator.free(current);
                        return .{ .action = .handled };
                    },
                    .transform => {
                        if (result.text) |text| {
                            const next = try self.allocator.dupe(u8, text);
                            self.allocator.free(current);
                            current = next;
                            modified = true;
                        }
                        if (result.images) |next_images| {
                            current_images = next_images;
                            modified = true;
                        }
                    },
                    .@"continue" => {},
                },
                else => {},
            }
        }

        if (modified) {
            return .{ .action = .transform, .text = current, .images = current_images };
        }
        self.allocator.free(current);
        return .{ .action = .@"continue" };
    }

    pub fn emitMessageEnd(self: *ResultEventBus, event: MessageEndEvent) !?MessageEndCombinedResult {
        var current_role = event.role;
        var current_message = event.final_message;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .message_end) continue;
            const current_event = ExtensionEvent{ .message_end = .{
                .message_id = event.message_id,
                .role = current_role,
                .final_message = current_message,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .message_end, err);
                continue;
            };
            switch (handler_result) {
                .message_end => |replacement| {
                    if (replacement.message) |message| {
                        const replacement_role = replacement.role orelse current_role;
                        if (!std.mem.eql(u8, replacement_role, current_role)) {
                            try self.recordErrorMessage(entry.extension_path, .message_end, "message_end handlers must return a message with the same role");
                            continue;
                        }
                        current_role = replacement_role;
                        current_message = message;
                        modified = true;
                    }
                },
                else => {},
            }
        }

        if (!modified) return null;
        return .{ .role = current_role, .message = current_message };
    }

    pub fn emitContext(self: *ResultEventBus, messages: []const []const u8) ![]const []const u8 {
        var current_messages = messages;
        for (self.handlers.items) |entry| {
            if (entry.event_type != .context) continue;
            const event = ExtensionEvent{ .context = .{ .messages = current_messages } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .context, err);
                continue;
            };
            switch (handler_result) {
                .context => |result| {
                    if (result.messages) |next| current_messages = next;
                },
                else => {},
            }
        }
        return current_messages;
    }

    pub fn emitBeforeProviderRequest(self: *ResultEventBus, payload: []const u8) ![]const u8 {
        var current_payload = payload;
        for (self.handlers.items) |entry| {
            if (entry.event_type != .before_provider_request) continue;
            const event = ExtensionEvent{ .before_provider_request = .{
                .model = "",
                .messages = &.{},
                .payload = current_payload,
            } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .before_provider_request, err);
                continue;
            };
            switch (handler_result) {
                .before_provider_request => |result| {
                    if (result.payload) |next| current_payload = next;
                },
                else => {},
            }
        }
        return current_payload;
    }

    pub fn emitBeforeAgentStart(
        self: *ResultEventBus,
        prompt: []const u8,
        images: []const []const u8,
        system_prompt: []const u8,
    ) !?BeforeAgentStartCombinedResult {
        var current_system_prompt = system_prompt;
        var messages = std.ArrayList([]const u8).empty;
        errdefer messages.deinit(self.allocator);
        var system_prompt_modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .before_agent_start) continue;
            const event = ExtensionEvent{ .before_agent_start = .{
                .prompt = prompt,
                .images = images,
                .system_prompt = current_system_prompt,
                .messages = messages.items,
            } };
            const handler_result = entry.handler(event) catch |err| {
                try self.recordError(entry.extension_path, .before_agent_start, err);
                continue;
            };
            switch (handler_result) {
                .before_agent_start => |result| {
                    if (result.message) |message| try messages.append(self.allocator, message);
                    if (result.system_prompt) |next| {
                        current_system_prompt = next;
                        system_prompt_modified = true;
                    }
                },
                else => {},
            }
        }

        if (messages.items.len == 0 and !system_prompt_modified) {
            messages.deinit(self.allocator);
            return null;
        }
        return .{
            .messages = try messages.toOwnedSlice(self.allocator),
            .system_prompt = if (system_prompt_modified) current_system_prompt else null,
        };
    }

    pub fn emitToolCall(self: *ResultEventBus, event: ToolCallEvent) !?ToolCallCombinedResult {
        var current_input = event.input;
        var modified = false;
        var result_seen = false;
        var last_reason: ?[]const u8 = null;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .tool_call) continue;
            const current_event = ExtensionEvent{ .tool_call = .{
                .tool_name = event.tool_name,
                .tool_call_id = event.tool_call_id,
                .input = current_input,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .tool_call, err);
                continue;
            };
            switch (handler_result) {
                .tool_call => |result| {
                    result_seen = true;
                    if (result.input) |next_input| {
                        current_input = next_input;
                        modified = true;
                    }
                    last_reason = result.reason;
                    if (result.block) {
                        return .{
                            .input = current_input,
                            .block = true,
                            .reason = result.reason,
                        };
                    }
                },
                else => {},
            }
        }

        if (!modified and !result_seen) return null;
        return .{ .input = current_input, .reason = last_reason };
    }

    pub fn emitToolResult(self: *ResultEventBus, event: ToolResultEvent) !?ToolResultCombinedResult {
        var current_content = event.content;
        var current_details = event.details;
        var current_is_error = event.is_error;
        var modified = false;

        for (self.handlers.items) |entry| {
            if (entry.event_type != .tool_result) continue;
            const current_event = ExtensionEvent{ .tool_result = .{
                .tool_name = event.tool_name,
                .tool_call_id = event.tool_call_id,
                .result = event.result,
                .content = current_content,
                .details = current_details,
                .is_error = current_is_error,
            } };
            const handler_result = entry.handler(current_event) catch |err| {
                try self.recordError(entry.extension_path, .tool_result, err);
                continue;
            };
            switch (handler_result) {
                .tool_result => |patch| {
                    if (patch.content) |content| {
                        current_content = content;
                        modified = true;
                    }
                    if (patch.details) |details| {
                        current_details = details;
                        modified = true;
                    }
                    if (patch.is_error) |is_error| {
                        current_is_error = is_error;
                        modified = true;
                    }
                },
                else => {},
            }
        }

        if (!modified) return null;
        return .{
            .content = current_content,
            .details = current_details,
            .is_error = current_is_error,
        };
    }

    pub fn emitUserBash(self: *ResultEventBus, event: UserBashEvent) !?UserBashEventResult {
        for (self.handlers.items) |entry| {
            if (entry.event_type != .user_bash) continue;
            const handler_result = entry.handler(.{ .user_bash = event }) catch |err| {
                try self.recordError(entry.extension_path, .user_bash, err);
                continue;
            };
            switch (handler_result) {
                .user_bash => |result| return result,
                else => {},
            }
        }
        return null;
    }

    fn recordError(self: *ResultEventBus, extension_path: []const u8, event_type: ExtensionEventType, err: anyerror) !void {
        try self.recordErrorMessage(extension_path, event_type, @errorName(err));
    }

    fn recordErrorMessage(self: *ResultEventBus, extension_path: []const u8, event_type: ExtensionEventType, message: []const u8) !void {
        const path_dup = try self.allocator.dupe(u8, extension_path);
        errdefer self.allocator.free(path_dup);
        const event_name_value = eventName(event_type);
        const event_dup = try self.allocator.dupe(u8, event_name_value);
        errdefer self.allocator.free(event_dup);
        const error_dup = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(error_dup);
        try self.errors.append(self.allocator, .{
            .extension_path = path_dup,
            .event = event_dup,
            .@"error" = error_dup,
        });
    }
};

fn appendResourcePaths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ResourcePathResult),
    paths: []const []const u8,
    extension_path: []const u8,
) !void {
    for (paths) |path| {
        const path_dup = try allocator.dupe(u8, path);
        errdefer allocator.free(path_dup);
        const extension_path_dup = try allocator.dupe(u8, extension_path);
        errdefer allocator.free(extension_path_dup);
        try out.append(allocator, .{ .path = path_dup, .extension_path = extension_path_dup });
    }
}

fn deinitResourcePathList(allocator: std.mem.Allocator, list: *std.ArrayList(ResourcePathResult)) void {
    for (list.items) |*path| path.deinit(allocator);
    list.deinit(allocator);
}

pub fn eventSurfaceNames() []const []const u8 {
    return &.{
        "resources_discover",
        "session_start",
        "session_before_switch",
        "session_before_fork",
        "session_before_compact",
        "session_compact",
        "session_shutdown",
        "session_before_tree",
        "session_tree",
        "before_agent_start",
        "agent_start",
        "agent_end",
        "sub_agent_readiness",
        "turn_start",
        "turn_end",
        "message_start",
        "message_update",
        "message_end",
        "tool_execution_start",
        "tool_execution_update",
        "tool_execution_end",
        "tool_call",
        "tool_result",
        "user_bash",
        "context",
        "before_provider_request",
        "after_provider_response",
        "model_select",
        "thinking_level_select",
        "input",
    };
}

pub fn eventName(event_type: ExtensionEventType) []const u8 {
    return switch (event_type) {
        .resources_discover => "resources_discover",
        .session_start => "session_start",
        .session_before_switch => "session_before_switch",
        .session_before_fork => "session_before_fork",
        .session_before_compact => "session_before_compact",
        .session_compact => "session_compact",
        .session_shutdown => "session_shutdown",
        .session_before_tree => "session_before_tree",
        .session_tree => "session_tree",
        .before_agent_start => "before_agent_start",
        .agent_start => "agent_start",
        .agent_end => "agent_end",
        .sub_agent_readiness => "sub_agent_readiness",
        .turn_start => "turn_start",
        .turn_end => "turn_end",
        .message_start => "message_start",
        .message_update => "message_update",
        .message_end => "message_end",
        .tool_execution_start => "tool_execution_start",
        .tool_execution_update => "tool_execution_update",
        .tool_execution_end => "tool_execution_end",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .user_bash => "user_bash",
        .context => "context",
        .before_provider_request => "before_provider_request",
        .after_provider_response => "after_provider_response",
        .model_select => "model_select",
        .thinking_level_select => "thinking_level_select",
        .input => "input",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

var test_event_received: bool = false;
var test_event_data: []const u8 = "";

fn testHandler(event: ExtensionEvent) !void {
    switch (event) {
        .session_start => |e| {
            test_event_received = true;
            test_event_data = e.reason;
        },
        else => {},
    }
}

test "EventBus subscribes and emits events" {
    test_event_received = false;
    test_event_data = "";

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.session_start, testHandler, "/tmp/ext.ts");
    try std.testing.expect(bus.hasHandlers(.session_start));
    try std.testing.expect(!bus.hasHandlers(.agent_start));

    const event = ExtensionEvent{
        .session_start = .{
            .reason = "startup",
        },
    };
    try bus.emit(event);

    try std.testing.expect(test_event_received);
    try std.testing.expectEqualStrings("startup", test_event_data);
}

test "EventBus clears extension handlers" {
    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.session_start, testHandler, "/tmp/ext.ts");
    try std.testing.expect(bus.hasHandlers(.session_start));

    bus.clearExtensionHandlers("/tmp/ext.ts");
    try std.testing.expect(!bus.hasHandlers(.session_start));
}

var g_count: u32 = 0;

fn countingHandler1(_: ExtensionEvent) !void {
    g_count += 1;
}

fn countingHandler2(_: ExtensionEvent) !void {
    g_count += 1;
}

test "EventBus emits to multiple handlers" {
    g_count = 0;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    try bus.on(.agent_start, countingHandler1, "/tmp/ext1.ts");
    try bus.on(.agent_start, countingHandler2, "/tmp/ext2.ts");

    const event = ExtensionEvent{ .agent_start = .{} };
    try bus.emit(event);

    try std.testing.expectEqual(@as(u32, 2), g_count);
}

const resource_skills_1 = [_][]const u8{"/skills/one"};
const resource_prompts_1 = [_][]const u8{"/prompts/one"};
const resource_themes_2 = [_][]const u8{"/themes/two"};

fn resourcesHandlerOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("/work", event.resources_discover.cwd);
    try std.testing.expectEqualStrings("startup", event.resources_discover.reason);
    return .{ .resources_discover = .{
        .skill_paths = &resource_skills_1,
        .prompt_paths = &resource_prompts_1,
    } };
}

fn resourcesHandlerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ResourcesDiscoverFixtureFailure;
}

fn resourcesHandlerTwo(_: ExtensionEvent) !EventHandlerResult {
    return .{ .resources_discover = .{
        .theme_paths = &resource_themes_2,
    } };
}

test "ResultEventBus resources_discover preserves empty success failure and listener order" {
    const allocator = std.testing.allocator;

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    var empty = try empty_bus.emitResourcesDiscover("/work", "startup");
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.skill_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.prompt_paths.len);
    try std.testing.expectEqual(@as(usize, 0), empty.theme_paths.len);

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.resources_discover, resourcesHandlerOne, "/tmp/resources-one.ts");
    try bus.on(.resources_discover, resourcesHandlerFailure, "/tmp/resources-fail.ts");
    try bus.on(.resources_discover, resourcesHandlerTwo, "/tmp/resources-two.ts");

    var result = try bus.emitResourcesDiscover("/work", "startup");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.skill_paths.len);
    try std.testing.expectEqualStrings("/skills/one", result.skill_paths[0].path);
    try std.testing.expectEqualStrings("/tmp/resources-one.ts", result.skill_paths[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), result.prompt_paths.len);
    try std.testing.expectEqualStrings("/prompts/one", result.prompt_paths[0].path);
    try std.testing.expectEqual(@as(usize, 1), result.theme_paths.len);
    try std.testing.expectEqualStrings("/themes/two", result.theme_paths[0].path);
    try std.testing.expectEqualStrings("/tmp/resources-two.ts", result.theme_paths[0].extension_path);

    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("/tmp/resources-fail.ts", bus.errors.items[0].extension_path);
    try std.testing.expectEqualStrings("resources_discover", bus.errors.items[0].event);
    try std.testing.expectEqualStrings("ResourcesDiscoverFixtureFailure", bus.errors.items[0].@"error");
}

fn inputTransformOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.input.data);
    return .{ .input = .{ .action = .transform, .text = "first" } };
}

fn inputTransformTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.input.data);
    return .{ .input = .{ .action = .transform, .text = "second" } };
}

fn inputHandled(_: ExtensionEvent) !EventHandlerResult {
    return .{ .input = .{ .action = .handled } };
}

test "ResultEventBus input results chain transforms and handled short-circuits" {
    const allocator = std.testing.allocator;

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    var empty = try empty_bus.emitInput("base");
    defer empty.deinit(allocator);
    try std.testing.expect(empty.action == .@"continue");
    try std.testing.expect(empty.text == null);

    var transform_bus = ResultEventBus.init(allocator);
    defer transform_bus.deinit();
    try transform_bus.on(.input, inputTransformOne, "/tmp/input-one.ts");
    try transform_bus.on(.input, inputTransformTwo, "/tmp/input-two.ts");
    var transformed = try transform_bus.emitInput("base");
    defer transformed.deinit(allocator);
    try std.testing.expect(transformed.action == .transform);
    try std.testing.expectEqualStrings("second", transformed.text.?);

    var handled_bus = ResultEventBus.init(allocator);
    defer handled_bus.deinit();
    try handled_bus.on(.input, inputTransformOne, "/tmp/input-one.ts");
    try handled_bus.on(.input, inputHandled, "/tmp/input-handled.ts");
    try handled_bus.on(.input, inputTransformTwo, "/tmp/input-two.ts");
    var handled = try handled_bus.emitInput("base");
    defer handled.deinit(allocator);
    try std.testing.expect(handled.action == .handled);
    try std.testing.expect(handled.text == null);
}

const base_tool_content = [_][]const u8{"base"};
const patched_tool_content = [_][]const u8{"first"};

fn toolResultPatchContent(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.tool_result.content[0]);
    return .{ .tool_result = .{
        .content = &patched_tool_content,
        .details = "{\"source\":\"ext1\"}",
    } };
}

fn toolResultPatchError(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.tool_result.content[0]);
    try std.testing.expectEqualStrings("{\"source\":\"ext1\"}", event.tool_result.details.?);
    return .{ .tool_result = .{ .is_error = true } };
}

test "ResultEventBus tool_result returns undefined empty and chains partial patches" {
    const allocator = std.testing.allocator;

    const event = ToolResultEvent{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .result = "base",
        .content = &base_tool_content,
        .details = "{\"initial\":true}",
        .is_error = false,
    };

    var empty_bus = ResultEventBus.init(allocator);
    defer empty_bus.deinit();
    const empty = try empty_bus.emitToolResult(event);
    try std.testing.expect(empty == null);

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.tool_result, toolResultPatchContent, "/tmp/tool-result-one.ts");
    try bus.on(.tool_result, toolResultPatchError, "/tmp/tool-result-two.ts");

    const patched = (try bus.emitToolResult(event)).?;
    try std.testing.expectEqual(@as(usize, 1), patched.content.len);
    try std.testing.expectEqualStrings("first", patched.content[0]);
    try std.testing.expectEqualStrings("{\"source\":\"ext1\"}", patched.details.?);
    try std.testing.expect(patched.is_error);
}

var lifecycle_order: u32 = 0;

fn lifecycleHandlerOne(_: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(u32, 0), lifecycle_order);
    lifecycle_order += 1;
    return .none;
}

fn lifecycleHandlerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.LifecycleFixtureFailure;
}

fn lifecycleHandlerTwo(_: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(u32, 1), lifecycle_order);
    lifecycle_order += 1;
    return .none;
}

var session_after_cancel_called = false;

fn sessionBeforeContinue(_: ExtensionEvent) !EventHandlerResult {
    return .none;
}

fn sessionBeforeCancel(_: ExtensionEvent) !EventHandlerResult {
    return .{ .session_before = .{ .cancel = true } };
}

fn sessionBeforeAfterCancel(_: ExtensionEvent) !EventHandlerResult {
    session_after_cancel_called = true;
    return .none;
}

test "ResultEventBus lifecycle isolates errors and session_before first cancel short-circuits" {
    const allocator = std.testing.allocator;

    var lifecycle_bus = ResultEventBus.init(allocator);
    defer lifecycle_bus.deinit();
    lifecycle_order = 0;
    try lifecycle_bus.on(.session_start, lifecycleHandlerOne, "/tmp/lifecycle-one.ts");
    try lifecycle_bus.on(.session_start, lifecycleHandlerFailure, "/tmp/lifecycle-fail.ts");
    try lifecycle_bus.on(.session_start, lifecycleHandlerTwo, "/tmp/lifecycle-two.ts");
    try lifecycle_bus.emitLifecycle(.{ .session_start = .{ .reason = "startup" } });
    try std.testing.expectEqual(@as(u32, 2), lifecycle_order);
    try std.testing.expectEqual(@as(usize, 1), lifecycle_bus.errors.items.len);
    try std.testing.expectEqualStrings("session_start", lifecycle_bus.errors.items[0].event);

    var cancel_bus = ResultEventBus.init(allocator);
    defer cancel_bus.deinit();
    session_after_cancel_called = false;
    try cancel_bus.on(.session_before_switch, sessionBeforeContinue, "/tmp/session-one.ts");
    try cancel_bus.on(.session_before_switch, sessionBeforeCancel, "/tmp/session-cancel.ts");
    try cancel_bus.on(.session_before_switch, sessionBeforeAfterCancel, "/tmp/session-after.ts");
    const cancel = (try cancel_bus.emitSessionBefore(.{ .session_before_switch = .{ .reason = "new" } })).?;
    try std.testing.expect(cancel.cancel);
    try std.testing.expect(!session_after_cancel_called);
}

fn inputImageTransformOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.input.data);
    try std.testing.expectEqualStrings("orig-img", event.input.images[0]);
    return .{ .input = .{ .action = .transform, .text = "with-image" } };
}

const replacement_images = [_][]const u8{"new-img"};

fn inputImageTransformTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("with-image", event.input.data);
    try std.testing.expectEqualStrings("orig-img", event.input.images[0]);
    return .{ .input = .{ .action = .transform, .text = "done", .images = &replacement_images } };
}

test "ResultEventBus input preserves and replaces images through transform chaining" {
    const allocator = std.testing.allocator;
    const original_images = [_][]const u8{"orig-img"};

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.input, inputImageTransformOne, "/tmp/input-image-one.ts");
    try bus.on(.input, inputImageTransformTwo, "/tmp/input-image-two.ts");
    var transformed = try bus.emitInputWithImages("base", &original_images);
    defer transformed.deinit(allocator);
    try std.testing.expect(transformed.action == .transform);
    try std.testing.expectEqualStrings("done", transformed.text.?);
    try std.testing.expectEqualStrings("new-img", transformed.images.?[0]);
}

fn messageEndReplaceOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("user", event.message_end.role);
    try std.testing.expectEqualStrings("base", event.message_end.final_message);
    return .{ .message_end = .{ .role = "user", .message = "first" } };
}

fn messageEndInvalidRole(_: ExtensionEvent) !EventHandlerResult {
    return .{ .message_end = .{ .role = "assistant", .message = "invalid" } };
}

fn messageEndReplaceTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.message_end.final_message);
    return .{ .message_end = .{ .message = "second" } };
}

test "ResultEventBus message_end chains same role and reports invalid replacements" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.message_end, messageEndReplaceOne, "/tmp/message-one.ts");
    try bus.on(.message_end, messageEndInvalidRole, "/tmp/message-invalid.ts");
    try bus.on(.message_end, messageEndReplaceTwo, "/tmp/message-two.ts");

    const result = (try bus.emitMessageEnd(.{
        .message_id = "m1",
        .role = "user",
        .final_message = "base",
    })).?;
    try std.testing.expectEqualStrings("user", result.role);
    try std.testing.expectEqualStrings("second", result.message);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("message_end handlers must return a message with the same role", bus.errors.items[0].@"error");
}

const context_base = [_][]const u8{"base"};
const context_first = [_][]const u8{ "base", "first" };
const context_second = [_][]const u8{ "base", "first", "second" };

fn contextReplaceOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(usize, 1), event.context.messages.len);
    return .{ .context = .{ .messages = &context_first } };
}

fn contextFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ContextFixtureFailure;
}

fn contextReplaceTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqual(@as(usize, 2), event.context.messages.len);
    return .{ .context = .{ .messages = &context_second } };
}

fn providerReplaceOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.before_provider_request.payload);
    return .{ .before_provider_request = .{ .payload = "first" } };
}

fn providerFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ProviderFixtureFailure;
}

fn providerReplaceTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.before_provider_request.payload);
    return .{ .before_provider_request = .{ .payload = "second" } };
}

test "ResultEventBus context and provider replacements chain through errors" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.context, contextReplaceOne, "/tmp/context-one.ts");
    try bus.on(.context, contextFailure, "/tmp/context-fail.ts");
    try bus.on(.context, contextReplaceTwo, "/tmp/context-two.ts");
    try bus.on(.before_provider_request, providerReplaceOne, "/tmp/provider-one.ts");
    try bus.on(.before_provider_request, providerFailure, "/tmp/provider-fail.ts");
    try bus.on(.before_provider_request, providerReplaceTwo, "/tmp/provider-two.ts");

    const messages = try bus.emitContext(&context_base);
    const payload = try bus.emitBeforeProviderRequest("base");
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("second", messages[2]);
    try std.testing.expectEqualStrings("second", payload);
    try std.testing.expectEqual(@as(usize, 2), bus.errors.items.len);
    try std.testing.expectEqualStrings("ContextFixtureFailure", bus.errors.items[0].@"error");
    try std.testing.expectEqualStrings("ProviderFixtureFailure", bus.errors.items[1].@"error");
}

fn beforeAgentStartOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base prompt", event.before_agent_start.system_prompt);
    return .{ .before_agent_start = .{
        .message = "first-message",
        .system_prompt = "first prompt",
    } };
}

fn beforeAgentStartFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.BeforeAgentStartFixtureFailure;
}

fn beforeAgentStartTwo(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first prompt", event.before_agent_start.system_prompt);
    try std.testing.expectEqual(@as(usize, 1), event.before_agent_start.messages.len);
    return .{ .before_agent_start = .{
        .message = "second-message",
        .system_prompt = "second prompt",
    } };
}

test "ResultEventBus before_agent_start aggregates messages and chains system prompt" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    try bus.on(.before_agent_start, beforeAgentStartOne, "/tmp/before-one.ts");
    try bus.on(.before_agent_start, beforeAgentStartFailure, "/tmp/before-fail.ts");
    try bus.on(.before_agent_start, beforeAgentStartTwo, "/tmp/before-two.ts");

    var result = (try bus.emitBeforeAgentStart("hello", &.{}, "base prompt")).?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expectEqualStrings("first-message", result.messages[0]);
    try std.testing.expectEqualStrings("second-message", result.messages[1]);
    try std.testing.expectEqualStrings("second prompt", result.system_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("BeforeAgentStartFixtureFailure", bus.errors.items[0].@"error");
}

fn toolCallMutateOne(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("base", event.tool_call.input);
    return .{ .tool_call = .{ .input = "first" } };
}

fn toolCallFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.ToolCallFixtureFailure;
}

fn toolCallBlock(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("first", event.tool_call.input);
    return .{ .tool_call = .{ .block = true, .reason = "blocked" } };
}

var tool_call_after_block_called = false;

fn toolCallAfterBlock(_: ExtensionEvent) !EventHandlerResult {
    tool_call_after_block_called = true;
    return .none;
}

test "ResultEventBus tool_call exposes mutations, isolates errors, and first block wins" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    tool_call_after_block_called = false;
    try bus.on(.tool_call, toolCallMutateOne, "/tmp/tool-call-one.ts");
    try bus.on(.tool_call, toolCallFailure, "/tmp/tool-call-fail.ts");
    try bus.on(.tool_call, toolCallBlock, "/tmp/tool-call-block.ts");
    try bus.on(.tool_call, toolCallAfterBlock, "/tmp/tool-call-after.ts");

    const result = (try bus.emitToolCall(.{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .input = "base",
    })).?;
    try std.testing.expect(result.block);
    try std.testing.expectEqualStrings("first", result.input);
    try std.testing.expectEqualStrings("blocked", result.reason.?);
    try std.testing.expect(!tool_call_after_block_called);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("ToolCallFixtureFailure", bus.errors.items[0].@"error");
}

fn userBashUndefined(_: ExtensionEvent) !EventHandlerResult {
    return .none;
}

fn userBashFailure(_: ExtensionEvent) !EventHandlerResult {
    return error.UserBashFixtureFailure;
}

fn userBashResult(event: ExtensionEvent) !EventHandlerResult {
    try std.testing.expectEqualStrings("echo hi", event.user_bash.command);
    return .{ .user_bash = .{ .result = "handled" } };
}

var user_bash_after_result_called = false;

fn userBashAfterResult(_: ExtensionEvent) !EventHandlerResult {
    user_bash_after_result_called = true;
    return .{ .user_bash = .{ .result = "skipped" } };
}

test "ResultEventBus user_bash returns first result after undefined and errors" {
    const allocator = std.testing.allocator;

    var bus = ResultEventBus.init(allocator);
    defer bus.deinit();
    user_bash_after_result_called = false;
    try bus.on(.user_bash, userBashUndefined, "/tmp/user-bash-undefined.ts");
    try bus.on(.user_bash, userBashFailure, "/tmp/user-bash-fail.ts");
    try bus.on(.user_bash, userBashResult, "/tmp/user-bash-result.ts");
    try bus.on(.user_bash, userBashAfterResult, "/tmp/user-bash-after.ts");

    const result = (try bus.emitUserBash(.{ .command = "echo hi", .cwd = "/work" })).?;
    try std.testing.expectEqualStrings("handled", result.result.?);
    try std.testing.expect(!user_bash_after_result_called);
    try std.testing.expectEqual(@as(usize, 1), bus.errors.items.len);
    try std.testing.expectEqualStrings("UserBashFixtureFailure", bus.errors.items[0].@"error");
}

test "extension event conformance helper covers every supported event surface" {
    const names = eventSurfaceNames();
    try std.testing.expectEqual(@typeInfo(ExtensionEventType).@"enum".fields.len, names.len);
    try std.testing.expectEqualStrings("resources_discover", names[0]);
    try std.testing.expectEqualStrings("input", names[names.len - 1]);
    inline for (@typeInfo(ExtensionEventType).@"enum".fields, 0..) |field, index| {
        const event_type: ExtensionEventType = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(eventName(event_type), names[index]);
    }
}

var subagent_readiness_observed: bool = false;
var subagent_readiness_second_observer_called: bool = false;

fn subAgentReadinessObserver(event: ExtensionEvent) !void {
    try std.testing.expect(event == .sub_agent_readiness);
    try std.testing.expect(event.sub_agent_readiness.read_only);
    try std.testing.expectEqualStrings("recorded", event.sub_agent_readiness.phase);
    try std.testing.expectEqualStrings("agent", event.sub_agent_readiness.owner);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event.sub_agent_readiness.envelope, .{});
    defer parsed.deinit();
    var validation = try validateSubAgentReadinessEnvelope(std.testing.allocator, parsed.value);
    defer validation.deinit(std.testing.allocator);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_invocation, validation.valid);

    subagent_readiness_observed = true;
}

fn subAgentReadinessSecondObserver(event: ExtensionEvent) !void {
    try std.testing.expect(event == .sub_agent_readiness);
    subagent_readiness_second_observer_called = true;
}

test "sub-agent readiness events are subscriber observation only" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    subagent_readiness_observed = false;
    subagent_readiness_second_observer_called = false;

    try bus.on(.sub_agent_readiness, subAgentReadinessObserver, "/tmp/readiness-one.ts");
    try bus.on(.sub_agent_readiness, subAgentReadinessSecondObserver, "/tmp/readiness-two.ts");

    try bus.emit(.{ .sub_agent_readiness = .{
        .envelope = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\",\"input\":{\"text\":\"observe only\"},\"cancellation\":{\"state\":\"requested\",\"reason\":\"abort signal requested\"},\"limits\":{\"maxChildren\":0,\"depth\":1,\"turns\":1}}",
        .phase = "recorded",
        .owner = "agent",
        .read_only = true,
    } });

    try std.testing.expect(subagent_readiness_observed);
    try std.testing.expect(subagent_readiness_second_observer_called);
}

test "sub-agent readiness envelopes validate identity lineage invocation and result wire shape" {
    const allocator = std.testing.allocator;
    const invocation_json =
        \\{"type":"sub_agent_task_invocation","agentId":"agent-opaque","runId":"run-opaque","taskId":"task-opaque","sessionId":"session-opaque","toolCallId":"tool-call-opaque","parentAgentId":"parent-agent","parentRunId":"parent-run","parentTaskId":"parent-task","parentSessionId":"parent-session","parentId":"parent-record","route":"delegate","input":{"text":"summarize"},"limits":{"maxChildren":0,"depth":1,"turns":3,"timeoutMs":2500,"outputBytes":4096,"outputLines":80,"toolScopes":["read-only"]},"cancellation":{"signalId":"cancel-1","state":"pending","parentRunId":"parent-run","parentTaskId":"parent-task"},"metadata":{"substrateOnly":true}}
    ;
    var invocation = try std.json.parseFromSlice(std.json.Value, allocator, invocation_json, .{});
    defer invocation.deinit();
    var invocation_validation = try validateSubAgentReadinessEnvelope(allocator, invocation.value);
    defer invocation_validation.deinit(allocator);
    try std.testing.expect(invocation_validation == .valid);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_invocation, invocation_validation.valid);

    const result_json =
        \\{"type":"sub_agent_task_result","agentId":"agent-opaque","runId":"run-opaque","taskId":"task-opaque","sessionId":"session-opaque","parentAgentId":"parent-agent","parentRunId":"parent-run","parentTaskId":"parent-task","parentSessionId":"parent-session","status":"completed","content":[{"type":"text","text":"done"}],"details":{"replaySafe":true},"startedAt":10,"completedAt":20,"usage":{"inputTokens":1,"outputTokens":2,"totalTokens":3,"toolCalls":0},"resourceSummary":{"turns":1,"outputBytes":128,"outputLines":2,"childrenStarted":0,"limitDetails":{"outputBytes":{"limit":4096,"actual":5000,"truncated":true,"reason":"output truncated"},"timeoutMs":{"limit":2500,"actual":2500,"truncated":false},"toolScopes":["read-only"]}}}
    ;
    var result = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer result.deinit();
    var result_validation = try validateSubAgentReadinessEnvelope(allocator, result.value);
    defer result_validation.deinit(allocator);
    try std.testing.expect(result_validation == .valid);
    try std.testing.expectEqual(SubAgentReadinessEnvelopeKind.task_result, result_validation.valid);
}

test "sub-agent readiness envelope validation rejects missing ids product fields and invalid result status" {
    const allocator = std.testing.allocator;
    const invalid_cases = [_]struct {
        json: []const u8,
        path: []const u8,
        message: []const u8,
    }{
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{}}",
            .path = "$.agentId",
            .message = "must not be empty",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"sessionId\":\"session\",\"input\":{}}",
            .path = "$.taskId",
            .message = "missing required field",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"spawnPolicy\":{\"automatic\":true}}",
            .path = "$.spawnPolicy",
            .message = "product UX/spawn policy is not allowed",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"complete\",\"startedAt\":1,\"completedAt\":2}",
            .path = "$.status",
            .message = "unsupported task status \"complete\"",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"limits\":{\"toolScopes\":[\"\"]}}",
            .path = "$.limits.toolScopes[0]",
            .message = "must not be empty",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"cancellation\":{\"state\":\"aborted\",\"propagatedFrom\":\"parent-run\"}}",
            .path = "$.cancellation.state",
            .message = "unsupported cancellation state \"aborted\"",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"cancellation\":{\"state\":\"propagated\",\"parentRunId\":\"\"}}",
            .path = "$.cancellation.parentRunId",
            .message = "must not be empty",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{},\"limits\":{\"maxChildren\":-1}}",
            .path = "$.limits.maxChildren",
            .message = "expected non-negative integer",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"resourceSummary\":{\"limitDetails\":{\"outputBytes\":{\"limit\":-1}}}}",
            .path = "$.resourceSummary.limitDetails.outputBytes.limit",
            .message = "expected non-negative number",
        },
        .{
            .json = "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"resourceSummary\":{\"limitDetails\":{\"outputBytes\":{\"limit\":4096,\"actual\":5000}}}}",
            .path = "$.resourceSummary.limitDetails.outputBytes.truncated",
            .message = "missing required field",
        },
    };

    for (invalid_cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.json, .{});
        defer parsed.deinit();
        var validation = try validateSubAgentReadinessEnvelope(allocator, parsed.value);
        defer validation.deinit(allocator);
        try std.testing.expect(validation == .invalid);
        try std.testing.expectEqualStrings(case.path, validation.invalid.path);
        try std.testing.expectEqualStrings(case.message, validation.invalid.message);
    }
}

test "sub-agent readiness envelope validation rejects every forbidden product policy field" {
    const allocator = std.testing.allocator;

    inline for (subagent_forbidden_fields) |field| {
        const invocation_json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"input\":{{}},\"{s}\":{{\"automatic\":true}}}}",
            .{field},
        );
        defer allocator.free(invocation_json);
        var invocation = try std.json.parseFromSlice(std.json.Value, allocator, invocation_json, .{});
        defer invocation.deinit();
        var invocation_validation = try validateSubAgentReadinessEnvelope(allocator, invocation.value);
        defer invocation_validation.deinit(allocator);
        const expected_path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
        defer allocator.free(expected_path);
        try std.testing.expect(invocation_validation == .invalid);
        try std.testing.expectEqualStrings(expected_path, invocation_validation.invalid.path);
        try std.testing.expectEqualStrings("product UX/spawn policy is not allowed", invocation_validation.invalid.message);

        const result_json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent\",\"runId\":\"run\",\"taskId\":\"task\",\"sessionId\":\"session\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"{s}\":{{\"automatic\":true}}}}",
            .{field},
        );
        defer allocator.free(result_json);
        var result = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
        defer result.deinit();
        var result_validation = try validateSubAgentReadinessEnvelope(allocator, result.value);
        defer result_validation.deinit(allocator);
        try std.testing.expect(result_validation == .invalid);
        try std.testing.expectEqualStrings(expected_path, result_validation.invalid.path);
        try std.testing.expectEqualStrings("product UX/spawn policy is not allowed", result_validation.invalid.message);
    }
}

test "extension event surface matches TypeScript parity fixture" {
    const fixture_path = "../packages/coding-agent/test/fixtures/extension-event-surface-names.json";
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, fixture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const fixture_names = parsed.value.array.items;
    const names = eventSurfaceNames();
    try std.testing.expectEqual(names.len, fixture_names.len);

    for (names, fixture_names) |zig_name, fixture_name| {
        try std.testing.expect(fixture_name == .string);
        try std.testing.expectEqualStrings(zig_name, fixture_name.string);
    }
}
