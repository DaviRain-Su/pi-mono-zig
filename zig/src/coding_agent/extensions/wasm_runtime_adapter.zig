const std = @import("std");
const agent = @import("agent");
const enforcement = @import("enforcement.zig");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const tools_common = @import("../tools/common.zig");
const wasm_host = @import("wasm/zwasm_host.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const policy_resource_helpers = @import("policy_resource_helpers.zig");

const DiagnosticCategory = runtime_adapter.DiagnosticCategory;
const ExtensionUiRequest = runtime_adapter.ExtensionUiRequest;
const RegistryCallback = runtime_adapter.RegistryCallback;
const RuntimeAdapter = runtime_adapter.RuntimeAdapter;
const RuntimeHookDefinition = runtime_adapter.RuntimeHookDefinition;
const WasmManifestHandoff = runtime_adapter.WasmManifestHandoff;
const WasmOptions = runtime_adapter.WasmOptions;

const cloneEnforcementResourceLimits = policy_resource_helpers.cloneEnforcementResourceLimits;
const deinitEnforcementResourceLimits = policy_resource_helpers.deinitEnforcementResourceLimits;

const OwnedWasmManifest = struct {
    package_root: ?[]u8,
    manifest_path: ?[]u8,
    schema_version: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    artifact_kind: wasm_manifest.ArtifactKind,
    artifact_path: []u8,
    artifact_absolute_path: []u8,
    artifact_sha256: ?[]u8,
    package_root_sha256: ?[]u8,
    tool_id: []u8,
    tool_description: []u8,
    input_schema_json: []u8,
    output_schema_json: []u8,
    hooks: []RuntimeHookDefinition,
    requested_capabilities: []wasm_manifest.Capability,
    resource_limits: enforcement.ResourceLimits,
    policy_lookup_key: ?[]u8,

    fn clone(allocator: std.mem.Allocator, handoff: WasmManifestHandoff) !OwnedWasmManifest {
        const package_root = if (handoff.package_root) |value| try allocator.dupe(u8, value) else null;
        errdefer if (package_root) |value| allocator.free(value);
        const manifest_path = if (handoff.manifest_path) |value| try allocator.dupe(u8, value) else null;
        errdefer if (manifest_path) |value| allocator.free(value);
        const schema_version = try allocator.dupe(u8, handoff.schema_version);
        errdefer allocator.free(schema_version);
        const id = try allocator.dupe(u8, handoff.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, handoff.name);
        errdefer allocator.free(name);
        const version = try allocator.dupe(u8, handoff.version);
        errdefer allocator.free(version);
        const description = try allocator.dupe(u8, handoff.description);
        errdefer allocator.free(description);
        const artifact_path = try allocator.dupe(u8, handoff.artifact_path);
        errdefer allocator.free(artifact_path);
        const artifact_absolute_path = try allocator.dupe(u8, handoff.artifact_absolute_path);
        errdefer allocator.free(artifact_absolute_path);
        const artifact_sha256 = if (handoff.artifact_sha256) |value| try allocator.dupe(u8, value) else null;
        errdefer if (artifact_sha256) |value| allocator.free(value);
        const package_root_sha256 = if (handoff.package_root_sha256) |value| try allocator.dupe(u8, value) else null;
        errdefer if (package_root_sha256) |value| allocator.free(value);
        const tool_id = try allocator.dupe(u8, handoff.tool_id);
        errdefer allocator.free(tool_id);
        const tool_description = try allocator.dupe(u8, handoff.tool_description);
        errdefer allocator.free(tool_description);
        const input_schema_json = try allocator.dupe(u8, handoff.input_schema_json);
        errdefer allocator.free(input_schema_json);
        const output_schema_json = try allocator.dupe(u8, handoff.output_schema_json);
        errdefer allocator.free(output_schema_json);
        const hooks = try cloneRuntimeHooks(allocator, handoff.hooks);
        errdefer freeRuntimeHooks(allocator, hooks);
        const requested_capabilities = try allocator.dupe(wasm_manifest.Capability, handoff.requested_capabilities);
        errdefer allocator.free(requested_capabilities);
        var resource_limits = try cloneEnforcementResourceLimits(allocator, handoff.resource_limits);
        errdefer deinitEnforcementResourceLimits(allocator, &resource_limits);
        const policy_lookup_key = if (handoff.policy_lookup_key) |value| try allocator.dupe(u8, value) else null;
        errdefer if (policy_lookup_key) |value| allocator.free(value);
        return .{
            .package_root = package_root,
            .manifest_path = manifest_path,
            .schema_version = schema_version,
            .id = id,
            .name = name,
            .version = version,
            .description = description,
            .artifact_kind = handoff.artifact_kind,
            .artifact_path = artifact_path,
            .artifact_absolute_path = artifact_absolute_path,
            .artifact_sha256 = artifact_sha256,
            .package_root_sha256 = package_root_sha256,
            .tool_id = tool_id,
            .tool_description = tool_description,
            .input_schema_json = input_schema_json,
            .output_schema_json = output_schema_json,
            .hooks = hooks,
            .requested_capabilities = requested_capabilities,
            .resource_limits = resource_limits,
            .policy_lookup_key = policy_lookup_key,
        };
    }

    fn deinit(self: *OwnedWasmManifest, allocator: std.mem.Allocator) void {
        if (self.package_root) |value| allocator.free(value);
        if (self.manifest_path) |value| allocator.free(value);
        allocator.free(self.schema_version);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.artifact_path);
        allocator.free(self.artifact_absolute_path);
        if (self.artifact_sha256) |value| allocator.free(value);
        if (self.package_root_sha256) |value| allocator.free(value);
        allocator.free(self.tool_id);
        allocator.free(self.tool_description);
        allocator.free(self.input_schema_json);
        allocator.free(self.output_schema_json);
        freeRuntimeHooks(allocator, self.hooks);
        allocator.free(self.requested_capabilities);
        deinitEnforcementResourceLimits(allocator, &self.resource_limits);
        if (self.policy_lookup_key) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn cloneRuntimeHooks(
    allocator: std.mem.Allocator,
    hooks: []const RuntimeHookDefinition,
) ![]RuntimeHookDefinition {
    const cloned = try allocator.alloc(RuntimeHookDefinition, hooks.len);
    errdefer allocator.free(cloned);
    for (hooks, 0..) |hook, index| {
        cloned[index] = .{
            .event_name = try allocator.dupe(u8, hook.event_name),
            .extension_path = try allocator.dupe(u8, hook.extension_path),
            .priority = hook.priority,
            .declaration_order = hook.declaration_order,
            .error_policy = hook.error_policy,
        };
        errdefer {
            allocator.free(cloned[index].event_name);
            allocator.free(cloned[index].extension_path);
        }
    }
    return cloned;
}

fn freeRuntimeHooks(allocator: std.mem.Allocator, hooks: []RuntimeHookDefinition) void {
    for (hooks) |hook| {
        allocator.free(hook.event_name);
        allocator.free(hook.extension_path);
    }
    allocator.free(hooks);
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
    try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = mutated });
    try object.put(allocator, try allocator.dupe(u8, "runtime"), .{ .string = try allocator.dupe(u8, runtime_name) });
    try object.put(allocator, try allocator.dupe(u8, "extensionId"), .{ .string = try allocator.dupe(u8, extension_id) });
    return .{ .object = object };
}

pub const WasmRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: extension_host.ProtocolState,
    mutex: std.Io.Mutex = .init,
    manifest: OwnedWasmManifest,
    host: wasm_host.Host,
    accounting: enforcement.Accounting,
    unloaded: bool,

    fn start(allocator: std.mem.Allocator, io: std.Io, options: WasmOptions) !*WasmRuntime {
        try options.manifest.validate();
        var owned_manifest = try OwnedWasmManifest.clone(allocator, options.manifest);
        errdefer owned_manifest.deinit(allocator);
        var host = try wasm_host.Host.loadFromFile(allocator, io, options.manifest.artifact_absolute_path);
        errdefer host.deinit();
        host.setToolId(owned_manifest.tool_id);
        try validateWasmArtifactHandoff(allocator, &host, options.manifest);

        const runtime = try allocator.create(WasmRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{
            .allocator = allocator,
            .io = io,
            .state = extension_host.ProtocolState.init(allocator),
            .manifest = owned_manifest,
            .host = host,
            .accounting = .{},
            .unloaded = false,
        };
        errdefer runtime.state.deinit();
        runtime.state.ready_seen = true;
        try runtime.registerManifestTool();
        try runtime.registerManifestHooks();
        return runtime;
    }

    fn registerManifestTool(self: *WasmRuntime) !void {
        var parsed_parameters = try std.json.parseFromSlice(std.json.Value, self.allocator, self.manifest.input_schema_json, .{});
        defer parsed_parameters.deinit();
        try self.state.registry.registerToolFull(
            self.manifest.tool_id,
            self.manifest.tool_id,
            self.manifest.tool_description,
            parsed_parameters.value,
            null,
            null,
            self.manifest.artifact_absolute_path,
        );
        self.state.registry_frames_applied += 1;
    }

    fn registerManifestHooks(self: *WasmRuntime) !void {
        for (self.manifest.hooks) |hook| {
            try self.state.registry.registerHookFull(
                hook.event_name,
                hook.extension_path,
                hook.priority,
                hook.declaration_order,
                hook.error_policy,
            );
            self.state.registry_frames_applied += 1;
        }
    }

    fn cleanupForUnload(self: *WasmRuntime) void {
        self.state.clearPendingRequests();
        if (!self.unloaded) {
            self.host.unload(&self.state.registry, self.manifest.tool_id);
            for (self.manifest.hooks) |hook| {
                _ = self.state.registry.unregisterHook(hook.event_name, hook.extension_path);
            }
            self.unloaded = true;
            return;
        }
        _ = self.state.registry.unregisterTool(self.manifest.tool_id);
        for (self.manifest.hooks) |hook| {
            _ = self.state.registry.unregisterHook(hook.event_name, hook.extension_path);
        }
    }

    fn invokeExtensionEvent(
        self: *WasmRuntime,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        event: std.json.Value,
        timeout_ms: u64,
    ) !?std.json.Value {
        _ = timeout_ms;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.unloaded) {
            try self.state.addDiagnostic(.host_error, .warning, "wasm stale hook invocation rejected after runtime unload");
            return null;
        }
        if (!self.state.registry.hasHook(event_name)) return null;
        if (eventFailsRuntime(event, "wasm")) {
            try self.state.addDiagnostic(.host_error, .warning, "wasm hook returned configured non-fatal error");
            return null;
        }
        return try runtimeHookMutationResult(allocator, "wasm", self.manifest.id, event);
    }

    fn addObservableDiagnostic(
        self: *WasmRuntime,
        phase: wasm_manifest.LifecyclePhase,
        category: []const u8,
        path: []const u8,
        capability: ?wasm_manifest.Capability,
        message: []const u8,
    ) !void {
        var envelope: std.Io.Writer.Allocating = .init(self.allocator);
        defer envelope.deinit();
        try envelope.writer.writeAll("{\"phase\":");
        try std.json.Stringify.value(phase.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"category\":");
        try std.json.Stringify.value(category, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"capability\":");
        if (capability) |capability_value| {
            try std.json.Stringify.value(capability_value.jsonName(), .{}, &envelope.writer);
        } else {
            try envelope.writer.writeAll("null");
        }
        try envelope.writer.writeAll(",\"message\":");
        try std.json.Stringify.value(message, .{}, &envelope.writer);
        try envelope.writer.writeAll("}");
        try self.state.addDiagnostic(.host_error, .@"error", envelope.written());
    }

    fn enforceToolExecution(
        self: *WasmRuntime,
        delta: enforcement.UsageDelta,
    ) !void {
        const approved_tool_use = [_]wasm_manifest.Capability{.tool_use};
        const decision = enforcement.decide(
            .{
                .runtime_kind = "wasm",
                .extension_id = self.manifest.id,
                .policy_lookup_key = self.manifest.policy_lookup_key,
                .package_root = self.manifest.package_root,
            },
            .{
                .approved_grants = approved_tool_use[0..],
                .resource_limits = self.manifest.resource_limits,
            },
            .tool_use,
            .{ .id = self.manifest.tool_id },
            .call,
            "wasm/tool-execute",
            delta,
            &self.accounting,
        );
        switch (decision) {
            .allow => return,
            .deny => |denial| {
                try self.addDenialDiagnostic(denial);
                return error.UnsupportedRuntimeCapability;
            },
        }
    }

    fn addDenialDiagnostic(self: *WasmRuntime, denial: enforcement.DenyDecision) !void {
        var envelope: std.Io.Writer.Allocating = .init(self.allocator);
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
        if (denial.principal.policy_lookup_key) |policy_lookup_key| {
            try envelope.writer.writeAll(",\"policyLookupKey\":");
            try std.json.Stringify.value(policy_lookup_key, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll(",\"toolId\":");
        try std.json.Stringify.value(self.manifest.tool_id, .{}, &envelope.writer);
        try envelope.writer.writeAll("},\"operation\":");
        try std.json.Stringify.value(denial.operation.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"target\":{\"id\":");
        if (enforcement.diagnosticTargetId(denial.operation, denial.target)) |target_id| {
            try std.json.Stringify.value(target_id, .{}, &envelope.writer);
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
        try envelope.writer.writeAll(",\"source\":{");
        var wrote_source = false;
        if (self.manifest.manifest_path) |manifest_path| {
            try envelope.writer.writeAll("\"manifestPath\":");
            try std.json.Stringify.value(manifest_path, .{}, &envelope.writer);
            wrote_source = true;
        }
        if (self.manifest.package_root) |package_root| {
            if (wrote_source) try envelope.writer.writeAll(",");
            try envelope.writer.writeAll("\"packageRoot\":");
            try std.json.Stringify.value(package_root, .{}, &envelope.writer);
            wrote_source = true;
        }
        if (wrote_source) try envelope.writer.writeAll(",");
        try envelope.writer.writeAll("\"artifactPath\":");
        try std.json.Stringify.value(self.manifest.artifact_path, .{}, &envelope.writer);
        if (self.manifest.artifact_sha256) |artifact_sha256| {
            try envelope.writer.writeAll(",\"artifactSha256\":");
            try std.json.Stringify.value(artifact_sha256, .{}, &envelope.writer);
        }
        if (self.manifest.package_root_sha256) |package_root_sha256| {
            try envelope.writer.writeAll(",\"packageRootSha256\":");
            try std.json.Stringify.value(package_root_sha256, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("}");
        try envelope.writer.writeAll(",\"message\":\"wasm tool execution denied by enforcement substrate\"}");
        try self.state.addDiagnostic(.host_error, .@"error", envelope.written());
    }

    fn deinit(self: *WasmRuntime) void {
        self.cleanupForUnload();
        self.host.deinit();
        self.state.deinit();
        self.manifest.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn validateWasmArtifactHandoff(
    allocator: std.mem.Allocator,
    host: *const wasm_host.Host,
    manifest: WasmManifestHandoff,
) !void {
    const metadata_json = try host.callMetadata();
    defer allocator.free(metadata_json);
    var metadata = std.json.parseFromSlice(std.json.Value, allocator, metadata_json, .{}) catch return error.WasmManifestMetadataMismatch;
    defer metadata.deinit();
    if (metadata.value != .object) return error.WasmManifestMetadataMismatch;
    const metadata_id = jsonStringField(metadata.value.object, "id") orelse return error.WasmManifestMetadataMismatch;
    if (!std.mem.eql(u8, metadata_id, manifest.tool_id)) return error.WasmManifestMetadataMismatch;

    const schema_json = try host.callSchema();
    defer allocator.free(schema_json);
    var schema = std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{}) catch return error.WasmManifestSchemaMismatch;
    defer schema.deinit();
    if (schema.value != .object) return error.WasmManifestSchemaMismatch;
    const input_schema = schema.value.object.get("inputSchema") orelse return error.WasmManifestSchemaMismatch;
    const output_schema = schema.value.object.get("outputSchema") orelse return error.WasmManifestSchemaMismatch;
    const input_schema_json = try std.json.Stringify.valueAlloc(allocator, input_schema, .{});
    defer allocator.free(input_schema_json);
    const output_schema_json = try std.json.Stringify.valueAlloc(allocator, output_schema, .{});
    defer allocator.free(output_schema_json);
    if (!std.mem.eql(u8, input_schema_json, manifest.input_schema_json)) return error.WasmManifestSchemaMismatch;
    if (!std.mem.eql(u8, output_schema_json, manifest.output_schema_json)) return error.WasmManifestSchemaMismatch;
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn startWasm(allocator: std.mem.Allocator, io: std.Io, options: WasmOptions) !RuntimeAdapter {
    const runtime = try WasmRuntime.start(allocator, io, options);
    return .{
        .ptr = @ptrCast(runtime),
        .vtable = &wasm_vtable,
        .kind = .wasm,
    };
}

pub fn wasmRuntime(ptr: *anyopaque) *WasmRuntime {
    return @ptrCast(@alignCast(ptr));
}

fn wasmWaitForReady(ptr: *anyopaque, timeout_ms: u64) !void {
    _ = timeout_ms;
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    if (runtime.state.ready_seen) return;
    return error.HostNotReady;
}

fn wasmPendingCount(ptr: *anyopaque) usize {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.pendingCount();
}

fn wasmDiagnosticCount(ptr: *anyopaque) usize {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.diagnostics.items.len;
}

fn wasmDiagnosticCategoryCount(ptr: *anyopaque, category: DiagnosticCategory) usize {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.diagnosticCategoryCount(category);
}

fn wasmHasShutdownComplete(ptr: *anyopaque) bool {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.shutdown_complete_seen;
}

fn wasmRegistryFramesApplied(ptr: *anyopaque) usize {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.registry_frames_applied;
}

fn wasmHasRegisteredCommand(ptr: *anyopaque, name: []const u8) bool {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.registry.hasCommandInvocation(name);
}

fn wasmSnapshotRegistryJson(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try extension_registry.writeRegistrySnapshotJson(allocator, &runtime.state.registry, &out.writer);
    return try allocator.dupe(u8, out.written());
}

fn wasmWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: RegistryCallback) !void {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    try callback(context, &runtime.state.registry);
}

fn wasmApplyCliFlagValues(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    for (entries) |entry| {
        _ = try runtime.state.registry.setFlagValue(entry.name, entry.value);
    }
}

fn wasmAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    for (runtime.state.registry.tools.items) |tool| {
        if (!std.mem.eql(u8, tool.name, name)) continue;
        return .{
            .name = tool.name,
            .description = tool.description,
            .label = tool.label,
            .parameters = try tools_common.cloneJsonValue(allocator, tool.parameters),
            .source = .extension,
            .execute = wasmAgentToolExecute,
            .execute_context = runtime,
        };
    }
    return null;
}

fn wasmAgentToolExecute(
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
    const runtime: *WasmRuntime = @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
    const input_json = try std.json.Stringify.valueAlloc(allocator, params, .{});
    defer allocator.free(input_json);

    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    var registered = false;
    for (runtime.state.registry.tools.items) |tool| {
        if (std.mem.eql(u8, tool.name, runtime.manifest.tool_id)) {
            registered = true;
            break;
        }
    }
    if (!registered) return error.WasmToolNotRegistered;
    try runtime.enforceToolExecution(.{ .turns = 1 });

    const output_json = runtime.host.callExecute(input_json) catch |err| switch (err) {
        error.InvalidJsonInput => {
            try runtime.addObservableDiagnostic(
                .call,
                "invalid_input",
                "$.execute",
                null,
                "execute input must be a JSON object",
            );
            return invalidInputAgentToolResult(allocator, runtime);
        },
        else => return err,
    };
    defer runtime.allocator.free(output_json);
    try runtime.enforceToolExecution(.{
        .output_bytes = output_json.len,
        .output_lines = countLogicalLines(output_json),
    });
    const details = try wasmRuntimeDetailsJson(allocator, runtime);
    errdefer if (details) |value| tools_common.deinitJsonValue(allocator, value);
    return .{
        .content = try tools_common.makeTextContent(allocator, output_json),
        .details = details,
    };
}

fn invalidInputAgentToolResult(allocator: std.mem.Allocator, runtime: *const WasmRuntime) !agent.AgentToolResult {
    const details = try wasmRuntimeDetailsJson(allocator, runtime);
    errdefer if (details) |value| tools_common.deinitJsonValue(allocator, value);
    return .{
        .content = try tools_common.makeTextContent(
            allocator,
            "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object\"}}",
        ),
        .details = details,
        .is_error = true,
    };
}

fn wasmRuntimeDetailsJson(allocator: std.mem.Allocator, runtime: *const WasmRuntime) !?std.json.Value {
    if (runtime.manifest.policy_lookup_key == null) return null;

    var runtime_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = runtime_object });

    try putJsonString(allocator, &runtime_object, "runtimeKind", "wasm");
    try putJsonString(allocator, &runtime_object, "extensionId", runtime.manifest.id);
    try putJsonString(allocator, &runtime_object, "extensionName", runtime.manifest.name);
    try putJsonString(allocator, &runtime_object, "extensionVersion", runtime.manifest.version);
    try putJsonString(allocator, &runtime_object, "toolId", runtime.manifest.tool_id);
    try putOptionalJsonString(allocator, &runtime_object, "packageRoot", runtime.manifest.package_root);
    try putOptionalJsonString(allocator, &runtime_object, "manifestPath", runtime.manifest.manifest_path);
    try putJsonString(allocator, &runtime_object, "artifactPath", runtime.manifest.artifact_absolute_path);
    try putOptionalJsonString(allocator, &runtime_object, "artifactSha256", runtime.manifest.artifact_sha256);
    try putOptionalJsonString(allocator, &runtime_object, "packageRootSha256", runtime.manifest.package_root_sha256);
    try putOptionalJsonString(allocator, &runtime_object, "policyLookupKey", runtime.manifest.policy_lookup_key);

    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = root });
    try root.put(
        allocator,
        try allocator.dupe(u8, "extensionRuntime"),
        .{ .object = runtime_object },
    );
    return .{ .object = root };
}

fn putJsonString(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    try object.put(
        allocator,
        try allocator.dupe(u8, key),
        .{ .string = try allocator.dupe(u8, value) },
    );
}

fn putOptionalJsonString(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |text| {
        try putJsonString(allocator, object, key, text);
    } else {
        try object.put(allocator, try allocator.dupe(u8, key), .null);
    }
}

fn countLogicalLines(value: []const u8) u64 {
    if (value.len == 0) return 0;
    var lines: u64 = 1;
    for (value) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

fn wasmTakeUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    const requests = try allocator.alloc(ExtensionUiRequest, runtime.state.ui_requests.items.len);
    errdefer allocator.free(requests);
    for (runtime.state.ui_requests.items, 0..) |request, index| {
        requests[index] = try ExtensionUiRequest.clone(allocator, request);
    }
    for (runtime.state.ui_requests.items) |*request| request.deinit(runtime.allocator);
    runtime.state.ui_requests.clearRetainingCapacity();
    return requests;
}

fn wasmSendExtensionUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    _ = payload_json;
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    _ = runtime.state.resolvePendingRequest(id);
}

fn wasmSendExtensionEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    _ = ptr;
    _ = frame_json;
}

fn wasmHasRegisteredHook(ptr: *anyopaque, event_name: []const u8) bool {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.state.registry.hasHook(event_name);
}

fn wasmInvokeExtensionEvent(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    return try wasmRuntime(ptr).invokeExtensionEvent(allocator, event_name, event, timeout_ms);
}

fn wasmShutdown(ptr: *anyopaque) !void {
    const runtime = wasmRuntime(ptr);
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    runtime.cleanupForUnload();
    runtime.state.shutdown_complete_seen = true;
}

fn wasmDeinit(ptr: *anyopaque) void {
    wasmRuntime(ptr).deinit();
}

pub const wasm_vtable: RuntimeAdapter.VTable = .{
    .wait_for_ready = wasmWaitForReady,
    .pending_count = wasmPendingCount,
    .diagnostic_count = wasmDiagnosticCount,
    .diagnostic_category_count = wasmDiagnosticCategoryCount,
    .has_shutdown_complete = wasmHasShutdownComplete,
    .registry_frames_applied = wasmRegistryFramesApplied,
    .has_registered_command = wasmHasRegisteredCommand,
    .has_registered_hook = wasmHasRegisteredHook,
    .snapshot_registry_json = wasmSnapshotRegistryJson,
    .with_registry = wasmWithRegistry,
    .apply_cli_flag_values = wasmApplyCliFlagValues,
    .agent_tool = wasmAgentTool,
    .take_ui_requests = wasmTakeUiRequests,
    .send_extension_ui_response = wasmSendExtensionUiResponse,
    .send_extension_event_frame = wasmSendExtensionEventFrame,
    .invoke_extension_event = wasmInvokeExtensionEvent,
    .shutdown = wasmShutdown,
    .deinit = wasmDeinit,
};