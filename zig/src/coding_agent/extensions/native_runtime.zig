const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const sandbox = ai.shared.sandbox;
const string_utils = ai.shared.string_utils;
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const enforcement = @import("enforcement.zig");
const tools_common = @import("../tools/common.zig");
const capability = @import("capability.zig");
const sdk = @import("sdk.zig");
const dynamic_library = @import("native_dynamic_library.zig");
const native_process = @import("native_process.zig");

pub const Registry = extension_registry.Registry;
pub const RegistryCallback = *const fn (context: ?*anyopaque, registry: *const Registry) anyerror!void;

pub const NativeToolExecute = *const fn (
    ctx: *sdk.ToolContext,
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

pub const NativeHookDefinition = struct {
    event_name: []const u8,
    extension_path: []const u8,
    priority: i64 = 0,
    declaration_order: ?usize = null,
    error_policy: extension_registry.HookErrorPolicy = .@"continue",
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
    hooks: []const NativeHookDefinition = &.{},
    requested_capabilities: []const capability.Capability = &.{},
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
        for (self.hooks) |hook| {
            if (hook.event_name.len == 0) return error.InvalidRuntimeOptions;
            if (hook.extension_path.len == 0) return error.InvalidRuntimeOptions;
        }
    }

    pub fn deniedCapability(
        self: NativeDescriptor,
        phase: capability.LifecyclePhase,
        mode: []const u8,
    ) ?capability.CapabilityDenialDiagnostic {
        return capability.denyFirstUnapprovedCapability(self.requested_capabilities, &.{}, phase, mode);
    }

    pub fn deniedCapabilityWithApprovals(
        self: NativeDescriptor,
        approved_capabilities: []const capability.Capability,
        phase: capability.LifecyclePhase,
        mode: []const u8,
    ) ?capability.CapabilityDenialDiagnostic {
        return capability.denyFirstUnapprovedCapability(self.requested_capabilities, approved_capabilities, phase, mode);
    }

    const forbidden_fields = &[_][]const u8{
        "library_path",
        "dynamic_library_path",
        "executable_command",
        "process_command",
        "remote_url",
        "workflow_preset",
        "wiki_preset",
        "qa_preset",
        "review_preset",
        "spawn_policy",
        "automatic_spawn",
        "orchestration_policy",
        "model_selection_ui",
        "approval_ui",
    };

    pub fn firstForbiddenField(self: NativeDescriptor) ?[]const u8 {
        inline for (forbidden_fields) |name| {
            if (@field(self, name) != null) return name;
        }
        return null;
    }
};

pub const NativeOptions = struct {
    descriptor: *const NativeDescriptor,
    approved_capabilities: []const capability.Capability = &.{},
    resource_limits: ?NativeResourceLimits = null,
    policy_lookup_key: ?[]const u8 = null,
    host_effects: ?*NativeHostEffects = null,
    /// Optional dynamic library handle kept open for descriptors loaded from
    /// shared objects. NativeRuntime takes ownership only after successful
    /// start; callers remain responsible for closing it when start returns an
    /// error before ownership transfer.
    dyn_lib: ?dynamic_library.Handle = null,
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
    extension_event_invocations: u64 = 0,

    fn ensureSandboxPath(self: NativeHostEffects, io: std.Io, path: []const u8) !void {
        const root = self.sandbox_root orelse return;
        if (!sandbox.isPathWithinSandbox(root, path)) return error.NativeHostSandboxDenied;
        if (!sandbox.isCanonicalPathWithinSandbox(io, root, path)) return error.NativeHostSandboxDenied;
    }

    fn recordFileRead(self: *NativeHostEffects, io: std.Io, path: []const u8) !void {
        try self.ensureSandboxPath(io, path);
        self.file_reads += 1;
    }

    fn recordFileWrite(self: *NativeHostEffects, io: std.Io, path: []const u8) !void {
        try self.ensureSandboxPath(io, path);
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

    pub fn registerHook(self: *NativeHostApi, hook: NativeHookDefinition) !void {
        if (!self.runtime.state.ready_seen) {
            try self.runtime.state.addDiagnostic(.host_error, .@"error", "native module registered hook before readiness");
            return;
        }
        try self.runtime.state.registry.registerHookFull(
            hook.event_name,
            hook.extension_path,
            hook.priority,
            hook.declaration_order,
            hook.error_policy,
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

    /// Read a file from the filesystem. Enforces `file_read` capability and
    /// sandbox boundaries before performing I/O.
    pub fn readFile(self: *NativeHostApi, path: []const u8) ![]u8 {
        try self.enforceOperation(.file_read, .{ .id = path }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| {
            effects.recordFileRead(self.runtime.io, path) catch |err| switch (err) {
                error.NativeHostSandboxDenied => {
                    self.runtime.accounting.recordDenied();
                    try self.addSandboxDenialDiagnostic(.file_read, path, effects.sandbox_root);
                    return err;
                },
            };
        }
        return std.Io.Dir.readFileAlloc(.cwd(), self.runtime.io, path, self.runtime.allocator, .unlimited);
    }

    /// Write a file to the filesystem. Enforces `file_write` capability and
    /// sandbox boundaries before performing I/O.
    pub fn writeFile(self: *NativeHostApi, path: []const u8, contents: []const u8) !void {
        try self.enforceOperation(.file_write, .{ .id = path }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| {
            effects.recordFileWrite(self.runtime.io, path) catch |err| switch (err) {
                error.NativeHostSandboxDenied => {
                    self.runtime.accounting.recordDenied();
                    try self.addSandboxDenialDiagnostic(.file_write, path, effects.sandbox_root);
                    return err;
                },
            };
        }
        return std.Io.Dir.writeFile(.cwd(), self.runtime.io, .{ .sub_path = path, .data = contents });
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not perform actual network I/O.
    pub fn requestNetwork(self: *NativeHostApi, url: []const u8) !void {
        try self.enforceOperation(.network_request, .{ .id = url }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.network_requests += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not execute shell commands.
    pub fn runShell(self: *NativeHostApi, command: []const u8) !void {
        try self.enforceOperation(.shell_run, .{ .id = command }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.shell_runs += 1;
    }

    /// Read an environment variable. Enforces `env_read` capability and
    /// returns the variable value as an owned string.
    pub fn readEnv(self: *NativeHostApi, name: []const u8) ![]u8 {
        try self.enforceOperation(.env_read, .{ .id = name }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.env_reads += 1;
        const env = currentProcessEnviron();
        var env_map = try env.createMap(self.runtime.allocator);
        defer env_map.deinit();
        const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
        return try self.runtime.allocator.dupe(u8, value);
    }

    fn currentProcessEnviron() std.process.Environ {
        const builtin = @import("builtin");
        return switch (builtin.os.tag) {
            .windows => .{ .block = .{ .use_global = true } },
            else => blk: {
                const c_environ = std.c.environ;
                var env_count: usize = 0;
                while (c_environ[env_count] != null) : (env_count += 1) {}
                break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
            },
        };
    }

    /// Spawn a child process and capture stdout/stderr. Enforces `shell_run`
    /// capability before performing the operation.
    pub fn spawnProcess(self: *NativeHostApi, options: native_process.ProcessOptions) !native_process.ProcessResult {
        try self.enforceOperation(.shell_run, .{ .id = options.argv[0] }, .initialize, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.shell_runs += 1;
        return native_process.spawnAndCollect(self.runtime.allocator, self.runtime.io, options);
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not call language models.
    pub fn callModel(self: *NativeHostApi, model: []const u8, payload_json: []const u8) !void {
        try self.enforceOperation(.model_call, .{ .id = model }, .call, "native/host-api", .{
            .turns = 1,
            .output_bytes = payload_json.len,
        });
        if (self.runtime.host_effects) |effects| effects.model_calls += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not read session state.
    pub fn readSession(self: *NativeHostApi, session_id: []const u8) !void {
        try self.enforceOperation(.session_read, .{ .id = session_id }, .call, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.session_reads += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not write session state.
    pub fn writeSession(self: *NativeHostApi, session_id: []const u8, payload_json: []const u8) !void {
        _ = payload_json;
        try self.enforceOperation(.session_write, .{ .id = session_id }, .call, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.session_writes += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not emit UI notifications.
    pub fn notifyUi(self: *NativeHostApi, payload_json: []const u8) !void {
        try self.enforceOperation(.ui_notify, .{ .id = payload_json }, .call, "native/host-api", .{});
        if (self.runtime.host_effects) |effects| effects.ui_notifications += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not invoke tools.
    pub fn useTool(self: *NativeHostApi, name: []const u8, payload_json: []const u8) !void {
        _ = payload_json;
        try self.enforceOperation(.tool_use, .{ .id = name }, .call, "native/host-api", .{ .turns = 1 });
        if (self.runtime.host_effects) |effects| effects.tool_uses += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not spawn agents.
    pub fn spawnAgent(self: *NativeHostApi, task_json: []const u8) !void {
        try self.enforceOperation(.agent_spawn, .{ .id = task_json }, .call, "native/host-api", .{ .children_started = 1 });
        if (self.runtime.host_effects) |effects| effects.agent_spawns += 1;
    }

    /// Permission-gated counter stub. Enforces capability checks and records
    /// the operation via host_effects, but does not delegate to agents.
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
        phase: capability.LifecyclePhase,
        mode: []const u8,
        delta: enforcement.UsageDelta,
    ) !void {
        const decision = enforcement.decide(
            .{
                .runtime_kind = "native",
                .extension_id = self.runtime.descriptor.id,
                .policy_lookup_key = self.runtime.policy_lookup_key,
                .package_root = "native://static",
            },
            .{
                .approved_grants = self.runtime.approved_capabilities,
                .resource_limits = nativeResourceLimitsToEnforcement(self.runtime.resource_limits),
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
        try envelope.writer.writeAll("{\"schemaVersion\":\"diagnostic-envelope.v0\",\"severity\":\"error\",\"runtimeKind\":\"native\",\"category\":");
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
        if (denial.principal.policy_lookup_key) |policy_lookup_key| {
            try envelope.writer.writeAll(",\"policyLookupKey\":");
            try std.json.Stringify.value(policy_lookup_key, .{}, &envelope.writer);
        }
        if (denial.principal.package_root) |package_root| {
            try envelope.writer.writeAll(",\"packageRoot\":");
            try std.json.Stringify.value(package_root, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("},\"operation\":");
        try std.json.Stringify.value(denial.operation.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"target\":{\"id\":");
        if (enforcement.diagnosticTargetId(denial.operation, denial.target)) |target_id| {
            try string_utils.writeRedactedDiagnosticString(&envelope.writer, target_id);
        } else {
            try envelope.writer.writeAll("null");
        }
        try envelope.writer.writeAll("},\"reason\":");
        try std.json.Stringify.value(denial.reason, .{}, &envelope.writer);
        if (denial.limit_name) |limit_name| {
            try envelope.writer.writeAll(",\"limit\":{\"name\":");
            try std.json.Stringify.value(limit_name, .{}, &envelope.writer);
            try envelope.writer.writeAll(",\"configuredValue\":");
            try envelope.writer.print("{}", .{denial.limit_value orelse 0});
            try envelope.writer.writeAll("}");
        }
        try envelope.writer.writeAll(",\"source\":{\"runtimeKind\":\"native\",\"descriptorId\":");
        try std.json.Stringify.value(self.runtime.descriptor.id, .{}, &envelope.writer);
        if (self.runtime.descriptor.tools.len > 0) {
            try envelope.writer.writeAll(",\"extensionPath\":");
            try std.json.Stringify.value(self.runtime.descriptor.tools[0].extension_path, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("}");
        try envelope.writer.writeAll(",\"extensionIdentity\":");
        try std.json.Stringify.value(denial.principal.extension_id, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"recoveryHint\":\"Grant the required native extension capability or disable the operation.\",\"message\":\"native host API operation denied by enforcement substrate\"}");
        try self.runtime.state.addDiagnostic(.host_error, .@"error", envelope.written());
    }

    fn addSandboxDenialDiagnostic(
        self: *NativeHostApi,
        operation: enforcement.Operation,
        path: []const u8,
        sandbox_root: ?[]const u8,
    ) !void {
        var envelope: std.Io.Writer.Allocating = .init(self.runtime.allocator);
        defer envelope.deinit();
        const required_capability = operation.requiredGrant();
        try envelope.writer.writeAll("{\"category\":\"sandbox_path_denied\",\"capability\":");
        try std.json.Stringify.value(required_capability.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"branch\":");
        try std.json.Stringify.value(required_capability.enforcementBranch().jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"phase\":\"initialize\",\"mode\":\"native/host-api\"");
        try envelope.writer.writeAll(",\"principal\":{\"runtimeKind\":\"native\",\"extensionId\":");
        try std.json.Stringify.value(self.runtime.descriptor.id, .{}, &envelope.writer);
        if (self.runtime.policy_lookup_key) |policy_lookup_key| {
            try envelope.writer.writeAll(",\"policyLookupKey\":");
            try std.json.Stringify.value(policy_lookup_key, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll(",\"packageRoot\":\"native://static\"}");
        try envelope.writer.writeAll(",\"operation\":");
        try std.json.Stringify.value(operation.jsonName(), .{}, &envelope.writer);
        const diagnostic_path = enforcement.diagnosticTargetId(operation, .{ .id = path }) orelse path;
        try envelope.writer.writeAll(",\"target\":{\"id\":");
        try std.json.Stringify.value(diagnostic_path, .{}, &envelope.writer);
        try envelope.writer.writeAll("},\"path\":");
        try std.json.Stringify.value(diagnostic_path, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"policy\":{\"source\":\"native.host_effects.sandbox_root\",\"decision\":\"deny\"");
        if (self.runtime.policy_lookup_key) |policy_lookup_key| {
            try envelope.writer.writeAll(",\"policyLookupKey\":");
            try std.json.Stringify.value(policy_lookup_key, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("},\"sandbox\":{\"root\":");
        if (sandbox_root) |root| {
            try std.json.Stringify.value(root, .{}, &envelope.writer);
        } else {
            try envelope.writer.writeAll("null");
        }
        try envelope.writer.writeAll("},\"reason\":\"path is outside native sandbox root\"");
        try envelope.writer.writeAll(",\"source\":{\"runtimeKind\":\"native\",\"descriptorId\":");
        try std.json.Stringify.value(self.runtime.descriptor.id, .{}, &envelope.writer);
        if (self.runtime.descriptor.tools.len > 0) {
            try envelope.writer.writeAll(",\"extensionPath\":");
            try std.json.Stringify.value(self.runtime.descriptor.tools[0].extension_path, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("}");
        try envelope.writer.writeAll(",\"message\":\"native sandbox denied filesystem path outside approved root\"}");
        try self.runtime.state.addDiagnostic(.host_error, .@"error", envelope.written());
    }
};

pub const NativeRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: extension_host.ProtocolState,
    mutex: std.Io.Mutex = .init,
    descriptor: *const NativeDescriptor,
    approved_capabilities: []const capability.Capability,
    resource_limits: NativeResourceLimits,
    policy_lookup_key: ?[]const u8,
    accounting: enforcement.Accounting,
    host_effects: ?*NativeHostEffects,
    tool_bindings: []NativeToolBinding,
    unloaded: bool,
    /// If non-null, points to a heap-allocated descriptor that was built from a
    /// manifest (e.g. by native_extension_loader). Deinit frees this memory.
    owned_descriptor: ?*NativeDescriptor = null,
    owned_descriptor_allocator: ?std.mem.Allocator = null,
    /// Dynamic library handle loaded by native_extension_loader. Closed on deinit.
    dyn_lib: ?dynamic_library.Handle = null,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: NativeOptions) !*NativeRuntime {
        try options.descriptor.validate(allocator);
        const effective_resource_limits = options.resource_limits orelse options.descriptor.resource_limits;
        try effective_resource_limits.validate();
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
            .resource_limits = effective_resource_limits,
            .policy_lookup_key = options.policy_lookup_key,
            .accounting = .{},
            .host_effects = options.host_effects,
            .tool_bindings = tool_bindings,
            .unloaded = false,
            .dyn_lib = null,
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
        runtime.dyn_lib = options.dyn_lib;
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

    pub fn hasRegisteredHook(self: *NativeRuntime, event_name: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.registry.hasHook(event_name);
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
                    .source = .extension,
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

    pub fn invokeExtensionEvent(
        self: *NativeRuntime,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        event: std.json.Value,
        timeout_ms: u64,
    ) !?std.json.Value {
        _ = timeout_ms;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.unloaded) {
            try self.state.addDiagnostic(.host_error, .warning, "native stale hook invocation rejected after runtime unload");
            return null;
        }
        if (!self.state.registry.hasHook(event_name)) return null;
        if (self.host_effects) |effects| effects.extension_event_invocations += 1;
        if (eventFailsRuntime(event, "native")) {
            try self.state.addDiagnostic(.host_error, .warning, "native hook returned configured non-fatal error");
            return null;
        }
        return try runtimeHookMutationResult(allocator, "native", self.descriptor.id, event);
    }

    pub fn shutdown(self: *NativeRuntime) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.cleanupForUnload();
        self.state.shutdown_complete_seen = true;
    }

    pub fn deinit(self: *NativeRuntime) void {
        const owned = self.owned_descriptor;
        const owned_allocator = self.owned_descriptor_allocator;
        self.cleanupForUnload();
        self.state.deinit();
        self.allocator.free(self.tool_bindings);
        if (self.dyn_lib) |*dyn_lib| dyn_lib.close();
        if (owned) |desc| {
            if (owned_allocator) |alloc| {
                freeOwnedNativeDescriptor(alloc, desc);
                alloc.destroy(desc);
            }
        }
        self.allocator.destroy(self);
    }

    fn cleanupForUnload(self: *NativeRuntime) void {
        self.state.closePendingRequests();
        for (self.descriptor.tools) |tool| {
            _ = self.state.registry.unregisterTool(tool.name);
        }
        for (self.descriptor.hooks) |hook| {
            _ = self.state.registry.unregisterHook(hook.event_name, hook.extension_path);
        }
        self.unloaded = true;
    }
};

pub fn defaultNativeStart(api: *NativeHostApi) !void {
    try api.ready();
    for (api.runtime.descriptor.tools) |tool| {
        try api.registerTool(tool);
    }
    for (api.runtime.descriptor.hooks) |hook| {
        try api.registerHook(hook);
    }
}

fn eventFailsRuntime(event: std.json.Value, runtime_name: []const u8) bool {
    if (event != .object) return false;
    const value = event.object.get("failRuntime") orelse event.object.get("fail_runtime") orelse return false;
    return value == .string and std.mem.eql(u8, value.string, runtime_name);
}

fn runtimeHookMutationResult(
    allocator: std.mem.Allocator,
    runtime_name: []const u8,
    extension_id: []const u8,
    event: std.json.Value,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = object });
    const input_text = if (event == .object) blk: {
        const value = event.object.get("text") orelse break :blk "";
        break :blk if (value == .string) value.string else "";
    } else "";
    const mutated = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ input_text, runtime_name });
    errdefer allocator.free(mutated);
    try tools_common.putValue(allocator, &object, "text", .{ .string = mutated });
    try tools_common.putString(allocator, &object, "runtime", runtime_name);
    try tools_common.putString(allocator, &object, "extensionId", extension_id);
    return .{ .object = object };
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

    var api = NativeHostApi{ .runtime = binding.runtime };
    var ctx = sdk.ToolContext{
        .allocator = allocator,
        .tool_call_id = tool_call_id,
        .params = params,
        .signal = signal,
        .on_update_context = on_update_context,
        .on_update = on_update,
        .host_api_vtable = &native_host_api_vtable,
        .host_api_ctx = &api,
    };

    return execute(&ctx) catch |err| switch (err) {
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

/// Free all memory owned by a heap-allocated NativeDescriptor that was built
/// from a manifest (e.g. by native_extension_loader).
pub fn freeOwnedNativeDescriptor(allocator: std.mem.Allocator, descriptor: *NativeDescriptor) void {
    for (descriptor.tools) |*tool| {
        allocator.free(tool.name);
        allocator.free(tool.label);
        allocator.free(tool.description);
        allocator.free(tool.input_schema_json);
        if (tool.output_schema_json) |s| allocator.free(s);
        allocator.free(tool.extension_path);
    }
    allocator.free(descriptor.tools);
    for (descriptor.hooks) |*hook| {
        allocator.free(hook.event_name);
        allocator.free(hook.extension_path);
    }
    allocator.free(descriptor.hooks);
    allocator.free(descriptor.requested_capabilities);
    allocator.free(descriptor.id);
    allocator.free(descriptor.name);
    allocator.free(descriptor.version);
    allocator.free(descriptor.description);
    if (descriptor.dynamic_library_path) |p| allocator.free(p);
}

// Host API vtable functions — bridge opaque context to NativeHostApi methods.
fn hostApiReadFile(ctx: *anyopaque, path: []const u8) anyerror![]u8 {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.readFile(path);
}
fn hostApiWriteFile(ctx: *anyopaque, path: []const u8, contents: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.writeFile(path, contents);
}
fn hostApiSpawnProcess(ctx: *anyopaque, options: native_process.ProcessOptions) anyerror!native_process.ProcessResult {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.spawnProcess(options);
}
fn hostApiReadEnv(ctx: *anyopaque, name: []const u8) anyerror![]u8 {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.readEnv(name);
}
fn hostApiRequestNetwork(ctx: *anyopaque, url: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.requestNetwork(url);
}
fn hostApiRunShell(ctx: *anyopaque, command: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.runShell(command);
}
fn hostApiCallModel(ctx: *anyopaque, model: []const u8, payload_json: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.callModel(model, payload_json);
}
fn hostApiReadSession(ctx: *anyopaque, session_id: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.readSession(session_id);
}
fn hostApiWriteSession(ctx: *anyopaque, session_id: []const u8, payload_json: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.writeSession(session_id, payload_json);
}
fn hostApiNotifyUi(ctx: *anyopaque, payload_json: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.notifyUi(payload_json);
}
fn hostApiUseTool(ctx: *anyopaque, name: []const u8, payload_json: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.useTool(name, payload_json);
}
fn hostApiSpawnAgent(ctx: *anyopaque, task_json: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.spawnAgent(task_json);
}
fn hostApiDelegateAgent(ctx: *anyopaque, task_json: []const u8) anyerror!void {
    const self: *NativeHostApi = @ptrCast(@alignCast(ctx));
    return self.delegateAgent(task_json);
}

const native_host_api_vtable: sdk.HostApiVTable = .{
    .readFile = hostApiReadFile,
    .writeFile = hostApiWriteFile,
    .spawnProcess = hostApiSpawnProcess,
    .readEnv = hostApiReadEnv,
    .requestNetwork = hostApiRequestNetwork,
    .runShell = hostApiRunShell,
    .callModel = hostApiCallModel,
    .readSession = hostApiReadSession,
    .writeSession = hostApiWriteSession,
    .notifyUi = hostApiNotifyUi,
    .useTool = hostApiUseTool,
    .spawnAgent = hostApiSpawnAgent,
    .delegateAgent = hostApiDelegateAgent,
};

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

    const read_data = try api.readFile(read_path);
    defer api.runtime.allocator.free(read_data);
    try api.writeFile(write_path, "allowed");
    try api.requestNetwork("fake://network/request");
    try api.runShell("fake-shell --no-side-effects");
    if (api.readEnv("PI_FAKE_ENV")) |env_value| {
        defer api.runtime.allocator.free(env_value);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    try api.callModel("fake-model", "{\"prompt\":\"allowed\"}");
    try api.readSession("session-allowed");
    try api.writeSession("session-allowed", "{\"allowed\":true}");
    try api.notifyUi("{\"message\":\"allowed\"}");
    try api.useTool("native.enforcement.matrix", "{\"allowed\":true}");
    try api.spawnAgent("{\"task\":\"allowed\"}");
    try api.delegateAgent("{\"task\":\"allowed\"}");
}

fn nativeSandboxDenialStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_enforcement_matrix_tool);

    const sandbox_root = (api.runtime.host_effects orelse return error.NativeHostSandboxDenied).sandbox_root orelse return error.NativeHostSandboxDenied;
    const escaped_read_path = try std.fmt.allocPrint(api.runtime.allocator, "{s}/../outside.txt", .{sandbox_root});
    defer api.runtime.allocator.free(escaped_read_path);
    const sibling_write_path = try std.fmt.allocPrint(api.runtime.allocator, "{s}-sibling/write.txt", .{sandbox_root});
    defer api.runtime.allocator.free(sibling_write_path);

    try std.testing.expectError(error.NativeHostSandboxDenied, api.readFile(escaped_read_path));
    try std.testing.expectError(error.NativeHostSandboxDenied, api.writeFile(sibling_write_path, "blocked"));
}

fn nativeAgentLimitBoundaryStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_enforcement_matrix_tool);

    try api.spawnAgent("{\"task\":\"spawn-one\"}");
    try api.spawnAgent("{\"task\":\"spawn-two\"}");
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.spawnAgent("{\"task\":\"spawn-three\"}"));

    try api.delegateAgent("{\"task\":\"delegate-one\"}");
    try api.delegateAgent("{\"task\":\"delegate-two\"}");
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.delegateAgent("{\"task\":\"delegate-three\"}"));
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
    .requested_capabilities = capability.CANONICAL_CAPABILITIES[0..],
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

const native_sandbox_denial_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-sandbox-denial",
    .name = "Native Sandbox Denial",
    .version = "0.1.0",
    .description = "Exercises approved native filesystem operations denied by sandbox path policy.",
    .tools = &.{native_enforcement_matrix_tool},
    .requested_capabilities = &.{ .file_read, .file_write },
    .start = nativeSandboxDenialStart,
};

fn nativeSandboxCanonicalDenialStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_enforcement_matrix_tool);

    const sandbox_root = (api.runtime.host_effects orelse return error.NativeHostSandboxDenied).sandbox_root orelse return error.NativeHostSandboxDenied;
    const read_symlink_path = try std.fs.path.join(api.runtime.allocator, &.{ sandbox_root, "read-link.txt" });
    defer api.runtime.allocator.free(read_symlink_path);
    const linked_dir_write_path = try std.fs.path.join(api.runtime.allocator, &.{ sandbox_root, "linked-dir", "write.txt" });
    defer api.runtime.allocator.free(linked_dir_write_path);

    try std.testing.expectError(error.NativeHostSandboxDenied, api.readFile(read_symlink_path));
    try std.testing.expectError(error.NativeHostSandboxDenied, api.writeFile(linked_dir_write_path, "blocked"));
}

const native_sandbox_canonical_denial_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-sandbox-canonical-denial",
    .name = "Native Sandbox Canonical Denial",
    .version = "0.1.0",
    .description = "Exercises approved native filesystem operations denied after canonical path resolution.",
    .tools = &.{native_enforcement_matrix_tool},
    .requested_capabilities = &.{ .file_read, .file_write },
    .start = nativeSandboxCanonicalDenialStart,
};

const native_agent_limit_boundary_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-agent-limit-boundaries",
    .name = "Native Agent Limit Boundaries",
    .version = "0.1.0",
    .description = "Exercises sub-agent relevant native host gates at exact and exceeded resource limits.",
    .tools = &.{native_enforcement_matrix_tool},
    .requested_capabilities = &.{ .agent_spawn, .agent_delegate },
    .resource_limits = .{
        .turns = 2,
        .max_children = 2,
    },
    .start = nativeAgentLimitBoundaryStart,
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

test "native sandbox boundary rejects lexical escapes and sibling prefixes" {
    var effects = NativeHostEffects{ .sandbox_root = "/tmp/native-sandbox" };
    try effects.recordFileRead(std.testing.io, "/tmp/native-sandbox/read.txt");
    try std.testing.expectError(error.NativeHostSandboxDenied, effects.recordFileRead(std.testing.io, "/tmp/native-sandbox/../outside.txt"));
    try std.testing.expectEqual(@as(u64, 1), effects.file_reads);
}

test "native descriptor rejects dynamic library path at static descriptor boundary" {
    const allocator = std.testing.allocator;
    const descriptor: NativeDescriptor = .{
        .id = "com.pi.native-dynamic-field",
        .name = "Native Dynamic Field",
        .version = "0.1.0",
        .description = "Static descriptor must not smuggle dynamic library internals.",
        .tools = &.{native_enforcement_matrix_tool},
        .dynamic_library_path = "/tmp/native-plugin.dylib",
    };

    try std.testing.expectEqualStrings("dynamic_library_path", descriptor.firstForbiddenField().?);
    try std.testing.expectError(error.ForbiddenNativeDescriptorField, NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &descriptor,
    }));
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
        capability: capability.Capability,
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

    // Create test fixture files so real I/O succeeds within the sandbox.
    const read_fixture_path = try std.fs.path.join(allocator, &.{ sandbox_root, "read.txt" });
    defer allocator.free(read_fixture_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sandbox/read.txt", .data = "hello from sandbox" });

    var effects = NativeHostEffects{ .sandbox_root = sandbox_root };
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &native_allowed_operation_matrix_descriptor,
        .approved_capabilities = capability.CANONICAL_CAPABILITIES[0..],
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

test "native sandbox path denials emit auditable diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sandbox", .default_dir);
    const sandbox_root = try makeNativeAbsoluteTestPath(allocator, tmp, "sandbox");
    defer allocator.free(sandbox_root);

    var effects = NativeHostEffects{ .sandbox_root = sandbox_root };
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &native_sandbox_denial_descriptor,
        .approved_capabilities = &.{ .file_read, .file_write },
        .policy_lookup_key = "native:test-policy:sandbox",
        .host_effects = &effects,
    });
    defer runtime.deinit();

    try runtime.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), runtime.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 2), runtime.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 2), runtime.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqual(@as(u64, 0), effects.file_reads);
    try std.testing.expectEqual(@as(u64, 0), effects.file_writes);

    const expected = [_]struct {
        capability: []const u8,
        operation: []const u8,
        path_fragment: []const u8,
    }{
        .{ .capability = "file.read", .operation = "file.read", .path_fragment = "/../outside.txt" },
        .{ .capability = "file.write", .operation = "file.write", .path_fragment = "-sibling/write.txt" },
    };

    for (expected) |entry| {
        var found = false;
        for (runtime.state.diagnostics.items) |diagnostic| {
            if (std.mem.indexOf(u8, diagnostic.message, "\"category\":\"sandbox_path_denied\"") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"runtimeKind\":\"native\"") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"extensionId\":\"com.pi.native-sandbox-denial\"") != null and
                std.mem.indexOf(u8, diagnostic.message, entry.capability) != null and
                std.mem.indexOf(u8, diagnostic.message, entry.operation) != null and
                std.mem.indexOf(u8, diagnostic.message, entry.path_fragment) != null and
                std.mem.indexOf(u8, diagnostic.message, "\"sandbox\":{\"root\":") != null and
                std.mem.indexOf(u8, diagnostic.message, sandbox_root) != null and
                std.mem.indexOf(u8, diagnostic.message, "\"policy\":{\"source\":\"native.host_effects.sandbox_root\",\"decision\":\"deny\",\"policyLookupKey\":\"native:test-policy:sandbox\"}") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"reason\":\"path is outside native sandbox root\"") != null)
            {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "native sandbox path denials reject canonical symlink escapes before side effects" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sandbox");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/secret.txt", .data = "outside" });

    const sandbox_root = try makeNativeAbsoluteTestPath(allocator, tmp, "sandbox");
    defer allocator.free(sandbox_root);
    const outside_file = try makeNativeAbsoluteTestPath(allocator, tmp, "outside/secret.txt");
    defer allocator.free(outside_file);
    const read_link = try makeNativeAbsoluteTestPath(allocator, tmp, "sandbox/read-link.txt");
    defer allocator.free(read_link);
    try std.Io.Dir.symLinkAbsolute(std.testing.io, outside_file, read_link, .{});
    const outside_dir = try makeNativeAbsoluteTestPath(allocator, tmp, "outside");
    defer allocator.free(outside_dir);
    const linked_dir = try makeNativeAbsoluteTestPath(allocator, tmp, "sandbox/linked-dir");
    defer allocator.free(linked_dir);
    try std.Io.Dir.symLinkAbsolute(std.testing.io, outside_dir, linked_dir, .{});

    var effects = NativeHostEffects{ .sandbox_root = sandbox_root };
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &native_sandbox_canonical_denial_descriptor,
        .approved_capabilities = &.{ .file_read, .file_write },
        .policy_lookup_key = "native:test-policy:canonical-sandbox",
        .host_effects = &effects,
    });
    defer runtime.deinit();

    try runtime.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), runtime.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 2), runtime.diagnosticCount());
    try std.testing.expectEqual(@as(u64, 0), effects.file_reads);
    try std.testing.expectEqual(@as(u64, 0), effects.file_writes);
    try std.testing.expectEqual(@as(u64, 2), runtime.accounting.denied_operations);
}

test "native agent host operation gates enforce exact and exceeded resource boundaries" {
    const allocator = std.testing.allocator;
    var effects = NativeHostEffects{};
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &native_agent_limit_boundary_descriptor,
        .approved_capabilities = &.{ .agent_spawn, .agent_delegate },
        .host_effects = &effects,
    });
    defer runtime.deinit();

    try runtime.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), runtime.registryFramesApplied());
    try std.testing.expectEqual(@as(u64, 2), effects.agent_spawns);
    try std.testing.expectEqual(@as(u64, 2), effects.agent_delegations);
    try std.testing.expectEqual(@as(u64, 4), effects.total());
    try std.testing.expectEqual(@as(u64, 4), runtime.accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 2), runtime.accounting.children_started);
    try std.testing.expectEqual(@as(u64, 2), runtime.accounting.turns);
    try std.testing.expectEqual(@as(u64, 2), runtime.accounting.denied_operations);
    try std.testing.expectEqual(@as(usize, 2), runtime.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 2), runtime.diagnosticCategoryCount(.host_error));

    var max_children_denial = false;
    var turns_denial = false;
    for (runtime.state.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, "\"operation\":\"agent.spawn\"") != null and
            std.mem.indexOf(u8, diagnostic.message, "\"reason\":\"resource limit exceeded: maxChildren\"") != null)
        {
            max_children_denial = true;
        }
        if (std.mem.indexOf(u8, diagnostic.message, "\"operation\":\"agent.delegate\"") != null and
            std.mem.indexOf(u8, diagnostic.message, "\"reason\":\"resource limit exceeded: turns\"") != null)
        {
            turns_denial = true;
        }
    }
    try std.testing.expect(max_children_denial);
    try std.testing.expect(turns_denial);
}

const tool_context_test_descriptor: NativeDescriptor = .{
    .id = "com.pi.tool-context-test",
    .name = "Tool Context Test",
    .version = "0.1.0",
    .description = "Validates that ToolContext reaches the native tool execute function.",
    .tools = &.{.{
        .name = "native.tool.context.probe",
        .label = "Tool Context Probe",
        .description = "Echoes back tool_call_id and params through the result.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}}",
        .extension_path = "native://tool-context/probe",
        .execute = toolContextProbeExecute,
    }},
    .start = toolContextProbeStart,
};

fn toolContextProbeStart(api: *NativeHostApi) !void {
    try api.ready();
    for (api.runtime.descriptor.tools) |tool| {
        try api.registerTool(tool);
    }
}

fn toolContextProbeExecute(ctx: *sdk.ToolContext) !agent.AgentToolResult {
    const value = if (ctx.params == .object) blk: {
        const field = ctx.params.object.get("value") orelse break :blk "no-value";
        break :blk switch (field) {
            .string => |text| text,
            else => "no-value",
        };
    } else "no-value";

    const text = try std.fmt.allocPrint(ctx.allocator, "id={s} value={s}", .{ ctx.tool_call_id, value });
    defer ctx.allocator.free(text);

    return .{
        .content = try tools_common.makeTextContent(ctx.allocator, text),
        .details = .{ .object = blk: {
            var obj = try std.json.ObjectMap.init(ctx.allocator, &.{}, &.{});
            try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "received_tool_call_id"), .{ .string = try ctx.allocator.dupe(u8, ctx.tool_call_id) });
            try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "received_value"), .{ .string = try ctx.allocator.dupe(u8, value) });
            break :blk obj;
        } },
    };
}

test "native tool execute receives full ToolContext" {
    const allocator = std.testing.allocator;
    const runtime = try NativeRuntime.start(allocator, std.testing.io, .{
        .descriptor = &tool_context_test_descriptor,
    });
    defer runtime.deinit();

    try runtime.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), runtime.registryFramesApplied());

    const tool = try runtime.agentTool(allocator, "native.tool.context.probe");
    try std.testing.expect(tool != null);
    defer if (tool) |*t| {
        if (t.deinit_execute_context) |deinit_ctx| {
            deinit_ctx(allocator, t.execute_context);
        }
        tools_common.deinitJsonValue(allocator, t.parameters);
    };

    const args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"hello-context\"}", .{});
    defer args.deinit();

    const result = try tool.?.execute.?(allocator, "call-123", args.value, tool.?.execute_context, null, null, null);
    defer {
        for (result.content) |block| {
            if (block == .text) allocator.free(block.text.text);
        }
        allocator.free(result.content);
        if (result.details) |*d| tools_common.deinitJsonValue(allocator, d.*);
    }

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings("id=call-123 value=hello-context", result.content[0].text.text);
    try std.testing.expect(result.details != null);
    const detail_id = result.details.?.object.get("received_tool_call_id").?;
    try std.testing.expectEqualStrings("call-123", detail_id.string);
}
