const std = @import("std");
const common = @import("../tools/common.zig");
const extension_registry = @import("extension_registry.zig");

pub const ExecutionState = enum {
    completed,
    failed,
    cancelled,
    timed_out,
    replay_blocked,

    pub fn jsonName(self: ExecutionState) []const u8 {
        return switch (self) {
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
            .timed_out => "timed_out",
            .replay_blocked => "replay_blocked",
        };
    }
};

pub const StepKind = enum {
    deterministic,
    side_effect,
    child_agent,

    pub fn jsonName(self: StepKind) []const u8 {
        return switch (self) {
            .deterministic => "deterministic",
            .side_effect => "side_effect",
            .child_agent => "child_agent",
        };
    }
};

pub const StepReplayMode = enum {
    deterministic,
    recorded,
    stubbed,
    blocked,

    pub fn jsonName(self: StepReplayMode) []const u8 {
        return switch (self) {
            .deterministic => "deterministic",
            .recorded => "recorded",
            .stubbed => "stubbed",
            .blocked => "blocked",
        };
    }
};

pub const Diagnostic = struct {
    code: []u8,
    workflow_id: []u8,
    step_id: ?[]u8 = null,
    path: []u8,
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.workflow_id);
        if (self.step_id) |step_id| allocator.free(step_id);
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ChildAgentLimits = struct {
    max_children: ?u64 = null,
    max_turns: ?u64 = null,
    max_tool_calls: ?u64 = null,
    max_tokens: ?u64 = null,
    timeout_ms: ?u64 = null,
    permission_grants: []const []const u8 = &.{},
    permission_grants_json: ?std.json.Value = null,
    workflow_permissions_json: ?std.json.Value = null,

    pub fn fromJson(value: std.json.Value) ChildAgentLimits {
        if (value != .object) return .{};
        return .{
            .max_children = optionalU64(value.object, "maxChildren"),
            .max_turns = optionalU64(value.object, "maxTurns"),
            .max_tool_calls = optionalU64(value.object, "maxToolCalls"),
            .max_tokens = optionalU64(value.object, "maxTokens"),
            .timeout_ms = optionalU64(value.object, "timeoutMs"),
            .permission_grants_json = value.object.get("permissionGrants") orelse value.object.get("permission_grants"),
        };
    }
};

pub const ChildAgentUsage = struct {
    children_started: u64 = 0,
    turns: u64 = 0,
    tool_calls: u64 = 0,
    tokens: u64 = 0,
    elapsed_ms: u64 = 0,
};

pub const ChildAgentDelta = struct {
    children_started: u64 = 0,
    turns: u64 = 0,
    tool_calls: u64 = 0,
    tokens: u64 = 0,
    elapsed_ms: u64 = 0,
    permission: ?[]const u8 = null,
};

pub const ActiveRuntimeWork = struct {
    started: bool = false,
    cancelled: bool = false,

    pub fn start(self: *ActiveRuntimeWork) void {
        self.started = true;
    }

    pub fn cancel(self: *ActiveRuntimeWork) void {
        self.cancelled = true;
    }
};

pub const WorkflowDescriptor = struct {
    id: []const u8,
    extension_path: []const u8 = "",
    input_schema: std.json.Value,
    output_schema: std.json.Value,
    permissions: std.json.Value = .null,
    timeout_ms: u64 = 30_000,
    child_agent_limits: ChildAgentLimits = .{},
};

pub fn descriptorFromRegistryWorkflow(workflow: extension_registry.ExtensionWorkflow) WorkflowDescriptor {
    var child_agent_limits = ChildAgentLimits.fromJson(workflow.child_agent_limits);
    child_agent_limits.workflow_permissions_json = workflow.permissions;
    return .{
        .id = workflow.id,
        .extension_path = workflow.extension_path,
        .input_schema = workflow.input_schema,
        .output_schema = workflow.output_schema,
        .permissions = workflow.permissions,
        .timeout_ms = workflow.timeout_ms,
        .child_agent_limits = child_agent_limits,
    };
}

pub const StepSpec = struct {
    id: []const u8,
    kind: StepKind = .deterministic,
    input: std.json.Value = .null,
    output: std.json.Value = .null,
    elapsed_ms: u64 = 0,
    replay_mode: StepReplayMode = .deterministic,
    selected_capability: ?[]const u8 = null,
    child_delta: ChildAgentDelta = .{},
    runtime_work: ?*ActiveRuntimeWork = null,
    cancel_after_start: bool = false,
};

pub const RecordedReplayStep = struct {
    step_id: []const u8,
    mode: StepReplayMode,
    output: ?std.json.Value = null,
    order: ?usize = null,
    kind: ?StepKind = null,
    input: ?std.json.Value = null,
    selected_capability_present: bool = false,
    selected_capability: ?[]const u8 = null,
    child_agent_limits: ?ChildAgentLimits = null,
    permissions: ?std.json.Value = null,
};

pub const CapabilityDispatchFn = *const fn (
    allocator: std.mem.Allocator,
    capability_id: []const u8,
    input: std.json.Value,
    context: ?*anyopaque,
) anyerror!std.json.Value;

pub const ExecutionOptions = struct {
    cancel_signal: ?*const std.atomic.Value(bool) = null,
    replay: bool = false,
    recorded_steps: []const RecordedReplayStep = &.{},
    recorded_terminal_state: ?ExecutionState = null,
    recorded_permissions: ?std.json.Value = null,
    recorded_child_agent_limits: ?ChildAgentLimits = null,
    capability_dispatch: ?CapabilityDispatchFn = null,
    capability_dispatch_context: ?*anyopaque = null,
};

pub const ReplayStepMetadata = struct {
    step_id: []u8,
    order: usize,
    kind: []u8,
    mode: []u8,
    state: []u8,
    input: std.json.Value,
    side_effect: bool,
    selected_capability: ?[]u8,

    pub fn deinit(self: *ReplayStepMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.step_id);
        allocator.free(self.kind);
        allocator.free(self.mode);
        allocator.free(self.state);
        common.deinitJsonValue(allocator, self.input);
        if (self.selected_capability) |capability| allocator.free(capability);
        self.* = undefined;
    }
};

pub const ReplayMetadata = struct {
    workflow_id: []u8,
    terminal_state: ExecutionState,
    permissions: std.json.Value,
    child_agent_limits: ChildAgentLimits,
    cancellation_point: ?[]u8 = null,
    steps: std.ArrayList(ReplayStepMetadata) = .empty,

    pub fn init(allocator: std.mem.Allocator, descriptor: WorkflowDescriptor) !ReplayMetadata {
        const permissions = try common.cloneJsonValue(allocator, descriptor.permissions);
        var child_agent_limits = descriptor.child_agent_limits;
        child_agent_limits.workflow_permissions_json = permissions;
        if (descriptor.child_agent_limits.permission_grants_json) |grants| {
            child_agent_limits.permission_grants_json = try common.cloneJsonValue(allocator, grants);
        }
        return .{
            .workflow_id = try allocator.dupe(u8, descriptor.id),
            .terminal_state = .completed,
            .permissions = permissions,
            .child_agent_limits = child_agent_limits,
        };
    }

    pub fn deinit(self: *ReplayMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.workflow_id);
        common.deinitJsonValue(allocator, self.permissions);
        if (self.child_agent_limits.permission_grants_json) |grants| common.deinitJsonValue(allocator, grants);
        if (self.cancellation_point) |point| allocator.free(point);
        for (self.steps.items) |*step| step.deinit(allocator);
        self.steps.deinit(allocator);
        self.* = undefined;
    }
};

pub const ExecutionResult = struct {
    state: ExecutionState,
    output: ?std.json.Value = null,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    replay_metadata: ReplayMetadata,
    child_usage: ChildAgentUsage = .{},

    pub fn init(allocator: std.mem.Allocator, descriptor: WorkflowDescriptor) !ExecutionResult {
        return .{
            .state = .completed,
            .replay_metadata = try ReplayMetadata.init(allocator, descriptor),
        };
    }

    pub fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        if (self.output) |output| common.deinitJsonValue(allocator, output);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
        self.diagnostics.deinit(allocator);
        self.replay_metadata.deinit(allocator);
        self.* = undefined;
    }
};

const SchemaValidationFailure = struct {
    path: []u8,
    message: []u8,

    fn deinit(self: *SchemaValidationFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn executeWorkflow(
    allocator: std.mem.Allocator,
    descriptor: WorkflowDescriptor,
    input: std.json.Value,
    steps: []const StepSpec,
    options: ExecutionOptions,
) !ExecutionResult {
    var result = try ExecutionResult.init(allocator, descriptor);
    errdefer result.deinit(allocator);

    if (try validateWorkflowInputJsonSchema(allocator, descriptor.input_schema, input, "$", options.replay)) |failure| {
        var owned_failure = failure;
        defer owned_failure.deinit(allocator);
        result.state = .failed;
        result.replay_metadata.terminal_state = result.state;
        try appendDiagnostic(
            allocator,
            &result,
            "workflow.input_schema_invalid",
            descriptor.id,
            null,
            owned_failure.path,
            owned_failure.message,
        );
        return result;
    }

    if (options.replay) {
        if (try replayDescriptorMetadataMismatch(allocator, descriptor, &result, options)) return result;
        if (try replayRecordedStepsMismatch(allocator, descriptor, &result, steps, options)) return result;
    }

    var elapsed_ms: u64 = 0;
    var last_output: ?std.json.Value = null;
    errdefer if (last_output) |output| common.deinitJsonValue(allocator, output);

    for (steps, 0..) |step, step_index| {
        if (isCancelRequested(options.cancel_signal)) {
            try cancelActiveStep(allocator, descriptor.id, &result, step, step_index);
            break;
        }

        if (elapsed_ms + step.elapsed_ms > descriptor.timeout_ms) {
            if (step.runtime_work) |runtime_work| runtime_work.cancel();
            result.state = .timed_out;
            try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .timed_out, step.replay_mode);
            const message = try std.fmt.allocPrint(
                allocator,
                "workflow exceeded declared timeout: limit={d}ms elapsed={d}ms",
                .{ descriptor.timeout_ms, elapsed_ms + step.elapsed_ms },
            );
            defer allocator.free(message);
            try appendDiagnostic(allocator, &result, "workflow.timeout", descriptor.id, step.id, "$.timeoutMs", message);
            break;
        }

        if (step.runtime_work) |runtime_work| runtime_work.start();

        if (step.cancel_after_start or isCancelRequested(options.cancel_signal)) {
            try cancelActiveStep(allocator, descriptor.id, &result, step, step_index);
            break;
        }

        if (options.replay) {
            const recorded = findRecordedStep(options.recorded_steps, step.id);
            if (recorded) |recorded_step| {
                if (try replayMetadataMismatch(allocator, descriptor, &result, step, step_index, recorded_step)) break;
            } else if (options.recorded_steps.len > 0) {
                result.state = .replay_blocked;
                try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .replay_blocked, step.replay_mode);
                try appendDiagnostic(allocator, &result, "workflow.replay_metadata_mismatch", descriptor.id, step.id, "$.replay.steps", "recorded replay metadata is missing current workflow step");
                break;
            }
            if (isSideEffectStep(step)) {
                switch (step.replay_mode) {
                    .recorded => {
                        if (recorded) |recorded_step| {
                            if (recorded_step.mode != .recorded) {
                                result.state = .replay_blocked;
                                try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .replay_blocked, .recorded);
                                try appendDiagnostic(allocator, &result, "workflow.replay_metadata_mismatch", descriptor.id, step.id, "$.replay.steps[].mode", "recorded replay metadata mode does not match selected side-effect policy");
                                break;
                            }
                            try replaceLastOutput(allocator, &last_output, recorded_step.output orelse .null);
                            try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .completed, .recorded);
                            continue;
                        }
                        result.state = .replay_blocked;
                        try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .replay_blocked, .recorded);
                        try appendDiagnostic(allocator, &result, "workflow.replay_missing_record", descriptor.id, step.id, "$.replay", "recorded side effect is missing replay metadata");
                        break;
                    },
                    .stubbed => {
                        if (recorded) |recorded_step| {
                            if (recorded_step.mode != .stubbed) {
                                result.state = .replay_blocked;
                                try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .replay_blocked, .stubbed);
                                try appendDiagnostic(allocator, &result, "workflow.replay_metadata_mismatch", descriptor.id, step.id, "$.replay.steps[].mode", "stub replay metadata mode does not match selected side-effect policy");
                                break;
                            }
                        }
                        const stub_output = if (recorded) |recorded_step| recorded_step.output orelse .null else .null;
                        try replaceLastOutput(allocator, &last_output, stub_output);
                        try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .completed, .stubbed);
                        continue;
                    },
                    .blocked => {
                        result.state = .replay_blocked;
                        try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .replay_blocked, .blocked);
                        try appendDiagnostic(allocator, &result, "workflow.replay_side_effect_blocked", descriptor.id, step.id, "$.replay", "non-replayable side effect blocked during replay");
                        break;
                    },
                    .deterministic => {},
                }
            }
        }

        if (step.kind == .child_agent) {
            if (childLimitExceeded(descriptor.child_agent_limits, result.child_usage, step.child_delta)) |reason| {
                result.state = .failed;
                try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .failed, step.replay_mode);
                try appendDiagnostic(allocator, &result, "workflow.child_agent_limit_exceeded", descriptor.id, step.id, "$.childAgentLimits", reason);
                break;
            }
            applyChildDelta(&result.child_usage, step.child_delta);
        }

        var dispatched_output: ?std.json.Value = null;
        defer if (dispatched_output) |output| common.deinitJsonValue(allocator, output);
        if (step.kind != .child_agent) {
            if (step.selected_capability) |capability_id| {
                if (options.capability_dispatch) |dispatch| {
                    dispatched_output = dispatch(
                        allocator,
                        capability_id,
                        step.input,
                        options.capability_dispatch_context,
                    ) catch |err| {
                        result.state = .failed;
                        try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .failed, step.replay_mode);
                        const message = try std.fmt.allocPrint(
                            allocator,
                            "workflow capability dispatch failed for {s}: {s}",
                            .{ capability_id, @errorName(err) },
                        );
                        defer allocator.free(message);
                        try appendDiagnostic(allocator, &result, "workflow.capability_dispatch_failed", descriptor.id, step.id, "$.steps[].selectedCapability", message);
                        break;
                    };
                }
            }
        }

        elapsed_ms += step.elapsed_ms;
        try replaceLastOutput(allocator, &last_output, dispatched_output orelse step.output);
        try appendReplayStep(allocator, &result.replay_metadata, step, step_index, .completed, step.replay_mode);
    }

    if (result.state == .completed) {
        const output = last_output orelse .null;
        if (try validateJsonSchema(allocator, descriptor.output_schema, output, "$")) |failure| {
            var owned_failure = failure;
            defer owned_failure.deinit(allocator);
            result.state = .failed;
            try appendDiagnostic(
                allocator,
                &result,
                "workflow.output_schema_invalid",
                descriptor.id,
                null,
                owned_failure.path,
                owned_failure.message,
            );
        }
    }

    if (last_output) |output| {
        result.output = output;
        last_output = null;
    }
    result.replay_metadata.terminal_state = result.state;
    if (options.replay) {
        if (options.recorded_terminal_state) |recorded_state| {
            if (recorded_state != result.state) {
                result.state = .replay_blocked;
                result.replay_metadata.terminal_state = result.state;
                try appendDiagnostic(allocator, &result, "workflow.replay_metadata_mismatch", descriptor.id, null, "$.replay.terminalState", "recorded workflow terminal state does not match current replay result");
            }
        }
    }
    return result;
}

fn validateWorkflowInputJsonSchema(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: []const u8,
    allow_reserved_replay_metadata: bool,
) !?SchemaValidationFailure {
    return try validateJsonSchemaInternal(allocator, schema, value, path, allow_reserved_replay_metadata);
}

fn validateJsonSchema(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: []const u8,
) !?SchemaValidationFailure {
    return try validateJsonSchemaInternal(allocator, schema, value, path, false);
}

fn validateJsonSchemaInternal(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: []const u8,
    allow_reserved_replay_metadata: bool,
) !?SchemaValidationFailure {
    if (schema != .object) return null;
    const type_value = schema.object.get("type") orelse return null;
    if (type_value != .string) return null;
    const type_name = type_value.string;

    if (std.mem.eql(u8, type_name, "object")) {
        if (value != .object) return try schemaFailure(allocator, path, "expected object");
        if (schema.object.get("required")) |required| {
            if (required == .array) {
                for (required.array.items) |item| {
                    if (item == .string and !value.object.contains(item.string)) {
                        const child_path = try joinJsonPath(allocator, path, item.string);
                        defer allocator.free(child_path);
                        return try schemaFailure(allocator, child_path, "missing required field");
                    }
                }
            }
        }
        const properties = schema.object.get("properties") orelse return null;
        if (properties != .object) return null;
        var property_iterator = properties.object.iterator();
        while (property_iterator.next()) |entry| {
            if (value.object.get(entry.key_ptr.*)) |property_value| {
                const child_path = try joinJsonPath(allocator, path, entry.key_ptr.*);
                defer allocator.free(child_path);
                if (try validateJsonSchemaInternal(allocator, entry.value_ptr.*, property_value, child_path, allow_reserved_replay_metadata)) |failure| return failure;
            }
        }
        if (schema.object.get("additionalProperties")) |additional_properties| {
            if (additional_properties == .bool and !additional_properties.bool) {
                var value_iterator = value.object.iterator();
                while (value_iterator.next()) |entry| {
                    if (!properties.object.contains(entry.key_ptr.*)) {
                        if (allow_reserved_replay_metadata and std.mem.eql(u8, path, "$") and isReservedReplayMetadataField(entry.key_ptr.*)) continue;
                        const child_path = try joinJsonPath(allocator, path, entry.key_ptr.*);
                        defer allocator.free(child_path);
                        return try schemaFailure(allocator, child_path, "unexpected additional property");
                    }
                }
            }
        }
        return null;
    }
    if (std.mem.eql(u8, type_name, "string") and value != .string) return try schemaFailure(allocator, path, "expected string");
    if (std.mem.eql(u8, type_name, "boolean") and value != .bool) return try schemaFailure(allocator, path, "expected boolean");
    if (std.mem.eql(u8, type_name, "integer") and value != .integer) return try schemaFailure(allocator, path, "expected integer");
    if (std.mem.eql(u8, type_name, "number") and value != .integer and value != .float and value != .number_string) return try schemaFailure(allocator, path, "expected number");
    if (std.mem.eql(u8, type_name, "array")) {
        if (value != .array) return try schemaFailure(allocator, path, "expected array");
        if (schema.object.get("items")) |items_schema| {
            for (value.array.items, 0..) |item, index| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                defer allocator.free(child_path);
                if (try validateJsonSchemaInternal(allocator, items_schema, item, child_path, allow_reserved_replay_metadata)) |failure| return failure;
            }
        }
    }
    return null;
}

fn isReservedReplayMetadataField(field: []const u8) bool {
    return std.mem.eql(u8, field, "__workflowReplay") or
        std.mem.eql(u8, field, "workflowReplay") or
        std.mem.eql(u8, field, "__workflowReplayMetadata") or
        std.mem.eql(u8, field, "workflowReplayMetadata") or
        std.mem.eql(u8, field, "replayMetadata") or
        std.mem.eql(u8, field, "replay_metadata");
}

fn schemaFailure(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !SchemaValidationFailure {
    return .{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    };
}

fn joinJsonPath(allocator: std.mem.Allocator, base: []const u8, field: []const u8) ![]u8 {
    if (std.mem.eql(u8, base, "$")) return std.fmt.allocPrint(allocator, "$.{s}", .{field});
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, field });
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    code: []const u8,
    workflow_id: []const u8,
    step_id: ?[]const u8,
    path: []const u8,
    message: []const u8,
) !void {
    try result.diagnostics.append(allocator, .{
        .code = try allocator.dupe(u8, code),
        .workflow_id = try allocator.dupe(u8, workflow_id),
        .step_id = if (step_id) |id| try allocator.dupe(u8, id) else null,
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    });
}

fn appendReplayStep(
    allocator: std.mem.Allocator,
    metadata: *ReplayMetadata,
    step: StepSpec,
    order: usize,
    state: ExecutionState,
    mode: StepReplayMode,
) !void {
    try metadata.steps.append(allocator, .{
        .step_id = try allocator.dupe(u8, step.id),
        .order = order,
        .kind = try allocator.dupe(u8, step.kind.jsonName()),
        .mode = try allocator.dupe(u8, mode.jsonName()),
        .state = try allocator.dupe(u8, state.jsonName()),
        .input = try common.cloneJsonValue(allocator, step.input),
        .side_effect = isSideEffectStep(step),
        .selected_capability = if (step.selected_capability) |capability| try allocator.dupe(u8, capability) else null,
    });
}

fn replayMetadataMismatch(
    allocator: std.mem.Allocator,
    descriptor: WorkflowDescriptor,
    result: *ExecutionResult,
    step: StepSpec,
    order: usize,
    recorded: RecordedReplayStep,
) !bool {
    if (recorded.order) |recorded_order| {
        if (recorded_order != order) {
            try blockReplayForMetadataMismatch(allocator, descriptor.id, result, step, order, "$.replay.steps[].order", "recorded step order does not match current workflow step order");
            return true;
        }
    }
    if (recorded.kind) |recorded_kind| {
        if (recorded_kind != step.kind) {
            try blockReplayForMetadataMismatch(allocator, descriptor.id, result, step, order, "$.replay.steps[].kind", "recorded step kind does not match current workflow step kind");
            return true;
        }
    }
    if (recorded.input) |recorded_input| {
        if (!jsonValueEql(recorded_input, step.input)) {
            try blockReplayForMetadataMismatch(allocator, descriptor.id, result, step, order, "$.replay.steps[].input", "recorded step input does not match current workflow step input");
            return true;
        }
    }
    if (recorded.selected_capability_present) {
        if (!optionalStringEql(recorded.selected_capability, step.selected_capability)) {
            try blockReplayForMetadataMismatch(allocator, descriptor.id, result, step, order, "$.replay.steps[].selectedCapability", "recorded capability selection does not match current workflow step capability");
            return true;
        }
    }
    if (recorded.child_agent_limits) |recorded_limits| {
        if (!childAgentLimitsEql(recorded_limits, descriptor.child_agent_limits)) {
            try blockReplayForMetadataMismatch(allocator, descriptor.id, result, step, order, "$.replay.childAgentLimits", "recorded child-agent bounds do not match current workflow bounds");
            return true;
        }
    }
    if (recorded.permissions) |recorded_permissions| {
        if (!jsonValueEql(recorded_permissions, descriptor.permissions)) {
            try blockReplayForMetadataMismatch(allocator, descriptor.id, result, step, order, "$.replay.permissions", "recorded workflow permissions do not match current workflow permissions");
            return true;
        }
    }
    return false;
}

fn replayDescriptorMetadataMismatch(
    allocator: std.mem.Allocator,
    descriptor: WorkflowDescriptor,
    result: *ExecutionResult,
    options: ExecutionOptions,
) !bool {
    if (options.recorded_permissions) |recorded_permissions| {
        if (!jsonValueEql(recorded_permissions, descriptor.permissions)) {
            result.state = .replay_blocked;
            result.replay_metadata.terminal_state = result.state;
            try appendDiagnostic(allocator, result, "workflow.replay_metadata_mismatch", descriptor.id, null, "$.replay.permissions", "recorded workflow permissions do not match current workflow permissions");
            return true;
        }
    }
    if (options.recorded_child_agent_limits) |recorded_limits| {
        if (!childAgentLimitsEql(recorded_limits, descriptor.child_agent_limits)) {
            result.state = .replay_blocked;
            result.replay_metadata.terminal_state = result.state;
            try appendDiagnostic(allocator, result, "workflow.replay_metadata_mismatch", descriptor.id, null, "$.replay.childAgentLimits", "recorded child-agent bounds do not match current workflow bounds");
            return true;
        }
    }
    return false;
}

fn replayRecordedStepsMismatch(
    allocator: std.mem.Allocator,
    descriptor: WorkflowDescriptor,
    result: *ExecutionResult,
    steps: []const StepSpec,
    options: ExecutionOptions,
) !bool {
    if (!options.replay or options.recorded_steps.len == 0) return false;
    for (options.recorded_steps) |recorded| {
        if (findCurrentStep(steps, recorded.step_id)) continue;
        result.state = .replay_blocked;
        result.replay_metadata.terminal_state = result.state;
        try appendDiagnostic(
            allocator,
            result,
            "workflow.replay_metadata_mismatch",
            descriptor.id,
            recorded.step_id,
            "$.replay.steps",
            "recorded replay metadata contains a step that is not present in the current workflow",
        );
        return true;
    }
    return false;
}

fn blockReplayForMetadataMismatch(
    allocator: std.mem.Allocator,
    workflow_id: []const u8,
    result: *ExecutionResult,
    step: StepSpec,
    order: usize,
    path: []const u8,
    message: []const u8,
) !void {
    result.state = .replay_blocked;
    try appendReplayStep(allocator, &result.replay_metadata, step, order, .replay_blocked, step.replay_mode);
    try appendDiagnostic(allocator, result, "workflow.replay_metadata_mismatch", workflow_id, step.id, path, message);
}

fn replaceLastOutput(allocator: std.mem.Allocator, last_output: *?std.json.Value, output: std.json.Value) !void {
    if (last_output.*) |old| common.deinitJsonValue(allocator, old);
    last_output.* = try common.cloneJsonValue(allocator, output);
}

fn isCancelRequested(signal: ?*const std.atomic.Value(bool)) bool {
    const value = signal orelse return false;
    return value.load(.seq_cst);
}

fn cancelActiveStep(allocator: std.mem.Allocator, workflow_id: []const u8, result: *ExecutionResult, step: StepSpec, order: usize) !void {
    if (step.runtime_work) |runtime_work| runtime_work.cancel();
    result.state = .cancelled;
    if (result.replay_metadata.cancellation_point == null) {
        result.replay_metadata.cancellation_point = try allocator.dupe(u8, step.id);
    }
    try appendReplayStep(allocator, &result.replay_metadata, step, order, .cancelled, step.replay_mode);
    try appendDiagnostic(allocator, result, "workflow.cancelled", workflow_id, step.id, "$.cancellation", "workflow cancellation propagated to active runtime work");
}

fn isSideEffectStep(step: StepSpec) bool {
    return step.kind == .side_effect or step.kind == .child_agent;
}

fn findRecordedStep(steps: []const RecordedReplayStep, step_id: []const u8) ?RecordedReplayStep {
    for (steps) |step| {
        if (std.mem.eql(u8, step.step_id, step_id)) return step;
    }
    return null;
}

fn findCurrentStep(steps: []const StepSpec, step_id: []const u8) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step.id, step_id)) return true;
    }
    return false;
}

fn childLimitExceeded(limits: ChildAgentLimits, usage: ChildAgentUsage, delta: ChildAgentDelta) ?[]const u8 {
    if (limits.max_children) |limit| {
        if (usage.children_started + delta.children_started > limit) return "maxChildren exceeded";
    }
    if (limits.max_turns) |limit| {
        if (usage.turns + delta.turns > limit) return "maxTurns exceeded";
    }
    if (limits.max_tool_calls) |limit| {
        if (usage.tool_calls + delta.tool_calls > limit) return "maxToolCalls exceeded";
    }
    if (limits.max_tokens) |limit| {
        if (usage.tokens + delta.tokens > limit) return "maxTokens exceeded";
    }
    if (limits.timeout_ms) |limit| {
        if (usage.elapsed_ms + delta.elapsed_ms > limit) return "timeoutMs exceeded";
    }
    if (delta.permission) |permission| {
        if (!containsString(limits.permission_grants, permission) and
            !permissionJsonAllows(limits.permission_grants_json, permission) and
            !permissionJsonAllows(limits.workflow_permissions_json, permission)) return "permission grant not allowed";
    }
    return null;
}

fn applyChildDelta(usage: *ChildAgentUsage, delta: ChildAgentDelta) void {
    usage.children_started += delta.children_started;
    usage.turns += delta.turns;
    usage.tool_calls += delta.tool_calls;
    usage.tokens += delta.tokens;
    usage.elapsed_ms += delta.elapsed_ms;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn permissionJsonAllows(value: ?std.json.Value, permission: []const u8) bool {
    const permissions = value orelse return false;
    return permissionValueAllows(permissions, permission);
}

fn permissionValueAllows(value: std.json.Value, permission: []const u8) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, permission),
        .object => |object| blk: {
            if (permissionPolicyDenied(object)) break :blk false;
            const id = jsonObjectString(object, "id") orelse jsonObjectString(object, "grant") orelse jsonObjectString(object, "permission") orelse break :blk false;
            break :blk std.mem.eql(u8, id, permission);
        },
        .array => |array| blk: {
            for (array.items) |item| {
                if (permissionValueAllows(item, permission)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn permissionPolicyDenied(object: std.json.ObjectMap) bool {
    if (jsonObjectBool(object, "denied") orelse false) return true;
    if (jsonObjectBool(object, "policyDenied") orelse false) return true;
    const policy = object.get("policy") orelse return false;
    if (policy != .object) return false;
    if (policy.object.get("approved")) |approved| {
        if (approved == .bool and !approved.bool) return true;
    }
    if (policy.object.get("decision")) |decision| {
        if (decision == .string and (std.mem.eql(u8, decision.string, "deny") or std.mem.eql(u8, decision.string, "denied"))) return true;
    }
    return false;
}

fn jsonObjectString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonObjectBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn childAgentLimitsEql(left: ChildAgentLimits, right: ChildAgentLimits) bool {
    if (left.max_children != right.max_children) return false;
    if (left.max_turns != right.max_turns) return false;
    if (left.max_tool_calls != right.max_tool_calls) return false;
    if (left.max_tokens != right.max_tokens) return false;
    if (left.timeout_ms != right.timeout_ms) return false;
    if (left.permission_grants.len != right.permission_grants.len) return false;
    for (left.permission_grants, 0..) |grant, index| {
        if (!std.mem.eql(u8, grant, right.permission_grants[index])) return false;
    }
    if (left.permission_grants_json) |left_json| {
        const right_json = right.permission_grants_json orelse return false;
        if (!jsonValueEql(left_json, right_json)) return false;
    } else if (right.permission_grants_json != null) {
        return false;
    }
    return true;
}

fn jsonValueEql(left: std.json.Value, right: std.json.Value) bool {
    return switch (left) {
        .null => right == .null,
        .bool => |left_bool| right == .bool and right.bool == left_bool,
        .integer => |left_int| right == .integer and right.integer == left_int,
        .float => |left_float| right == .float and right.float == left_float,
        .number_string => |left_number| right == .number_string and std.mem.eql(u8, left_number, right.number_string),
        .string => |left_string| right == .string and std.mem.eql(u8, left_string, right.string),
        .array => |left_array| blk: {
            if (right != .array or left_array.items.len != right.array.items.len) break :blk false;
            for (left_array.items, 0..) |item, index| {
                if (!jsonValueEql(item, right.array.items[index])) break :blk false;
            }
            break :blk true;
        },
        .object => |left_object| blk: {
            if (right != .object or left_object.count() != right.object.count()) break :blk false;
            var iterator = left_object.iterator();
            while (iterator.next()) |entry| {
                const right_value = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEql(entry.value_ptr.*, right_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn optionalU64(object: std.json.ObjectMap, field: []const u8) ?u64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn parseJson(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
}

test "workflow execution rejects invalid input before side effects and diagnoses invalid output" {
    const allocator = std.testing.allocator;
    var input_schema = try parseJson(allocator, "{\"type\":\"object\",\"properties\":{\"issue\":{\"type\":\"string\"}},\"required\":[\"issue\"],\"additionalProperties\":false}");
    defer input_schema.deinit();
    var output_schema = try parseJson(allocator, "{\"type\":\"object\",\"properties\":{\"summary\":{\"type\":\"string\"}},\"required\":[\"summary\"]}");
    defer output_schema.deinit();
    var invalid_input = try parseJson(allocator, "{\"extra\":true}");
    defer invalid_input.deinit();
    var invalid_output = try parseJson(allocator, "{\"summary\":42}");
    defer invalid_output.deinit();

    const descriptor = WorkflowDescriptor{
        .id = "triage",
        .input_schema = input_schema.value,
        .output_schema = output_schema.value,
    };
    var side_effect = ActiveRuntimeWork{};
    const invalid_input_steps = [_]StepSpec{.{
        .id = "side-effect",
        .kind = .side_effect,
        .output = invalid_output.value,
        .runtime_work = &side_effect,
    }};
    var invalid_input_result = try executeWorkflow(allocator, descriptor, invalid_input.value, &invalid_input_steps, .{});
    defer invalid_input_result.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.failed, invalid_input_result.state);
    try std.testing.expect(!side_effect.started);
    try std.testing.expectEqualStrings("workflow.input_schema_invalid", invalid_input_result.diagnostics.items[0].code);
    try std.testing.expectEqualStrings("$.issue", invalid_input_result.diagnostics.items[0].path);

    var valid_input = try parseJson(allocator, "{\"issue\":\"bug\"}");
    defer valid_input.deinit();
    const invalid_output_steps = [_]StepSpec{.{ .id = "produce", .output = invalid_output.value }};
    var invalid_output_result = try executeWorkflow(allocator, descriptor, valid_input.value, &invalid_output_steps, .{});
    defer invalid_output_result.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.failed, invalid_output_result.state);
    try std.testing.expectEqualStrings("workflow.output_schema_invalid", invalid_output_result.diagnostics.items[0].code);
    try std.testing.expectEqualStrings("$.summary", invalid_output_result.diagnostics.items[0].path);
}

test "workflow cancellation propagates to active runtime work and records cancellation point" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator, "{\"type\":\"object\"}");
    defer schema.deinit();
    var input = try parseJson(allocator, "{}");
    defer input.deinit();
    var output = try parseJson(allocator, "{}");
    defer output.deinit();

    const descriptor = WorkflowDescriptor{
        .id = "cancel-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
    };
    var runtime_work = ActiveRuntimeWork{};
    const steps = [_]StepSpec{
        .{ .id = "active", .output = output.value, .runtime_work = &runtime_work, .cancel_after_start = true },
        .{ .id = "after-cancel", .output = output.value },
    };
    var result = try executeWorkflow(allocator, descriptor, input.value, &steps, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.cancelled, result.state);
    try std.testing.expect(runtime_work.started);
    try std.testing.expect(runtime_work.cancelled);
    try std.testing.expectEqual(@as(usize, 1), result.replay_metadata.steps.items.len);
    try std.testing.expectEqualStrings("active", result.replay_metadata.cancellation_point.?);
    try std.testing.expectEqualStrings("workflow.cancelled", result.diagnostics.items[0].code);
}

test "workflow timeout enforces declared limits and cancels active runtime work" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator, "{\"type\":\"object\"}");
    defer schema.deinit();
    var input = try parseJson(allocator, "{}");
    defer input.deinit();
    var output = try parseJson(allocator, "{}");
    defer output.deinit();

    const descriptor = WorkflowDescriptor{
        .id = "timeout-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
        .timeout_ms = 50,
    };
    var runtime_work = ActiveRuntimeWork{};
    const steps = [_]StepSpec{
        .{ .id = "fast", .output = output.value, .elapsed_ms = 30 },
        .{ .id = "slow", .output = output.value, .elapsed_ms = 25, .runtime_work = &runtime_work },
    };
    var result = try executeWorkflow(allocator, descriptor, input.value, &steps, .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.timed_out, result.state);
    try std.testing.expect(runtime_work.cancelled);
    try std.testing.expectEqualStrings("workflow.timeout", result.diagnostics.items[0].code);
    try std.testing.expectEqualStrings("slow", result.replay_metadata.steps.items[1].step_id);
}

test "workflow replay uses recorded metadata and blocks non replayable side effects" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator, "{\"type\":\"object\"}");
    defer schema.deinit();
    var input = try parseJson(allocator, "{}");
    defer input.deinit();
    var original_output = try parseJson(allocator, "{\"value\":\"original\"}");
    defer original_output.deinit();
    var mutated_output = try parseJson(allocator, "{\"value\":\"mutated\"}");
    defer mutated_output.deinit();
    var stub_output = try parseJson(allocator, "{\"value\":\"stubbed\"}");
    defer stub_output.deinit();
    var step_input = try parseJson(allocator, "{\"query\":\"issue\"}");
    defer step_input.deinit();
    var changed_input = try parseJson(allocator, "{\"query\":\"changed\"}");
    defer changed_input.deinit();
    var recorded_permissions = try parseJson(allocator, "[\"agent.delegate\"]");
    defer recorded_permissions.deinit();
    var changed_permissions = try parseJson(allocator, "[\"agent.spawn\"]");
    defer changed_permissions.deinit();

    const descriptor = WorkflowDescriptor{
        .id = "replay-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
        .permissions = recorded_permissions.value,
    };
    const replay_steps = [_]StepSpec{
        .{ .id = "provider-call", .kind = .side_effect, .input = step_input.value, .output = mutated_output.value, .replay_mode = .recorded, .selected_capability = "provider.demo" },
        .{ .id = "resource-write", .kind = .side_effect, .output = mutated_output.value, .replay_mode = .stubbed, .selected_capability = "resource.write" },
    };
    const recorded = [_]RecordedReplayStep{
        .{ .step_id = "provider-call", .mode = .recorded, .output = original_output.value, .order = 0, .kind = .side_effect, .input = step_input.value, .selected_capability_present = true, .selected_capability = "provider.demo", .permissions = recorded_permissions.value },
        .{ .step_id = "resource-write", .mode = .stubbed, .output = stub_output.value },
    };
    var replayed = try executeWorkflow(allocator, descriptor, input.value, &replay_steps, .{ .replay = true, .recorded_steps = &recorded });
    defer replayed.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.completed, replayed.state);
    try std.testing.expectEqual(@as(usize, 0), replayed.replay_metadata.steps.items[0].order);
    try std.testing.expectEqualStrings("side_effect", replayed.replay_metadata.steps.items[0].kind);
    try std.testing.expectEqualStrings("issue", replayed.replay_metadata.steps.items[0].input.object.get("query").?.string);
    try std.testing.expectEqualStrings("recorded", replayed.replay_metadata.steps.items[0].mode);
    try std.testing.expect(replayed.replay_metadata.steps.items[0].side_effect);
    try std.testing.expectEqualStrings("provider.demo", replayed.replay_metadata.steps.items[0].selected_capability.?);
    try std.testing.expectEqualStrings("stubbed", replayed.replay_metadata.steps.items[1].mode);
    try std.testing.expectEqualStrings("stubbed", replayed.output.?.object.get("value").?.string);

    const blocked_steps = [_]StepSpec{.{ .id = "shell", .kind = .side_effect, .replay_mode = .blocked, .selected_capability = "shell.run" }};
    var blocked = try executeWorkflow(allocator, descriptor, input.value, &blocked_steps, .{ .replay = true });
    defer blocked.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, blocked.state);
    try std.testing.expectEqualStrings("workflow.replay_side_effect_blocked", blocked.diagnostics.items[0].code);

    const mismatched_recorded = [_]RecordedReplayStep{.{ .step_id = "provider-call", .mode = .stubbed, .output = original_output.value }};
    const mismatch_steps = [_]StepSpec{.{ .id = "provider-call", .kind = .side_effect, .replay_mode = .recorded }};
    var mismatch = try executeWorkflow(allocator, descriptor, input.value, &mismatch_steps, .{ .replay = true, .recorded_steps = &mismatched_recorded });
    defer mismatch.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, mismatch.state);
    try std.testing.expectEqualStrings("workflow.replay_metadata_mismatch", mismatch.diagnostics.items[0].code);

    const input_mismatch_recorded = [_]RecordedReplayStep{.{ .step_id = "provider-call", .mode = .recorded, .input = step_input.value, .output = original_output.value }};
    const input_mismatch_steps = [_]StepSpec{.{ .id = "provider-call", .kind = .side_effect, .input = changed_input.value, .replay_mode = .recorded }};
    var input_mismatch = try executeWorkflow(allocator, descriptor, input.value, &input_mismatch_steps, .{ .replay = true, .recorded_steps = &input_mismatch_recorded });
    defer input_mismatch.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, input_mismatch.state);
    try std.testing.expectEqualStrings("$.replay.steps[].input", input_mismatch.diagnostics.items[0].path);

    const capability_mismatch_recorded = [_]RecordedReplayStep{.{ .step_id = "provider-call", .mode = .recorded, .selected_capability_present = true, .selected_capability = "provider.original", .output = original_output.value }};
    const capability_mismatch_steps = [_]StepSpec{.{ .id = "provider-call", .kind = .side_effect, .replay_mode = .recorded, .selected_capability = "provider.changed" }};
    var capability_mismatch = try executeWorkflow(allocator, descriptor, input.value, &capability_mismatch_steps, .{ .replay = true, .recorded_steps = &capability_mismatch_recorded });
    defer capability_mismatch.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, capability_mismatch.state);
    try std.testing.expectEqualStrings("$.replay.steps[].selectedCapability", capability_mismatch.diagnostics.items[0].path);

    const bounds_mismatch_recorded = [_]RecordedReplayStep{.{ .step_id = "delegate", .mode = .recorded, .kind = .child_agent, .child_agent_limits = .{ .max_children = 1 }, .output = original_output.value }};
    const bounds_mismatch_steps = [_]StepSpec{.{ .id = "delegate", .kind = .child_agent, .replay_mode = .recorded, .child_delta = .{ .children_started = 1 } }};
    const changed_bounds_descriptor = WorkflowDescriptor{
        .id = "replay-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
        .permissions = recorded_permissions.value,
        .child_agent_limits = .{ .max_children = 2 },
    };
    var bounds_mismatch = try executeWorkflow(allocator, changed_bounds_descriptor, input.value, &bounds_mismatch_steps, .{ .replay = true, .recorded_steps = &bounds_mismatch_recorded });
    defer bounds_mismatch.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, bounds_mismatch.state);
    try std.testing.expectEqualStrings("$.replay.childAgentLimits", bounds_mismatch.diagnostics.items[0].path);

    const permissions_mismatch_recorded = [_]RecordedReplayStep{.{ .step_id = "delegate", .mode = .recorded, .permissions = recorded_permissions.value, .output = original_output.value }};
    const permissions_mismatch_descriptor = WorkflowDescriptor{
        .id = "replay-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
        .permissions = changed_permissions.value,
    };
    var permissions_mismatch = try executeWorkflow(allocator, permissions_mismatch_descriptor, input.value, &bounds_mismatch_steps, .{ .replay = true, .recorded_steps = &permissions_mismatch_recorded });
    defer permissions_mismatch.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, permissions_mismatch.state);
    try std.testing.expectEqualStrings("$.replay.permissions", permissions_mismatch.diagnostics.items[0].path);
}

test "workflow replay metadata strictness preserves schema semantics and detects stale selections" {
    const allocator = std.testing.allocator;
    var strict_schema = try parseJson(allocator, "{\"type\":\"object\",\"properties\":{\"issue\":{\"type\":\"string\"}},\"required\":[\"issue\"],\"additionalProperties\":false}");
    defer strict_schema.deinit();
    var output_schema = try parseJson(allocator, "{\"type\":\"object\"}");
    defer output_schema.deinit();
    var replay_input = try parseJson(allocator, "{\"issue\":\"bug\",\"__workflowReplay\":true,\"__workflowReplayMetadata\":{\"steps\":[]}}");
    defer replay_input.deinit();
    var extra_input = try parseJson(allocator, "{\"issue\":\"bug\",\"unexpected\":true,\"__workflowReplay\":true}");
    defer extra_input.deinit();
    var output = try parseJson(allocator, "{}");
    defer output.deinit();

    const descriptor = WorkflowDescriptor{
        .id = "strict-replay",
        .input_schema = strict_schema.value,
        .output_schema = output_schema.value,
    };
    const steps = [_]StepSpec{.{ .id = "current", .output = output.value }};
    var allowed_reserved = try executeWorkflow(allocator, descriptor, replay_input.value, &steps, .{ .replay = true });
    defer allowed_reserved.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.completed, allowed_reserved.state);

    var rejected_user_extra = try executeWorkflow(allocator, descriptor, extra_input.value, &steps, .{ .replay = true });
    defer rejected_user_extra.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.failed, rejected_user_extra.state);
    try std.testing.expectEqualStrings("$.unexpected", rejected_user_extra.diagnostics.items[0].path);

    const extra_recorded_steps = [_]RecordedReplayStep{
        .{ .step_id = "current", .mode = .deterministic },
        .{ .step_id = "removed", .mode = .deterministic },
    };
    var extra_recorded = try executeWorkflow(allocator, descriptor, replay_input.value, &steps, .{ .replay = true, .recorded_steps = &extra_recorded_steps });
    defer extra_recorded.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, extra_recorded.state);
    try std.testing.expectEqualStrings("$.replay.steps", extra_recorded.diagnostics.items[0].path);

    const null_capability_recorded = [_]RecordedReplayStep{.{
        .step_id = "capability",
        .mode = .recorded,
        .selected_capability_present = true,
        .selected_capability = null,
        .output = output.value,
    }};
    const capability_steps = [_]StepSpec{.{ .id = "capability", .kind = .side_effect, .replay_mode = .recorded, .selected_capability = "provider.current" }};
    var null_capability_mismatch = try executeWorkflow(allocator, descriptor, replay_input.value, &capability_steps, .{ .replay = true, .recorded_steps = &null_capability_recorded });
    defer null_capability_mismatch.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.replay_blocked, null_capability_mismatch.state);
    try std.testing.expectEqualStrings("$.replay.steps[].selectedCapability", null_capability_mismatch.diagnostics.items[0].path);
}

test "workflow child-agent execution cannot exceed declared limits or grants" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator, "{\"type\":\"object\"}");
    defer schema.deinit();
    var input = try parseJson(allocator, "{}");
    defer input.deinit();
    var output = try parseJson(allocator, "{}");
    defer output.deinit();

    const grants = [_][]const u8{"read"};
    const descriptor = WorkflowDescriptor{
        .id = "child-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
        .child_agent_limits = .{
            .max_children = 1,
            .max_turns = 2,
            .max_tool_calls = 1,
            .max_tokens = 100,
            .timeout_ms = 1000,
            .permission_grants = &grants,
        },
    };
    const allowed_steps = [_]StepSpec{.{
        .id = "child-ok",
        .kind = .child_agent,
        .output = output.value,
        .child_delta = .{ .children_started = 1, .turns = 2, .tool_calls = 1, .tokens = 100, .elapsed_ms = 1000, .permission = "read" },
        .selected_capability = "agent.delegate",
    }};
    var allowed = try executeWorkflow(allocator, descriptor, input.value, &allowed_steps, .{});
    defer allowed.deinit(allocator);
    try std.testing.expectEqual(ExecutionState.completed, allowed.state);
    try std.testing.expectEqual(@as(u64, 1), allowed.child_usage.children_started);

    const limit_cases = [_]struct {
        id: []const u8,
        delta: ChildAgentDelta,
        reason: []const u8,
    }{
        .{ .id = "children", .delta = .{ .children_started = 2, .permission = "read" }, .reason = "maxChildren exceeded" },
        .{ .id = "turns", .delta = .{ .children_started = 1, .turns = 3, .permission = "read" }, .reason = "maxTurns exceeded" },
        .{ .id = "tools", .delta = .{ .children_started = 1, .tool_calls = 2, .permission = "read" }, .reason = "maxToolCalls exceeded" },
        .{ .id = "tokens", .delta = .{ .children_started = 1, .tokens = 101, .permission = "read" }, .reason = "maxTokens exceeded" },
        .{ .id = "timeout", .delta = .{ .children_started = 1, .elapsed_ms = 1001, .permission = "read" }, .reason = "timeoutMs exceeded" },
        .{ .id = "permission", .delta = .{ .children_started = 1, .permission = "write" }, .reason = "permission grant not allowed" },
    };
    for (limit_cases) |case| {
        const steps = [_]StepSpec{.{
            .id = case.id,
            .kind = .child_agent,
            .output = output.value,
            .child_delta = case.delta,
            .selected_capability = "agent.delegate",
        }};
        var denied = try executeWorkflow(allocator, descriptor, input.value, &steps, .{});
        defer denied.deinit(allocator);
        try std.testing.expectEqual(ExecutionState.failed, denied.state);
        try std.testing.expectEqualStrings("workflow.child_agent_limit_exceeded", denied.diagnostics.items[0].code);
        try std.testing.expectEqualStrings(case.reason, denied.diagnostics.items[0].message);
    }
}

test "workflow selected capabilities dispatch through execution callback" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator, "{\"type\":\"object\"}");
    defer schema.deinit();
    var input = try parseJson(allocator, "{}");
    defer input.deinit();
    var step_input = try parseJson(allocator, "{\"value\":\"alpha\"}");
    defer step_input.deinit();

    const DispatchContext = struct {
        calls: usize = 0,
        seen_input: bool = false,

        fn dispatch(
            dispatch_allocator: std.mem.Allocator,
            capability_id: []const u8,
            dispatch_input: std.json.Value,
            context: ?*anyopaque,
        ) !std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.seen_input = dispatch_input == .object and std.mem.eql(
                u8,
                dispatch_input.object.get("value").?.string,
                "alpha",
            );
            var object = try std.json.ObjectMap.init(dispatch_allocator, &.{}, &.{});
            errdefer common.deinitJsonValue(dispatch_allocator, .{ .object = object });
            try object.put(dispatch_allocator, try dispatch_allocator.dupe(u8, "capability"), .{ .string = try dispatch_allocator.dupe(u8, capability_id) });
            try object.put(dispatch_allocator, try dispatch_allocator.dupe(u8, "value"), .{ .string = try dispatch_allocator.dupe(u8, "dispatched") });
            return .{ .object = object };
        }
    };

    var context = DispatchContext{};
    const descriptor = WorkflowDescriptor{
        .id = "dispatch-flow",
        .input_schema = schema.value,
        .output_schema = schema.value,
    };
    const steps = [_]StepSpec{.{
        .id = "dispatch",
        .kind = .side_effect,
        .input = step_input.value,
        .output = .null,
        .selected_capability = "tool.runtime",
    }};
    var result = try executeWorkflow(allocator, descriptor, input.value, &steps, .{
        .capability_dispatch = DispatchContext.dispatch,
        .capability_dispatch_context = &context,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(ExecutionState.completed, result.state);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expect(context.seen_input);
    try std.testing.expectEqualStrings("tool.runtime", result.output.?.object.get("capability").?.string);
    try std.testing.expectEqualStrings("dispatched", result.output.?.object.get("value").?.string);
    try std.testing.expectEqualStrings("tool.runtime", result.replay_metadata.steps.items[0].selected_capability.?);
}
