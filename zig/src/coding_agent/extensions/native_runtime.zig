const std = @import("std");
const agent = @import("agent");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const tools_common = @import("../tools/common.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");

pub const Registry = extension_registry.Registry;
pub const RegistryCallback = *const fn (context: ?*anyopaque, registry: *const Registry) anyerror!void;

pub const NativeToolExecute = *const fn (
    allocator: std.mem.Allocator,
    params: std.json.Value,
) anyerror!agent.AgentToolResult;

pub const NativeToolDefinition = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    output_schema_json: ?[]const u8 = null,
    extension_path: []const u8,
    execute: ?NativeToolExecute = null,
};

pub const NativeStartFn = *const fn (api: *NativeHostApi) anyerror!void;

pub const NativeResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: []const []const u8 = &.{},

    pub fn validate(self: NativeResourceLimits) !void {
        _ = self.max_children;
        _ = self.depth;
        _ = self.turns;
        _ = self.timeout_ms;
        _ = self.output_bytes;
        _ = self.output_lines;
        for (self.tool_scopes) |scope| {
            if (scope.len == 0) return error.InvalidRuntimeOptions;
        }
    }
};

pub const NativeDescriptor = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    tools: []const NativeToolDefinition = &.{},
    requested_capabilities: []const wasm_manifest.Capability = &.{},
    resource_limits: NativeResourceLimits = .{},
    library_path: ?[]const u8 = null,
    dynamic_library_path: ?[]const u8 = null,
    executable_command: ?[]const u8 = null,
    process_command: ?[]const u8 = null,
    remote_url: ?[]const u8 = null,
    workflow_preset: ?[]const u8 = null,
    wiki_preset: ?[]const u8 = null,
    qa_preset: ?[]const u8 = null,
    review_preset: ?[]const u8 = null,
    spawn_policy: ?[]const u8 = null,
    automatic_spawn: ?[]const u8 = null,
    orchestration_policy: ?[]const u8 = null,
    model_selection_ui: ?[]const u8 = null,
    approval_ui: ?[]const u8 = null,
    start: NativeStartFn = defaultNativeStart,

    pub fn validate(self: NativeDescriptor, allocator: std.mem.Allocator) !void {
        if (self.firstForbiddenField() != null) return error.ForbiddenNativeDescriptorField;
        if (self.id.len == 0) return error.InvalidRuntimeOptions;
        if (self.name.len == 0) return error.InvalidRuntimeOptions;
        if (self.version.len == 0) return error.InvalidRuntimeOptions;
        if (self.description.len == 0) return error.InvalidRuntimeOptions;
        try self.resource_limits.validate();
        for (self.tools, 0..) |tool, index| {
            if (tool.name.len == 0) return error.InvalidRuntimeOptions;
            if (tool.label.len == 0) return error.InvalidRuntimeOptions;
            if (tool.description.len == 0) return error.InvalidRuntimeOptions;
            if (tool.extension_path.len == 0) return error.InvalidRuntimeOptions;
            if (tool.input_schema_json.len == 0) return error.InvalidRuntimeOptions;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, tool.input_schema_json, .{}) catch return error.InvalidRuntimeOptions;
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidRuntimeOptions;
            if (tool.output_schema_json) |output_schema_json| {
                if (output_schema_json.len == 0) return error.InvalidRuntimeOptions;
                var parsed_output = std.json.parseFromSlice(std.json.Value, allocator, output_schema_json, .{}) catch return error.InvalidRuntimeOptions;
                defer parsed_output.deinit();
                if (parsed_output.value != .object) return error.InvalidRuntimeOptions;
            }
            for (self.tools[index + 1 ..]) |candidate| {
                if (std.mem.eql(u8, tool.name, candidate.name)) return error.InvalidRuntimeOptions;
            }
        }
    }

    pub fn deniedCapability(
        self: NativeDescriptor,
        phase: wasm_manifest.LifecyclePhase,
        mode: []const u8,
    ) ?wasm_manifest.CapabilityDenialDiagnostic {
        return wasm_manifest.denyFirstUnapprovedCapability(self.requested_capabilities, &.{}, phase, mode);
    }

    pub fn firstForbiddenField(self: NativeDescriptor) ?[]const u8 {
        if (self.library_path != null) return "library_path";
        if (self.dynamic_library_path != null) return "dynamic_library_path";
        if (self.executable_command != null) return "executable_command";
        if (self.process_command != null) return "process_command";
        if (self.remote_url != null) return "remote_url";
        if (self.workflow_preset != null) return "workflow_preset";
        if (self.wiki_preset != null) return "wiki_preset";
        if (self.qa_preset != null) return "qa_preset";
        if (self.review_preset != null) return "review_preset";
        if (self.spawn_policy != null) return "spawn_policy";
        if (self.automatic_spawn != null) return "automatic_spawn";
        if (self.orchestration_policy != null) return "orchestration_policy";
        if (self.model_selection_ui != null) return "model_selection_ui";
        if (self.approval_ui != null) return "approval_ui";
        return null;
    }
};

pub const NativeOptions = struct {
    descriptor: *const NativeDescriptor,
};

const NativeToolBinding = struct {
    runtime: *NativeRuntime,
    definition: *const NativeToolDefinition,
};

pub const NativeHostApi = struct {
    runtime: *NativeRuntime,

    pub fn ready(self: *NativeHostApi) !void {
        try self.runtime.state.onMessage(.ready);
    }

    pub fn registerTool(self: *NativeHostApi, tool: NativeToolDefinition) !void {
        var parsed_parameters = std.json.parseFromSlice(std.json.Value, self.runtime.allocator, tool.input_schema_json, .{}) catch return error.InvalidRuntimeOptions;
        defer parsed_parameters.deinit();
        try self.runtime.state.registry.registerToolFull(
            tool.name,
            tool.label,
            tool.description,
            parsed_parameters.value,
            null,
            null,
            tool.extension_path,
        );
        self.runtime.state.registry_frames_applied += 1;
    }

    pub fn requestUi(
        self: *NativeHostApi,
        id: []const u8,
        method: []const u8,
        response_required: bool,
        payload_json: []const u8,
    ) !void {
        if (!self.runtime.state.ready_seen) {
            try self.runtime.state.addDiagnostic(.host_error, .@"error", "native module requested UI before readiness");
            return;
        }
        if (self.runtime.state.pending_requests_closed) return;
        if (response_required) {
            if (self.runtime.state.pending_request_ids.contains(id)) {
                try self.runtime.state.addDiagnostic(.duplicate_pending_request, .@"error", "native module emitted duplicate pending request id");
                return;
            }
            try self.runtime.state.pending_request_ids.put(try self.runtime.allocator.dupe(u8, id), {});
        }

        const owned_id = try self.runtime.allocator.dupe(u8, id);
        errdefer self.runtime.allocator.free(owned_id);
        const owned_method = try self.runtime.allocator.dupe(u8, method);
        errdefer self.runtime.allocator.free(owned_method);
        const owned_payload = try self.runtime.allocator.dupe(u8, payload_json);
        errdefer self.runtime.allocator.free(owned_payload);
        try self.runtime.state.ui_requests.append(self.runtime.allocator, .{
            .id = owned_id,
            .method = owned_method,
            .response_required = response_required,
            .payload_json = owned_payload,
        });
    }

    pub fn readFile(self: *NativeHostApi, path: []const u8) !void {
        _ = path;
        return self.denyCapability(.file_read, .initialize, "file.read");
    }

    pub fn writeFile(self: *NativeHostApi, path: []const u8, contents: []const u8) !void {
        _ = path;
        _ = contents;
        return self.denyCapability(.file_write, .initialize, "file.write");
    }

    pub fn requestNetwork(self: *NativeHostApi, url: []const u8) !void {
        _ = url;
        return self.denyCapability(.network_request, .initialize, "network.request");
    }

    pub fn runShell(self: *NativeHostApi, command: []const u8) !void {
        _ = command;
        return self.denyCapability(.shell_run, .initialize, "shell.run");
    }

    pub fn readEnv(self: *NativeHostApi, name: []const u8) !void {
        _ = name;
        return self.denyCapability(.env_read, .initialize, "env.read");
    }

    pub fn callModel(self: *NativeHostApi, model: []const u8, payload_json: []const u8) !void {
        _ = model;
        _ = payload_json;
        return self.denyCapability(.model_call, .initialize, "model.call");
    }

    pub fn readSession(self: *NativeHostApi, session_id: []const u8) !void {
        _ = session_id;
        return self.denyCapability(.session_read, .initialize, "session.read");
    }

    pub fn writeSession(self: *NativeHostApi, session_id: []const u8, payload_json: []const u8) !void {
        _ = session_id;
        _ = payload_json;
        return self.denyCapability(.session_write, .initialize, "session.write");
    }

    pub fn notifyUi(self: *NativeHostApi, payload_json: []const u8) !void {
        _ = payload_json;
        return self.denyCapability(.ui_notify, .initialize, "ui.notify");
    }

    pub fn useTool(self: *NativeHostApi, name: []const u8, payload_json: []const u8) !void {
        _ = name;
        _ = payload_json;
        return self.denyCapability(.tool_use, .call, "tool.use");
    }

    pub fn spawnAgent(self: *NativeHostApi, task_json: []const u8) !void {
        _ = task_json;
        return self.denyCapability(.agent_spawn, .call, "agent.spawn");
    }

    pub fn delegateAgent(self: *NativeHostApi, task_json: []const u8) !void {
        _ = task_json;
        return self.denyCapability(.agent_delegate, .call, "agent.delegate");
    }

    pub fn emitEvent(self: *NativeHostApi, frame_json: []const u8) !void {
        _ = frame_json;
        try self.runtime.state.addDiagnostic(
            .host_error,
            .@"error",
            "{\"phase\":\"initialize\",\"category\":\"unsupported_native_host_event\",\"operation\":\"event.emit\",\"message\":\"native host API event emission is not supported in v0\"}",
        );
        return error.UnsupportedNativeHostOperation;
    }

    fn denyCapability(
        self: *NativeHostApi,
        capability: wasm_manifest.Capability,
        phase: wasm_manifest.LifecyclePhase,
        operation: []const u8,
    ) !void {
        const denial = wasm_manifest.denyRuntimeCapability(capability, phase, "native/host-api");
        var envelope: std.Io.Writer.Allocating = .init(self.runtime.allocator);
        defer envelope.deinit();
        try envelope.writer.writeAll("{\"category\":");
        try std.json.Stringify.value(denial.category, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"capability\":");
        try std.json.Stringify.value(denial.capability.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"branch\":");
        try std.json.Stringify.value(denial.branch.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"phase\":");
        try std.json.Stringify.value(denial.phase.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"mode\":");
        try std.json.Stringify.value(denial.mode, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"operation\":");
        try std.json.Stringify.value(operation, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"message\":\"native host API operation denied by default\"}");
        try self.runtime.state.addDiagnostic(.host_error, .@"error", envelope.written());
        return error.UnsupportedRuntimeCapability;
    }
};

pub const NativeRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: extension_host.ProtocolState,
    mutex: std.Io.Mutex = .init,
    descriptor: *const NativeDescriptor,
    tool_bindings: []NativeToolBinding,
    unloaded: bool,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: NativeOptions) !*NativeRuntime {
        try options.descriptor.validate(allocator);
        if (options.descriptor.deniedCapability(.initialize, "native/descriptor") != null) return error.UnsupportedRuntimeCapability;

        const tool_bindings = try allocator.alloc(NativeToolBinding, options.descriptor.tools.len);
        var runtime_initialized = false;
        errdefer if (!runtime_initialized) allocator.free(tool_bindings);
        const runtime = try allocator.create(NativeRuntime);
        errdefer if (!runtime_initialized) allocator.destroy(runtime);
        runtime.* = .{
            .allocator = allocator,
            .io = io,
            .state = extension_host.ProtocolState.init(allocator),
            .descriptor = options.descriptor,
            .tool_bindings = tool_bindings,
            .unloaded = false,
        };
        for (runtime.tool_bindings, options.descriptor.tools) |*binding, *tool| {
            binding.* = .{
                .runtime = runtime,
                .definition = tool,
            };
        }
        runtime_initialized = true;
        errdefer runtime.deinit();

        var api = NativeHostApi{ .runtime = runtime };
        try options.descriptor.start(&api);
        if (!runtime.state.ready_seen) return error.HostNotReady;
        return runtime;
    }

    pub fn waitForReady(self: *NativeRuntime, timeout_ms: u64) !void {
        _ = timeout_ms;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.ready_seen) return;
        return error.HostNotReady;
    }

    pub fn pendingCount(self: *NativeRuntime) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.pendingCount();
    }

    pub fn diagnosticCount(self: *NativeRuntime) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.diagnostics.items.len;
    }

    pub fn diagnosticCategoryCount(self: *NativeRuntime, category: extension_host.DiagnosticCategory) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.diagnosticCategoryCount(category);
    }

    pub fn hasShutdownComplete(self: *NativeRuntime) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.shutdown_complete_seen;
    }

    pub fn registryFramesApplied(self: *NativeRuntime) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.registry_frames_applied;
    }

    pub fn hasRegisteredCommand(self: *NativeRuntime, name: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.registry.hasCommandInvocation(name);
    }

    pub fn snapshotRegistryJson(self: *NativeRuntime, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try extension_registry.writeRegistrySnapshotJson(allocator, &self.state.registry, &out.writer);
        return try allocator.dupe(u8, out.written());
    }

    pub fn withRegistry(self: *NativeRuntime, context: ?*anyopaque, callback: RegistryCallback) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try callback(context, &self.state.registry);
    }

    pub fn applyCliFlagValues(self: *NativeRuntime, entries: []const extension_registry.ParsedCliFlag) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (entries) |entry| {
            _ = try self.state.registry.setFlagValue(entry.name, entry.value);
        }
    }

    pub fn agentTool(self: *NativeRuntime, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.unloaded) return null;
        for (self.state.registry.tools.items) |tool| {
            if (!std.mem.eql(u8, tool.name, name)) continue;
            for (self.tool_bindings) |*binding| {
                if (!std.mem.eql(u8, binding.definition.name, name)) continue;
                return .{
                    .name = tool.name,
                    .description = tool.description,
                    .label = tool.label,
                    .parameters = try tools_common.cloneJsonValue(allocator, tool.parameters),
                    .execute = nativeAgentToolExecute,
                    .execute_context = binding,
                };
            }
        }
        return null;
    }

    pub fn takeUiRequests(self: *NativeRuntime, allocator: std.mem.Allocator) ![]extension_host.ExtensionUiRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const requests = try allocator.alloc(extension_host.ExtensionUiRequest, self.state.ui_requests.items.len);
        errdefer allocator.free(requests);
        for (self.state.ui_requests.items, 0..) |request, index| {
            requests[index] = try extension_host.ExtensionUiRequest.clone(allocator, request);
        }
        for (self.state.ui_requests.items) |*request| request.deinit(self.allocator);
        self.state.ui_requests.clearRetainingCapacity();
        return requests;
    }

    pub fn sendExtensionUiResponse(self: *NativeRuntime, id: []const u8, payload_json: []const u8) !void {
        _ = payload_json;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.state.resolvePendingRequest(id);
    }

    pub fn sendExtensionEventFrame(self: *NativeRuntime, frame_json: []const u8) void {
        _ = frame_json;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
    }

    pub fn shutdown(self: *NativeRuntime) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.cleanupForUnload();
        self.state.shutdown_complete_seen = true;
    }

    pub fn deinit(self: *NativeRuntime) void {
        self.cleanupForUnload();
        self.state.deinit();
        self.allocator.free(self.tool_bindings);
        self.allocator.destroy(self);
    }

    fn cleanupForUnload(self: *NativeRuntime) void {
        self.state.closePendingRequests();
        for (self.descriptor.tools) |tool| {
            _ = self.state.registry.unregisterTool(tool.name);
        }
        self.unloaded = true;
    }
};

fn defaultNativeStart(api: *NativeHostApi) !void {
    try api.ready();
    for (api.runtime.descriptor.tools) |tool| {
        try api.registerTool(tool);
    }
}

fn nativeAgentToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    _ = tool_call_id;
    _ = signal;
    _ = on_update_context;
    _ = on_update;
    const binding: *NativeToolBinding = @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
    binding.runtime.mutex.lockUncancelable(binding.runtime.io);
    defer binding.runtime.mutex.unlock(binding.runtime.io);
    if (binding.runtime.unloaded) return error.NativeToolNotRegistered;
    var registered = false;
    for (binding.runtime.state.registry.tools.items) |tool| {
        if (std.mem.eql(u8, tool.name, binding.definition.name)) {
            registered = true;
            break;
        }
    }
    if (!registered) return error.NativeToolNotRegistered;
    const execute = binding.definition.execute orelse return error.NativeToolNotExecutable;
    return execute(allocator, params) catch |err| switch (err) {
        error.InvalidNativeToolInput => {
            try binding.runtime.state.addDiagnostic(
                .host_error,
                .@"error",
                "{\"phase\":\"call\",\"category\":\"invalid_input\",\"path\":\"$.execute\",\"capability\":null,\"message\":\"execute input must be a JSON object with string field value\"}",
            );
            return invalidNativeInputAgentToolResult(allocator);
        },
        else => return err,
    };
}

fn invalidNativeInputAgentToolResult(allocator: std.mem.Allocator) !agent.AgentToolResult {
    return .{ .content = try tools_common.makeTextContent(
        allocator,
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with string field value\"}}",
    ) };
}
