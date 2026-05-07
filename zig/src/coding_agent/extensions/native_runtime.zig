const std = @import("std");
const agent = @import("agent");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const enforcement = @import("enforcement.zig");
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

    pub fn deniedCapabilityWithApprovals(
        self: NativeDescriptor,
        approved_capabilities: []const wasm_manifest.Capability,
        phase: wasm_manifest.LifecyclePhase,
        mode: []const u8,
    ) ?wasm_manifest.CapabilityDenialDiagnostic {
        return wasm_manifest.denyFirstUnapprovedCapability(self.requested_capabilities, approved_capabilities, phase, mode);
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
    approved_capabilities: []const wasm_manifest.Capability = &.{},
    host_effects: ?*NativeHostEffects = null,
};

pub const NativeHostEffects = struct {
    sandbox_root: ?[]const u8 = null,
    file_reads: u64 = 0,
    file_writes: u64 = 0,
    network_requests: u64 = 0,
    shell_runs: u64 = 0,
    env_reads: u64 = 0,
    model_calls: u64 = 0,
    session_reads: u64 = 0,
    session_writes: u64 = 0,
    ui_notifications: u64 = 0,
    tool_uses: u64 = 0,
    agent_spawns: u64 = 0,
    agent_delegations: u64 = 0,

    fn ensureSandboxPath(self: NativeHostEffects, path: []const u8) !void {
        const root = self.sandbox_root orelse return;
        if (isPathWithinSandbox(root, path)) return;
        return error.NativeHostSandboxDenied;
    }

    fn recordFileRead(self: *NativeHostEffects, path: []const u8) !void {
        try self.ensureSandboxPath(path);
        self.file_reads += 1;
    }

    fn recordFileWrite(self: *NativeHostEffects, path: []const u8) !void {
        try self.ensureSandboxPath(path);
        self.file_writes += 1;
    }

    fn total(self: NativeHostEffects) u64 {
        return self.file_reads +
            self.file_writes +
            self.network_requests +
            self.shell_runs +
            self.env_reads +
            self.model_calls +
            self.session_reads +
            self.session_writes +
            self.ui_notifications +
            self.tool_uses +
            self.agent_spawns +
            self.agent_delegations;
    }
};

fn isPathWithinSandbox(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root[root.len - 1] == std.fs.path.sep) return true;
    return path.len > root.len and path[root.len] == std.fs.path.sep;
}

fn nativeResourceLimitsToEnforcement(limits: NativeResourceLimits) enforcement.ResourceLimits {
    return .{
        .max_children = limits.max_children,
        .depth = limits.depth,
        .turns = limits.turns,
        .timeout_ms = limits.timeout_ms,
        .output_bytes = limits.output_bytes,
        .output_lines = limits.output_lines,
        .tool_scopes = limits.tool_scopes,
    };
}

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
        if (!self.runtime.state.ready_seen) {
            try self.runtime.state.addDiagnostic(.host_error, .@"error", "native module registered tool before readiness");
            return;
        }
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
        try self.enforceOperation(.file_read, .{ .id = path }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| try effects.recordFileRead(path);
    }

    pub fn writeFile(self: *NativeHostApi, path: []const u8, contents: []const u8) !void {
        _ = contents;
        try self.enforceOperation(.file_write, .{ .id = path }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| try effects.recordFileWrite(path);
    }

    pub fn requestNetwork(self: *NativeHostApi, url: []const u8) !void {
        try self.enforceOperation(.network_request, .{ .id = url }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.network_requests += 1;
    }

    pub fn runShell(self: *NativeHostApi, command: []const u8) !void {
        try self.enforceOperation(.shell_run, .{ .id = command }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.shell_runs += 1;
    }

    pub fn readEnv(self: *NativeHostApi, name: []const u8) !void {
        try self.enforceOperation(.env_read, .{ .id = name }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.env_reads += 1;
    }

    pub fn callModel(self: *NativeHostApi, model: []const u8, payload_json: []const u8) !void {
        try self.enforceOperation(.model_call, .{ .id = model }, .call, "native/host-api", .{
            .turns = 1,
            .output_bytes = payload_json.len,
        });
        if (self.runtime.host_effects) |effects| effects.model_calls += 1;
    }

    pub fn readSession(self: *NativeHostApi, session_id: []const u8) !void {
        try self.enforceOperation(.session_read, .{ .id = session_id }, .call, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.session_reads += 1;
    }

    pub fn writeSession(self: *NativeHostApi, session_id: []const u8, payload_json: []const u8) !void {
        _ = payload_json;
        try self.enforceOperation(.session_write, .{ .id = session_id }, .call, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.session_writes += 1;
    }

    pub fn notifyUi(self: *NativeHostApi, payload_json: []const u8) !void {
        try self.enforceOperation(.ui_notify, .{ .id = payload_json }, .call, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.ui_notifications += 1;
    }

    pub fn useTool(self: *NativeHostApi, name: []const u8, payload_json: []const u8) !void {
        _ = payload_json;
        try self.enforceOperation(.tool_use, .{ .id = name }, .call, "native/host-api", .{ .turns = 1 });
        if (self.runtime.host_effects) |effects| effects.tool_uses += 1;
    }

    pub fn spawnAgent(self: *NativeHostApi, task_json: []const u8) !void {
        try self.enforceOperation(.agent_spawn, .{ .id = task_json }, .call, "native/host-api", .{ .children_started = 1 });
        if (self.runtime.host_effects) |effects| effects.agent_spawns += 1;
    }

    pub fn delegateAgent(self: *NativeHostApi, task_json: []const u8) !void {
        try self.enforceOperation(.agent_delegate, .{ .id = task_json }, .call, "native/host-api", .{ .turns = 1 });
        if (self.runtime.host_effects) |effects| effects.agent_delegations += 1;
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

    fn enforceOperation(
        self: *NativeHostApi,
        operation: enforcement.Operation,
        target: enforcement.OperationTarget,
        phase: wasm_manifest.LifecyclePhase,
        mode: []const u8,
        delta: enforcement.UsageDelta,
    ) !void {
        const decision = enforcement.decide(
            .{
                .runtime_kind = "native",
                .extension_id = self.runtime.descriptor.id,
                .package_root = "native://static",
            },
            .{
                .approved_grants = self.runtime.approved_capabilities,
                .resource_limits = nativeResourceLimitsToEnforcement(self.runtime.descriptor.resource_limits),
            },
            operation,
            target,
            phase,
            mode,
            delta,
            &self.runtime.accounting,
        );
        switch (decision) {
            .allow => return,
            .deny => |denial| {
                try self.addDenialDiagnostic(denial);
                return error.UnsupportedRuntimeCapability;
            },
        }
    }

    fn addDenialDiagnostic(self: *NativeHostApi, denial: enforcement.DenyDecision) !void {
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
        try envelope.writer.writeAll(",\"principal\":{\"runtimeKind\":");
        try std.json.Stringify.value(denial.principal.runtime_kind, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"extensionId\":");
        try std.json.Stringify.value(denial.principal.extension_id, .{}, &envelope.writer);
        if (denial.principal.package_root) |package_root| {
            try envelope.writer.writeAll(",\"packageRoot\":");
            try std.json.Stringify.value(package_root, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("},\"operation\":");
        try std.json.Stringify.value(denial.operation.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"target\":{\"id\":");
        if (denial.target.id) |target_id| {
            try std.json.Stringify.value(target_id, .{}, &envelope.writer);
        } else {
            try envelope.writer.writeAll("null");
        }
        try envelope.writer.writeAll("},\"reason\":");
        try std.json.Stringify.value(denial.reason, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"message\":\"native host API operation denied by enforcement substrate\"}");
        try self.runtime.state.addDiagnostic(.host_error, .@"error", envelope.written());
    }
};

pub const NativeRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: extension_host.ProtocolState,
    mutex: std.Io.Mutex = .init,
    descriptor: *const NativeDescriptor,
    approved_capabilities: []const wasm_manifest.Capability,
    accounting: enforcement.Accounting,
    host_effects: ?*NativeHostEffects,
    tool_bindings: []NativeToolBinding,
    unloaded: bool,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: NativeOptions) !*NativeRuntime {
        try options.descriptor.validate(allocator);
        if (options.descriptor.deniedCapabilityWithApprovals(options.approved_capabilities, .initialize, "native/descriptor") != null) return error.UnsupportedRuntimeCapability;

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
            .approved_capabilities = options.approved_capabilities,
            .accounting = .{},
            .host_effects = options.host_effects,
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

const native_enforcement_matrix_tool: NativeToolDefinition = .{
    .name = "native.enforcement.matrix",
    .label = "Native Enforcement Matrix",
    .description = "Test-only native tool used to assert operation gate side effects.",
    .input_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://enforcement/matrix",
};

fn nativeSandboxPath(allocator: std.mem.Allocator, effects: ?*NativeHostEffects, leaf: []const u8) ![]u8 {
    const sandbox_root = (effects orelse return error.NativeHostSandboxDenied).sandbox_root orelse return error.NativeHostSandboxDenied;
    return std.fs.path.join(allocator, &.{ sandbox_root, leaf });
}

fn nativeDeniedOperationMatrixStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_enforcement_matrix_tool);

    const read_path = try nativeSandboxPath(api.runtime.allocator, api.runtime.host_effects, "read.txt");
    defer api.runtime.allocator.free(read_path);
    const write_path = try nativeSandboxPath(api.runtime.allocator, api.runtime.host_effects, "write.txt");
    defer api.runtime.allocator.free(write_path);

    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.readFile(read_path));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.writeFile(write_path, "blocked"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.requestNetwork("https://example.invalid/blocked"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.runShell("echo blocked"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.readEnv("PI_BLOCKED"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.callModel("fake-model", "{\"prompt\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.readSession("session-blocked"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.writeSession("session-blocked", "{\"blocked\":true}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.notifyUi("{\"message\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.useTool("native.enforcement.matrix", "{\"blocked\":true}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.spawnAgent("{\"task\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.delegateAgent("{\"task\":\"blocked\"}"));
}

fn nativeAllowedOperationMatrixStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_enforcement_matrix_tool);

    const read_path = try nativeSandboxPath(api.runtime.allocator, api.runtime.host_effects, "read.txt");
    defer api.runtime.allocator.free(read_path);
    const write_path = try nativeSandboxPath(api.runtime.allocator, api.runtime.host_effects, "write.txt");
    defer api.runtime.allocator.free(write_path);

    try api.readFile(read_path);
    try api.writeFile(write_path, "allowed");
    try api.requestNetwork("fake://network/request");
    try api.runShell("fake-shell --no-side-effects");
    try api.readEnv("PI_FAKE_ENV");
    try api.callModel("fake-model", "{\"prompt\":\"allowed\"}");
    try api.readSession("session-allowed");
    try api.writeSession("session-allowed", "{\"allowed\":true}");
    try api.notifyUi("{\"message\":\"allowed\"}");
    try api.useTool("native.enforcement.matrix", "{\"allowed\":true}");
    try api.spawnAgent("{\"task\":\"allowed\"}");
    try api.delegateAgent("{\"task\":\"allowed\"}");
}

const native_denied_operation_matrix_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-denied-operation-matrix",
    .name = "Native Denied Operation Matrix",
    .version = "0.1.0",
    .description = "Exercises every denied native host operation without side effects.",
    .tools = &.{native_enforcement_matrix_tool},
    .start = nativeDeniedOperationMatrixStart,
};

const native_allowed_operation_matrix_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-allowed-operation-matrix",
    .name = "Native Allowed Operation Matrix",
    .version = "0.1.0",
    .description = "Exercises every allowed native host operation using fake/sandbox effects.",
    .tools = &.{native_enforcement_matrix_tool},
    .requested_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    .resource_limits = .{
        .turns = 8,
        .output_bytes = 1024,
        .output_lines = 64,
        .max_children = 2,
        .depth = 1,
        .tool_scopes = &.{"native.enforcement.matrix"},
    },
    .start = nativeAllowedOperationMatrixStart,
};

fn makeNativeAbsoluteTestPath(allocator: std.mem.Allocator, tmp: anytype, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        relative_path,
    });
}

test "native host operation gates deny side effects through enforcement matrix" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sandbox", .default_dir);
    const sandbox_root = try makeNativeAbsoluteTestPath(allocator, tmp, "sandbox");
    defer allocator.free(sandbox_root);

    var effects = NativeHostEffects{ .sandbox_root = sandbox_root };
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &native_denied_operation_matrix_descriptor,
        .host_effects = &effects,
    });
    defer runtime.deinit();

    try runtime.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), runtime.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 12), runtime.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 12), runtime.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqual(@as(u64, 0), effects.total());
    try std.testing.expectEqual(@as(u64, 0), runtime.accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 0), runtime.accounting.turns);
    try std.testing.expectEqual(@as(u64, 0), runtime.accounting.children_started);

    const expected = [_]struct {
        capability: wasm_manifest.Capability,
        operation: []const u8,
    }{
        .{ .capability = .file_read, .operation = "file.read" },
        .{ .capability = .file_write, .operation = "file.write" },
        .{ .capability = .network_request, .operation = "network.request" },
        .{ .capability = .shell_run, .operation = "shell.run" },
        .{ .capability = .env_read, .operation = "env.read" },
        .{ .capability = .model_call, .operation = "model.call" },
        .{ .capability = .session_read, .operation = "session.read" },
        .{ .capability = .session_write, .operation = "session.write" },
        .{ .capability = .ui_notify, .operation = "ui.notify" },
        .{ .capability = .tool_use, .operation = "tool.use" },
        .{ .capability = .agent_spawn, .operation = "agent.spawn" },
        .{ .capability = .agent_delegate, .operation = "agent.delegate" },
    };

    for (expected) |entry| {
        var found = false;
        for (runtime.state.diagnostics.items) |diagnostic| {
            if (std.mem.indexOf(u8, diagnostic.message, "\"category\":\"denied_capability\"") != null and
                std.mem.indexOf(u8, diagnostic.message, entry.capability.jsonName()) != null and
                std.mem.indexOf(u8, diagnostic.message, entry.capability.enforcementBranch().jsonName()) != null and
                std.mem.indexOf(u8, diagnostic.message, "\"phase\":") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"mode\":\"native/host-api\"") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"principal\":{\"runtimeKind\":\"native\"") != null and
                std.mem.indexOf(u8, diagnostic.message, entry.operation) != null)
            {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "native host operation gates allow only fake and sandbox side effects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sandbox", .default_dir);
    const sandbox_root = try makeNativeAbsoluteTestPath(allocator, tmp, "sandbox");
    defer allocator.free(sandbox_root);

    var effects = NativeHostEffects{ .sandbox_root = sandbox_root };
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &native_allowed_operation_matrix_descriptor,
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
        .host_effects = &effects,
    });
    defer runtime.deinit();

    try runtime.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), runtime.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), runtime.diagnosticCount());
    try std.testing.expectEqual(@as(u64, 1), effects.file_reads);
    try std.testing.expectEqual(@as(u64, 1), effects.file_writes);
    try std.testing.expectEqual(@as(u64, 1), effects.network_requests);
    try std.testing.expectEqual(@as(u64, 1), effects.shell_runs);
    try std.testing.expectEqual(@as(u64, 1), effects.env_reads);
    try std.testing.expectEqual(@as(u64, 1), effects.model_calls);
    try std.testing.expectEqual(@as(u64, 1), effects.session_reads);
    try std.testing.expectEqual(@as(u64, 1), effects.session_writes);
    try std.testing.expectEqual(@as(u64, 1), effects.ui_notifications);
    try std.testing.expectEqual(@as(u64, 1), effects.tool_uses);
    try std.testing.expectEqual(@as(u64, 1), effects.agent_spawns);
    try std.testing.expectEqual(@as(u64, 1), effects.agent_delegations);
    try std.testing.expectEqual(@as(u64, 12), effects.total());
    try std.testing.expectEqual(@as(u64, 12), runtime.accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 3), runtime.accounting.turns);
    try std.testing.expect(runtime.accounting.output_bytes > 0);
    try std.testing.expectEqual(@as(u64, 1), runtime.accounting.children_started);
}
