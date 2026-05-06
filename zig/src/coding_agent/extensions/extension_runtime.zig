const std = @import("std");
const agent = @import("agent");
const extension_events = @import("extension_events.zig");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const native_runtime = @import("native_runtime.zig");
const tools_common = @import("../tools/common.zig");
const wasm_host = @import("wasm/wasm_host_spike.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");

pub const DiagnosticCategory = extension_host.DiagnosticCategory;
pub const ExtensionUiRequest = extension_host.ExtensionUiRequest;
pub const HOST_MARKER_ENV = extension_host.HOST_MARKER_ENV;
pub const InitializeFrame = extension_host.InitializeFrame;
pub const ProcessJsonlOptions = extension_host.HostProcessOptions;
pub const Registry = extension_registry.Registry;
pub const RegistryCallback = *const fn (context: ?*anyopaque, registry: *const Registry) anyerror!void;
pub const NativeDescriptor = native_runtime.NativeDescriptor;
pub const NativeHostApi = native_runtime.NativeHostApi;
pub const NativeOptions = native_runtime.NativeOptions;
pub const NativeResourceLimits = native_runtime.NativeResourceLimits;
pub const NativeToolDefinition = native_runtime.NativeToolDefinition;

pub const RuntimeKind = enum {
    process_jsonl,
    wasm,
    native,
    remote,

    pub fn jsonName(self: RuntimeKind) []const u8 {
        return switch (self) {
            .process_jsonl => "process_jsonl",
            .wasm => "wasm",
            .native => "native",
            .remote => "remote",
        };
    }
};

pub const UnsupportedRuntimeOptions = struct {
    label: ?[]const u8 = null,
};

pub const WasmManifestHandoff = struct {
    schema_version: []const u8,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    artifact_kind: wasm_manifest.ArtifactKind,
    artifact_path: []const u8,
    artifact_absolute_path: []const u8,
    tool_id: []const u8,
    tool_description: []const u8,
    input_schema_json: []const u8,
    output_schema_json: []const u8,
    requested_capabilities: []const wasm_manifest.Capability = &.{},

    pub fn fromManifest(manifest: *const wasm_manifest.Manifest) WasmManifestHandoff {
        return .{
            .schema_version = manifest.schema_version,
            .id = manifest.id,
            .name = manifest.name,
            .version = manifest.version,
            .description = manifest.description,
            .artifact_kind = manifest.artifact_kind,
            .artifact_path = manifest.artifact_path,
            .artifact_absolute_path = manifest.artifact_absolute_path,
            .tool_id = manifest.tool_id,
            .tool_description = manifest.tool_description,
            .input_schema_json = manifest.input_schema_json,
            .output_schema_json = manifest.output_schema_json,
            .requested_capabilities = manifest.requested_capabilities,
        };
    }

    pub fn validate(self: WasmManifestHandoff) !void {
        if (!std.mem.eql(u8, self.schema_version, wasm_manifest.SCHEMA_VERSION)) return error.InvalidRuntimeOptions;
        if (self.id.len == 0) return error.InvalidRuntimeOptions;
        if (self.name.len == 0) return error.InvalidRuntimeOptions;
        if (self.version.len == 0) return error.InvalidRuntimeOptions;
        if (self.description.len == 0) return error.InvalidRuntimeOptions;
        if (self.artifact_kind != .wasm_component) return error.InvalidRuntimeOptions;
        if (self.artifact_path.len == 0) return error.InvalidRuntimeOptions;
        if (self.artifact_absolute_path.len == 0) return error.InvalidRuntimeOptions;
        if (!std.fs.path.isAbsolute(self.artifact_absolute_path)) return error.InvalidRuntimeOptions;
        if (self.tool_id.len == 0) return error.InvalidRuntimeOptions;
        if (self.tool_description.len == 0) return error.InvalidRuntimeOptions;
        if (self.input_schema_json.len == 0) return error.InvalidRuntimeOptions;
        if (self.output_schema_json.len == 0) return error.InvalidRuntimeOptions;
        if (self.deniedRuntimeCapability(.initialize, "runtime/handoff") != null) return error.UnsupportedRuntimeCapability;
    }

    pub fn deniedRuntimeCapability(
        self: WasmManifestHandoff,
        phase: wasm_manifest.LifecyclePhase,
        mode: []const u8,
    ) ?wasm_manifest.CapabilityDenialDiagnostic {
        return wasm_manifest.denyFirstUnapprovedCapability(self.requested_capabilities, &.{}, phase, mode);
    }
};

pub const WasmOptions = struct {
    manifest: WasmManifestHandoff,
};

pub const RuntimeOptions = union(RuntimeKind) {
    process_jsonl: ProcessJsonlOptions,
    wasm: WasmOptions,
    native: NativeOptions,
    remote: UnsupportedRuntimeOptions,
};

pub const RuntimeAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    kind: RuntimeKind,

    pub const VTable = struct {
        wait_for_ready: *const fn (*anyopaque, u64) anyerror!void,
        pending_count: *const fn (*anyopaque) usize,
        diagnostic_count: *const fn (*anyopaque) usize,
        diagnostic_category_count: *const fn (*anyopaque, DiagnosticCategory) usize,
        has_shutdown_complete: *const fn (*anyopaque) bool,
        registry_frames_applied: *const fn (*anyopaque) usize,
        has_registered_command: *const fn (*anyopaque, []const u8) bool,
        snapshot_registry_json: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        with_registry: *const fn (*anyopaque, ?*anyopaque, RegistryCallback) anyerror!void,
        apply_cli_flag_values: *const fn (*anyopaque, []const extension_registry.ParsedCliFlag) anyerror!void,
        agent_tool: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?agent.AgentTool,
        take_ui_requests: *const fn (*anyopaque, std.mem.Allocator) anyerror![]ExtensionUiRequest,
        send_extension_ui_response: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        send_extension_event_frame: *const fn (*anyopaque, []const u8) void,
        shutdown: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn waitForReady(self: RuntimeAdapter, timeout_ms: u64) !void {
        try self.vtable.wait_for_ready(self.ptr, timeout_ms);
    }

    pub fn pendingCount(self: RuntimeAdapter) usize {
        return self.vtable.pending_count(self.ptr);
    }

    pub fn diagnosticCount(self: RuntimeAdapter) usize {
        return self.vtable.diagnostic_count(self.ptr);
    }

    pub fn diagnosticCategoryCount(self: RuntimeAdapter, category: DiagnosticCategory) usize {
        return self.vtable.diagnostic_category_count(self.ptr, category);
    }

    pub fn hasShutdownComplete(self: RuntimeAdapter) bool {
        return self.vtable.has_shutdown_complete(self.ptr);
    }

    pub fn registryFramesApplied(self: RuntimeAdapter) usize {
        return self.vtable.registry_frames_applied(self.ptr);
    }

    pub fn hasRegisteredCommand(self: RuntimeAdapter, name: []const u8) bool {
        return self.vtable.has_registered_command(self.ptr, name);
    }

    pub fn snapshotRegistryJson(self: RuntimeAdapter, allocator: std.mem.Allocator) ![]u8 {
        return try self.vtable.snapshot_registry_json(self.ptr, allocator);
    }

    pub fn withRegistry(self: RuntimeAdapter, context: ?*anyopaque, callback: RegistryCallback) !void {
        try self.vtable.with_registry(self.ptr, context, callback);
    }

    pub fn applyCliFlagValues(self: RuntimeAdapter, entries: []const extension_registry.ParsedCliFlag) !void {
        try self.vtable.apply_cli_flag_values(self.ptr, entries);
    }

    pub fn agentTool(self: RuntimeAdapter, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
        return try self.vtable.agent_tool(self.ptr, allocator, name);
    }

    pub fn takeUiRequests(self: RuntimeAdapter, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
        return try self.vtable.take_ui_requests(self.ptr, allocator);
    }

    pub fn sendExtensionUiResponse(self: RuntimeAdapter, id: []const u8, payload_json: []const u8) !void {
        try self.vtable.send_extension_ui_response(self.ptr, id, payload_json);
    }

    pub fn sendExtensionEventFrame(self: RuntimeAdapter, frame_json: []const u8) void {
        self.vtable.send_extension_event_frame(self.ptr, frame_json);
    }

    pub fn shutdown(self: RuntimeAdapter) !void {
        try self.vtable.shutdown(self.ptr);
    }

    pub fn deinit(self: RuntimeAdapter) void {
        self.vtable.deinit(self.ptr);
    }
};

pub fn deinitAgentTool(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    tools_common.deinitJsonValue(allocator, tool.parameters);
    tool.* = undefined;
}

pub fn startRuntime(allocator: std.mem.Allocator, io: std.Io, options: RuntimeOptions) !RuntimeAdapter {
    return switch (options) {
        .process_jsonl => |process_options| try startProcessJsonl(allocator, io, process_options),
        .wasm => |wasm_options| try startWasm(allocator, io, wasm_options),
        .native => |native_options| try startNative(allocator, io, native_options),
        .remote => error.UnsupportedRuntime,
    };
}

pub fn startProcessJsonl(allocator: std.mem.Allocator, io: std.Io, options: ProcessJsonlOptions) !RuntimeAdapter {
    const host = try extension_host.HostProcess.start(allocator, io, options);
    return .{
        .ptr = @ptrCast(host),
        .vtable = &process_jsonl_vtable,
        .kind = .process_jsonl,
    };
}

fn processHost(ptr: *anyopaque) *extension_host.HostProcess {
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

fn processSnapshotRegistryJson(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return try processHost(ptr).snapshotRegistryJson(allocator);
}

fn processWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: RegistryCallback) !void {
    try processHost(ptr).withRegistry(context, callback);
}

fn processApplyCliFlagValues(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    try processHost(ptr).applyCliFlagValues(entries);
}

fn processAgentTool(ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
    _ = ptr;
    _ = allocator;
    _ = name;
    return null;
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
    .snapshot_registry_json = processSnapshotRegistryJson,
    .with_registry = processWithRegistry,
    .apply_cli_flag_values = processApplyCliFlagValues,
    .agent_tool = processAgentTool,
    .take_ui_requests = processTakeUiRequests,
    .send_extension_ui_response = processSendExtensionUiResponse,
    .send_extension_event_frame = processSendExtensionEventFrame,
    .shutdown = processShutdown,
    .deinit = processDeinit,
};

const OwnedWasmManifest = struct {
    schema_version: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    artifact_kind: wasm_manifest.ArtifactKind,
    artifact_path: []u8,
    artifact_absolute_path: []u8,
    tool_id: []u8,
    tool_description: []u8,
    input_schema_json: []u8,
    output_schema_json: []u8,
    requested_capabilities: []wasm_manifest.Capability,

    fn clone(allocator: std.mem.Allocator, handoff: WasmManifestHandoff) !OwnedWasmManifest {
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
        const tool_id = try allocator.dupe(u8, handoff.tool_id);
        errdefer allocator.free(tool_id);
        const tool_description = try allocator.dupe(u8, handoff.tool_description);
        errdefer allocator.free(tool_description);
        const input_schema_json = try allocator.dupe(u8, handoff.input_schema_json);
        errdefer allocator.free(input_schema_json);
        const output_schema_json = try allocator.dupe(u8, handoff.output_schema_json);
        errdefer allocator.free(output_schema_json);
        const requested_capabilities = try allocator.dupe(wasm_manifest.Capability, handoff.requested_capabilities);
        errdefer allocator.free(requested_capabilities);
        return .{
            .schema_version = schema_version,
            .id = id,
            .name = name,
            .version = version,
            .description = description,
            .artifact_kind = handoff.artifact_kind,
            .artifact_path = artifact_path,
            .artifact_absolute_path = artifact_absolute_path,
            .tool_id = tool_id,
            .tool_description = tool_description,
            .input_schema_json = input_schema_json,
            .output_schema_json = output_schema_json,
            .requested_capabilities = requested_capabilities,
        };
    }

    fn deinit(self: *OwnedWasmManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.schema_version);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.artifact_path);
        allocator.free(self.artifact_absolute_path);
        allocator.free(self.tool_id);
        allocator.free(self.tool_description);
        allocator.free(self.input_schema_json);
        allocator.free(self.output_schema_json);
        allocator.free(self.requested_capabilities);
        self.* = undefined;
    }
};

const WasmRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state: extension_host.ProtocolState,
    mutex: std.Io.Mutex = .init,
    manifest: OwnedWasmManifest,
    host: wasm_host.Host,
    unloaded: bool,

    fn start(allocator: std.mem.Allocator, io: std.Io, options: WasmOptions) !*WasmRuntime {
        try options.manifest.validate();
        var owned_manifest = try OwnedWasmManifest.clone(allocator, options.manifest);
        errdefer owned_manifest.deinit(allocator);
        var host = try wasm_host.Host.loadFromFile(allocator, io, options.manifest.artifact_absolute_path);
        errdefer host.deinit();
        try validateWasmArtifactHandoff(allocator, &host, options.manifest);

        const runtime = try allocator.create(WasmRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{
            .allocator = allocator,
            .io = io,
            .state = extension_host.ProtocolState.init(allocator),
            .manifest = owned_manifest,
            .host = host,
            .unloaded = false,
        };
        errdefer runtime.state.deinit();
        runtime.state.ready_seen = true;
        try runtime.registerManifestTool();
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

    fn cleanupForUnload(self: *WasmRuntime) void {
        self.state.clearPendingRequests();
        if (!self.unloaded) {
            self.host.unload(&self.state.registry, self.manifest.tool_id);
            self.unloaded = true;
            return;
        }
        _ = self.state.registry.unregisterTool(self.manifest.tool_id);
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

fn wasmRuntime(ptr: *anyopaque) *WasmRuntime {
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

    const output_json = runtime.host.callExecute(input_json) catch |err| switch (err) {
        error.InvalidJsonInput => {
            try runtime.addObservableDiagnostic(
                .call,
                "invalid_input",
                "$.execute",
                null,
                "execute input must be a JSON object",
            );
            return invalidInputAgentToolResult(allocator);
        },
        else => return err,
    };
    defer runtime.allocator.free(output_json);
    return .{ .content = try tools_common.makeTextContent(allocator, output_json) };
}

fn invalidInputAgentToolResult(allocator: std.mem.Allocator) !agent.AgentToolResult {
    return .{ .content = try tools_common.makeTextContent(
        allocator,
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object\"}}",
    ) };
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

const wasm_vtable: RuntimeAdapter.VTable = .{
    .wait_for_ready = wasmWaitForReady,
    .pending_count = wasmPendingCount,
    .diagnostic_count = wasmDiagnosticCount,
    .diagnostic_category_count = wasmDiagnosticCategoryCount,
    .has_shutdown_complete = wasmHasShutdownComplete,
    .registry_frames_applied = wasmRegistryFramesApplied,
    .has_registered_command = wasmHasRegisteredCommand,
    .snapshot_registry_json = wasmSnapshotRegistryJson,
    .with_registry = wasmWithRegistry,
    .apply_cli_flag_values = wasmApplyCliFlagValues,
    .agent_tool = wasmAgentTool,
    .take_ui_requests = wasmTakeUiRequests,
    .send_extension_ui_response = wasmSendExtensionUiResponse,
    .send_extension_event_frame = wasmSendExtensionEventFrame,
    .shutdown = wasmShutdown,
    .deinit = wasmDeinit,
};

pub fn startNative(allocator: std.mem.Allocator, io: std.Io, options: NativeOptions) !RuntimeAdapter {
    const runtime = try native_runtime.NativeRuntime.start(allocator, io, options);
    return .{
        .ptr = @ptrCast(runtime),
        .vtable = &native_vtable,
        .kind = .native,
    };
}

fn nativeRuntime(ptr: *anyopaque) *native_runtime.NativeRuntime {
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

fn nativeShutdown(ptr: *anyopaque) !void {
    try nativeRuntime(ptr).shutdown();
}

fn nativeDeinit(ptr: *anyopaque) void {
    nativeRuntime(ptr).deinit();
}

const native_vtable: RuntimeAdapter.VTable = .{
    .wait_for_ready = nativeWaitForReady,
    .pending_count = nativePendingCount,
    .diagnostic_count = nativeDiagnosticCount,
    .diagnostic_category_count = nativeDiagnosticCategoryCount,
    .has_shutdown_complete = nativeHasShutdownComplete,
    .registry_frames_applied = nativeRegistryFramesApplied,
    .has_registered_command = nativeHasRegisteredCommand,
    .snapshot_registry_json = nativeSnapshotRegistryJson,
    .with_registry = nativeWithRegistry,
    .apply_cli_flag_values = nativeApplyCliFlagValues,
    .agent_tool = nativeAgentTool,
    .take_ui_requests = nativeTakeUiRequests,
    .send_extension_ui_response = nativeSendExtensionUiResponse,
    .send_extension_event_frame = nativeSendExtensionEventFrame,
    .shutdown = nativeShutdown,
    .deinit = nativeDeinit,
};

fn absoluteTmpPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, name });
}

fn freeUiRequests(allocator: std.mem.Allocator, requests: []ExtensionUiRequest) void {
    for (requests) |*request| request.deinit(allocator);
    allocator.free(requests);
}

const RegistryExpectContext = struct {
    tool_seen: bool = false,
    command_seen: bool = false,
    shortcut_seen: bool = false,
    flag_seen: bool = false,
    provider_seen: bool = false,
    capability_seen: bool = false,
    resource_seen: bool = false,
    header_seen: bool = false,
    footer_seen: bool = false,
    terminal_input_seen: bool = false,
    editor_seen: bool = false,
    widget_seen: bool = false,
    message_renderer_seen: bool = false,
};

fn expectRegistryEntriesCallback(context: ?*anyopaque, registry: *const Registry) !void {
    const result: *RegistryExpectContext = @ptrCast(@alignCast(context.?));
    for (registry.tools.items) |tool| {
        if (std.mem.eql(u8, tool.name, "adapter-tool")) result.tool_seen = true;
    }
    for (registry.commands.items) |command| {
        if (std.mem.eql(u8, command.name, "adapter-command")) result.command_seen = true;
    }
    for (registry.shortcuts.items) |shortcut| {
        if (std.mem.eql(u8, shortcut.shortcut, "ctrl+a")) result.shortcut_seen = true;
    }
    for (registry.flags.items) |flag| {
        if (std.mem.eql(u8, flag.name, "adapter-flag")) result.flag_seen = true;
    }
    for (registry.providers.items) |provider| {
        if (std.mem.eql(u8, provider.name, "adapter-provider")) result.provider_seen = true;
    }
    for (registry.capabilities.items) |capability| {
        if (std.mem.eql(u8, capability.id, "adapter-capability")) result.capability_seen = true;
    }
    for (registry.resource_discoveries.items) |discovery| {
        if (std.mem.eql(u8, discovery.extension_path, "fixture/adapter.ts")) result.resource_seen = true;
    }
    result.header_seen = registry.header_hook != null;
    result.footer_seen = registry.footer_hook != null;
    for (registry.terminal_input_subs.items) |sub| {
        if (std.mem.eql(u8, sub.id, "adapter-terminal-input")) result.terminal_input_seen = true;
    }
    result.editor_seen = registry.editor_component_hook != null;
    for (registry.widgets.items) |widget| {
        if (std.mem.eql(u8, widget.key, "adapter-widget")) result.widget_seen = true;
    }
    for (registry.message_renderers.items) |renderer| {
        if (std.mem.eql(u8, renderer.custom_type, "adapter-message")) result.message_renderer_seen = true;
    }
}

fn expectAdapterRegistryUiEventShutdownConformance(allocator: std.mem.Allocator, adapter: RuntimeAdapter) !void {
    try adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while ((adapter.pendingCount() < 1 or adapter.registryFramesApplied() < 13) and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 13), adapter.registryFramesApplied());
    try std.testing.expect(adapter.hasRegisteredCommand("adapter-command"));

    var registry_context = RegistryExpectContext{};
    try adapter.withRegistry(&registry_context, expectRegistryEntriesCallback);
    try std.testing.expect(registry_context.tool_seen);
    try std.testing.expect(registry_context.command_seen);
    try std.testing.expect(registry_context.shortcut_seen);
    try std.testing.expect(registry_context.flag_seen);
    try std.testing.expect(registry_context.provider_seen);
    try std.testing.expect(registry_context.capability_seen);
    try std.testing.expect(registry_context.resource_seen);
    try std.testing.expect(registry_context.header_seen);
    try std.testing.expect(registry_context.footer_seen);
    try std.testing.expect(registry_context.terminal_input_seen);
    try std.testing.expect(registry_context.editor_seen);
    try std.testing.expect(registry_context.widget_seen);
    try std.testing.expect(registry_context.message_renderer_seen);

    const requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, requests);
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqualStrings("notify", requests[0].id);
    try std.testing.expect(!requests[0].response_required);
    try std.testing.expectEqualStrings("pending", requests[1].id);
    try std.testing.expect(requests[1].response_required);

    const empty_requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, empty_requests);
    try std.testing.expectEqual(@as(usize, 0), empty_requests.len);

    try adapter.applyCliFlagValues(&.{
        .{ .name = "adapter-flag", .value = .{ .string = "from-cli" } },
    });
    const snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"adapter-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"adapter-command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"shortcut\":\"ctrl+a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"adapter-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"adapter-capability\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"resourceDiscoveries\":[{\"extensionPath\":\"fixture/adapter.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"headerHook\":{\"lines\":[\"Adapter header\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"footerHook\":{\"lines\":[\"Adapter footer\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"adapter-terminal-input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"editorComponentHook\":{\"label\":\"Adapter editor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"widgets\":[{\"key\":\"adapter-widget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"customType\":\"adapter-message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"value\":\"from-cli\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"default\":\"default\"") != null);

    try adapter.sendExtensionUiResponse("unknown", "{\"ignored\":true}");
    try adapter.sendExtensionUiResponse("pending", "{\"accepted\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    adapter.sendExtensionEventFrame("{\"type\":\"agent_start\"}");
    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    adapter.sendExtensionEventFrame("{\"type\":\"agent_end\",\"messages\":[]}");
}

test "extension runtime factory rejects remote runtime deterministically" {
    const allocator = std.testing.allocator;
    const unsupported = [_]RuntimeOptions{
        .{ .remote = .{} },
    };

    for (unsupported) |options| {
        try std.testing.expectError(error.UnsupportedRuntime, startRuntime(allocator, std.testing.io, options));
    }
    try std.testing.expectEqualStrings("process_jsonl", RuntimeKind.process_jsonl.jsonName());
    try std.testing.expectEqualStrings("wasm", RuntimeKind.wasm.jsonName());
    try std.testing.expectEqualStrings("native", RuntimeKind.native.jsonName());
    try std.testing.expectEqualStrings("remote", RuntimeKind.remote.jsonName());
}

test "extension runtime factory constructs wasm adapter and keeps native remote unsupported" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer adapter.deinit();

    try std.testing.expectEqual(RuntimeKind.wasm, adapter.kind);
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expect(!adapter.hasRegisteredCommand("truncateHead"));

    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());

    try std.testing.expectError(error.UnsupportedRuntime, startRuntime(allocator, std.testing.io, .{ .remote = .{} }));
}

const native_static_tool: NativeToolDefinition = .{
    .name = "native.fixture.echo",
    .label = "Native Fixture Echo",
    .description = "Echoes a string through the static native fixture.",
    .input_schema_json = "{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{\"value\":{\"type\":\"string\",\"description\":\"Value to echo\"}},\"additionalProperties\":false}",
    .output_schema_json = "{\"type\":\"object\",\"required\":[\"ok\",\"tool\",\"echo\"],\"properties\":{\"ok\":{\"type\":\"boolean\"},\"tool\":{\"type\":\"string\"},\"echo\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    .extension_path = "native://template/pure-tool-v0",
    .execute = nativeFixtureEchoExecute,
};

const native_static_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-static-fixture",
    .name = "Native Static Fixture",
    .version = "0.1.0",
    .description = "Statically linked native runtime fixture",
    .tools = &.{native_static_tool},
};

const native_preready_tool: NativeToolDefinition = .{
    .name = "native.fixture.preready",
    .label = "Native Preready Tool",
    .description = "Attempts to register before readiness.",
    .input_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://fixture/preready",
    .execute = nativeFixtureEchoExecute,
};

const native_partial_failure_tool: NativeToolDefinition = .{
    .name = "native.fixture.partial",
    .label = "Native Partial Fixture",
    .description = "Native fixture registered before injected setup failure",
    .input_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://fixture/partial-failure",
};

fn nativeFixtureEchoExecute(allocator: std.mem.Allocator, params: std.json.Value) !agent.AgentToolResult {
    if (params != .object) return error.InvalidNativeToolInput;
    const value = params.object.get("value") orelse return error.InvalidNativeToolInput;
    if (value != .string) return error.InvalidNativeToolInput;

    const quoted_value = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value.string }, .{});
    defer allocator.free(quoted_value);
    const output_json = try std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":{s}}}",
        .{quoted_value},
    );
    defer allocator.free(output_json);
    return .{ .content = try tools_common.makeTextContent(allocator, output_json) };
}

fn nativeFailAfterReadyRegistryAndUi(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_partial_failure_tool);
    try api.requestUi("native-partial-pending", "input", true, "{\"prompt\":\"partial\"}");
    return error.NativeFixtureInjectedFailure;
}

fn nativeReadyBoundaryStart(api: *NativeHostApi) !void {
    try api.registerTool(native_preready_tool);
    try api.ready();
    try api.ready();
    try api.registerTool(native_static_tool);
}

const native_ready_boundary_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-ready-boundary",
    .name = "Native Ready Boundary Fixture",
    .version = "0.1.0",
    .description = "Native fixture that attempts pre-ready and duplicate-ready registration",
    .tools = &.{ native_preready_tool, native_static_tool },
    .start = nativeReadyBoundaryStart,
};

const native_partial_failure_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-partial-failure",
    .name = "Native Partial Failure Fixture",
    .version = "0.1.0",
    .description = "Native fixture that fails after partial setup",
    .tools = &.{native_partial_failure_tool},
    .start = nativeFailAfterReadyRegistryAndUi,
};

fn nativeHostApiBoundaryStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_static_tool);
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.readFile("/tmp/native-denied"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.writeFile("/tmp/native-denied", "blocked"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.requestNetwork("https://example.invalid/native-denied"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.runShell("echo blocked"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.readEnv("PI_NATIVE_DENIED"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.callModel("fake-model", "{\"prompt\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.readSession("session-denied"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.writeSession("session-denied", "{\"blocked\":true}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.notifyUi("{\"message\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.useTool("native.fixture.echo", "{\"value\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.spawnAgent("{\"task\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.delegateAgent("{\"task\":\"blocked\"}"));
    try std.testing.expectError(error.UnsupportedNativeHostOperation, api.emitEvent("{\"type\":\"native_event\"}"));
}

const native_host_api_boundary_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-host-api-boundary",
    .name = "Native Host API Boundary Fixture",
    .version = "0.1.0",
    .description = "Native fixture that exercises declared host API boundaries",
    .tools = &.{native_static_tool},
    .start = nativeHostApiBoundaryStart,
};

fn nativeInstanceIsolationStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_static_tool);
    try api.requestUi("native-shared-pending", "input", true, "{\"prompt\":\"native-instance\"}");
}

const native_instance_isolation_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-instance-isolation",
    .name = "Native Instance Isolation Fixture",
    .version = "0.1.0",
    .description = "Native fixture used to prove same-module adapter instance isolation",
    .tools = &.{native_static_tool},
    .start = nativeInstanceIsolationStart,
};

fn nativeUiLifecycleStart(api: *NativeHostApi) !void {
    try api.requestUi("native-pre-ready", "input", true, "{\"title\":\"Pre-ready\"}");
    try api.ready();
    try api.requestUi("native-notify", "notify", false, "{\"message\":\"Native notice\"}");
    try api.requestUi("native-pending", "input", true, "{\"title\":\"Native input\"}");
    try api.requestUi("native-pending", "input", true, "{\"title\":\"Duplicate\"}");
    try api.registerTool(native_static_tool);
}

const native_ui_lifecycle_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-ui-lifecycle",
    .name = "Native UI Lifecycle Fixture",
    .version = "0.1.0",
    .description = "Native fixture used to prove UI request and response lifecycle safety",
    .tools = &.{native_static_tool},
    .start = nativeUiLifecycleStart,
};

fn expectNativeStaticRegistry(context: ?*anyopaque, registry: *const Registry) !void {
    _ = context;
    const counts = extension_registry.registrySurfaceCounts(registry);
    try std.testing.expectEqual(@as(usize, 1), counts.tools);
    try std.testing.expectEqual(@as(usize, 0), counts.commands);
    try std.testing.expectEqualStrings("native.fixture.echo", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("Native Fixture Echo", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("Echoes a string through the static native fixture.", registry.tools.items[0].description);
    try std.testing.expectEqualStrings("native://template/pure-tool-v0", registry.tools.items[0].extension_path);
    try std.testing.expectEqualStrings("object", registry.tools.items[0].parameters.object.get("type").?.string);
    try std.testing.expectEqualStrings("value", registry.tools.items[0].parameters.object.get("required").?.array.items[0].string);
}

test "native runtime factory starts static module and remote stays unsupported" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();

    try std.testing.expectEqual(RuntimeKind.native, adapter.kind);
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try adapter.withRegistry(null, expectNativeStaticRegistry);

    const snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"native.fixture.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"label\":\"Native Fixture Echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"description\":\"Echoes a string through the static native fixture.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"parameters\":{\"type\":\"object\",\"required\":[\"value\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"extensionPath\":\"native://template/pure-tool-v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Workflow") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Wiki") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "QA") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Review") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "dynamic") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "library") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "executable") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "remote") == null);

    try std.testing.expectEqualStrings("remote", RuntimeKind.remote.jsonName());
    try std.testing.expectError(error.UnsupportedRuntime, startRuntime(allocator, std.testing.io, .{ .remote = .{} }));
}

test "native descriptor template executes pure tool and recovers after invalid input" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    var agent_tool = (try adapter.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    try std.testing.expect(agent_tool.execute != null);
    try std.testing.expectEqualStrings("native.fixture.echo", agent_tool.name);
    try std.testing.expectEqualStrings("Native Fixture Echo", agent_tool.label);
    try std.testing.expectEqualStrings("Echoes a string through the static native fixture.", agent_tool.description);
    try std.testing.expectEqualStrings("object", agent_tool.parameters.object.get("type").?.string);

    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"alpha\"}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "native-success", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqual(@as(usize, 1), success.content.len);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"alpha\"}", success.content[0].text.text);

    var repeated_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"alpha\"}", .{});
    defer repeated_params.deinit();
    const repeated = try agent_tool.execute.?(allocator, "native-repeat", repeated_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, repeated.content);
    try std.testing.expectEqualStrings(success.content[0].text.text, repeated.content[0].text.text);

    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":42}", .{});
    defer invalid_params.deinit();
    const invalid = try agent_tool.execute.?(allocator, "native-invalid", invalid_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, invalid.content);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with string field value\"}}",
        invalid.content[0].text.text,
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCategoryCount(.host_error));

    var recovered_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"omega\"}", .{});
    defer recovered_params.deinit();
    const recovered = try agent_tool.execute.?(allocator, "native-recovered", recovered_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, recovered.content);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"omega\"}", recovered.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
}

test "native runtime shutdown is idempotent and final" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    const maybe_tool = try adapter.agentTool(allocator, "native.fixture.echo");
    try std.testing.expect(maybe_tool != null);
    var tool = maybe_tool.?;
    defer deinitAgentTool(allocator, &tool);

    try adapter.shutdown();
    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "native.fixture.echo"));

    const snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tools\":[]") != null);
}

test "native descriptor validation rejects invalid shapes before registry registration" {
    const allocator = std.testing.allocator;
    const invalid_schema_tool: NativeToolDefinition = .{
        .name = "native.fixture.invalid-schema",
        .label = "Invalid Schema",
        .description = "Invalid schema fixture",
        .input_schema_json = "{\"type\":\"object\"",
        .extension_path = "native://template/invalid-schema",
    };
    const missing_tool_identity: NativeToolDefinition = .{
        .name = "",
        .label = "Missing Identity",
        .description = "Missing identity fixture",
        .input_schema_json = "{\"type\":\"object\"}",
        .extension_path = "native://template/missing-identity",
    };
    const duplicate_tool_a: NativeToolDefinition = .{
        .name = "native.fixture.duplicate",
        .label = "Duplicate A",
        .description = "Duplicate fixture A",
        .input_schema_json = "{\"type\":\"object\"}",
        .extension_path = "native://template/duplicate-a",
    };
    const duplicate_tool_b: NativeToolDefinition = .{
        .name = "native.fixture.duplicate",
        .label = "Duplicate B",
        .description = "Duplicate fixture B",
        .input_schema_json = "{\"type\":\"object\"}",
        .extension_path = "native://template/duplicate-b",
    };

    const invalid_descriptors = [_]NativeDescriptor{
        .{
            .id = "",
            .name = "Missing Id",
            .version = "0.1.0",
            .description = "Missing id fixture",
            .tools = &.{native_static_tool},
        },
        .{
            .id = "com.pi.native-invalid-schema",
            .name = "Invalid Schema",
            .version = "0.1.0",
            .description = "Invalid schema fixture",
            .tools = &.{invalid_schema_tool},
        },
        .{
            .id = "com.pi.native-missing-tool-identity",
            .name = "Missing Tool Identity",
            .version = "0.1.0",
            .description = "Missing tool identity fixture",
            .tools = &.{missing_tool_identity},
        },
        .{
            .id = "com.pi.native-duplicate-tool",
            .name = "Duplicate Tool",
            .version = "0.1.0",
            .description = "Duplicate tool fixture",
            .tools = &.{ duplicate_tool_a, duplicate_tool_b },
        },
    };

    for (invalid_descriptors) |descriptor| {
        try std.testing.expectError(error.InvalidRuntimeOptions, startRuntime(allocator, std.testing.io, .{ .native = .{
            .descriptor = &descriptor,
        } }));
    }

    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(0);
    try adapter.withRegistry(null, expectNativeStaticRegistry);
}

test "native descriptor capability and resource metadata remains default deny" {
    const allocator = std.testing.allocator;
    const resource_only_descriptor: NativeDescriptor = .{
        .id = "com.pi.native-resource-only",
        .name = "Native Resource Only",
        .version = "0.1.0",
        .description = "Resource limits constrain without granting capabilities",
        .tools = &.{native_static_tool},
        .resource_limits = .{
            .turns = 1,
            .output_bytes = 64,
            .tool_scopes = &.{"native.fixture.echo"},
        },
    };
    const resource_adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &resource_only_descriptor,
    } });
    defer resource_adapter.deinit();
    try resource_adapter.waitForReady(0);
    try resource_adapter.withRegistry(null, expectNativeStaticRegistry);

    const capability_descriptor: NativeDescriptor = .{
        .id = "com.pi.native-capability-request",
        .name = "Native Capability Request",
        .version = "0.1.0",
        .description = "Requested capabilities are denied by default",
        .tools = &.{native_static_tool},
        .requested_capabilities = &.{.tool_use},
        .resource_limits = .{
            .turns = 1,
            .tool_scopes = &.{"native.fixture.echo"},
        },
    };
    const denial = capability_descriptor.deniedCapability(.initialize, "native/descriptor").?;
    try std.testing.expectEqualStrings("denied_capability", denial.category);
    try std.testing.expectEqual(wasm_manifest.Capability.tool_use, denial.capability);
    try std.testing.expectEqual(wasm_manifest.CapabilityEnforcementBranch.tool_execution, denial.branch);
    try std.testing.expectEqual(wasm_manifest.LifecyclePhase.initialize, denial.phase);
    try std.testing.expectEqualStrings("native/descriptor", denial.mode);
    try std.testing.expectError(error.UnsupportedRuntimeCapability, startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &capability_descriptor,
    } }));

    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(0);
    try adapter.withRegistry(null, expectNativeStaticRegistry);
}

test "native runtime preserves ready boundary duplicate readiness and deterministic snapshots" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_ready_boundary_descriptor,
    } });
    defer adapter.deinit();

    try std.testing.expectEqual(RuntimeKind.native, adapter.kind);
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 2), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCategoryCount(.duplicate_ready));
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try adapter.withRegistry(null, expectNativeStaticRegistry);
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "native.fixture.preready"));

    const snapshot_one = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_one);
    const snapshot_two = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_two);
    try std.testing.expectEqualStrings(snapshot_one, snapshot_two);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "\"name\":\"native.fixture.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "native.fixture.preready") == null);
}

test "native descriptor rejects dynamic runtime and product policy fields" {
    const allocator = std.testing.allocator;
    const forbidden_descriptors = [_]NativeDescriptor{
        .{ .id = "com.pi.native-library", .name = "Library", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .library_path = "/tmp/libnative.dylib" },
        .{ .id = "com.pi.native-dynamic-library", .name = "Dynamic Library", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .dynamic_library_path = "/tmp/libnative.dylib" },
        .{ .id = "com.pi.native-process", .name = "Process", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .executable_command = "node extension.js" },
        .{ .id = "com.pi.native-process-command", .name = "Process Command", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .process_command = "bun extension.ts" },
        .{ .id = "com.pi.native-remote", .name = "Remote", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .remote_url = "https://example.invalid/plugin.wasm" },
        .{ .id = "com.pi.native-workflow", .name = "Workflow", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .workflow_preset = "workflow" },
        .{ .id = "com.pi.native-wiki", .name = "Wiki", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .wiki_preset = "wiki" },
        .{ .id = "com.pi.native-qa", .name = "QA", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .qa_preset = "qa" },
        .{ .id = "com.pi.native-review", .name = "Review", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .review_preset = "review" },
        .{ .id = "com.pi.native-spawn-policy", .name = "Spawn Policy", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .spawn_policy = "automatic" },
        .{ .id = "com.pi.native-automatic-spawn", .name = "Automatic Spawn", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .automatic_spawn = "true" },
        .{ .id = "com.pi.native-orchestration", .name = "Orchestration", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .orchestration_policy = "preset" },
        .{ .id = "com.pi.native-model-ui", .name = "Model UI", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .model_selection_ui = "picker" },
        .{ .id = "com.pi.native-approval-ui", .name = "Approval UI", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .approval_ui = "prompt" },
    };

    for (forbidden_descriptors) |descriptor| {
        try std.testing.expectError(error.ForbiddenNativeDescriptorField, startRuntime(allocator, std.testing.io, .{ .native = .{
            .descriptor = &descriptor,
        } }));
    }
}

test "native runtime partial setup failure cleans registry tool and UI state" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NativeFixtureInjectedFailure, startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_partial_failure_descriptor,
    } }));

    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try adapter.withRegistry(null, expectNativeStaticRegistry);
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "native.fixture.partial"));
}

test "native runtime participates in adapter conformance and event frames are stable no-op" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();

    try std.testing.expectEqual(RuntimeKind.native, adapter.kind);
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try adapter.withRegistry(null, expectNativeStaticRegistry);
    try std.testing.expect(!adapter.hasRegisteredCommand("native.fixture.echo"));

    const empty_requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, empty_requests);
    try std.testing.expectEqual(@as(usize, 0), empty_requests.len);
    try adapter.sendExtensionUiResponse("unknown", "{\"ignored\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());

    const snapshot_before_events = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_before_events);
    adapter.sendExtensionEventFrame("{\"type\":\"before_agent_start\",\"agentId\":\"agent\",\"runId\":\"run\"}");
    adapter.sendExtensionEventFrame("{\"type\":\"unsupported_native_event\",\"payload\":{\"x\":1}}");
    adapter.sendExtensionEventFrame("{");
    adapter.sendExtensionEventFrame("[]");
    const snapshot_after_events = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_after_events);
    try std.testing.expectEqualStrings(snapshot_before_events, snapshot_after_events);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());

    var agent_tool = (try adapter.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"event-stable\"}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "native-event-stable", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"event-stable\"}", success.content[0].text.text);

    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    adapter.sendExtensionEventFrame("{\"type\":\"after_shutdown\"}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "native.fixture.echo"));
    const snapshot_after_shutdown_event = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_after_shutdown_event);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_after_shutdown_event, "\"tools\":[]") != null);
}

test "native runtime UI lifecycle rejects unsafe requests and resolves pending responses once" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_ui_lifecycle_descriptor,
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 2), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCategoryCount(.duplicate_pending_request));

    const requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, requests);
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqualStrings("native-notify", requests[0].id);
    try std.testing.expect(!requests[0].response_required);
    try std.testing.expectEqualStrings("notify", requests[0].method);
    try std.testing.expectEqualStrings("{\"message\":\"Native notice\"}", requests[0].payload_json);
    try std.testing.expectEqualStrings("native-pending", requests[1].id);
    try std.testing.expect(requests[1].response_required);
    try std.testing.expectEqualStrings("input", requests[1].method);

    requests[1].id[0] = 'X';
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try adapter.sendExtensionUiResponse("unknown", "{\"ignored\":true}");
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try adapter.sendExtensionUiResponse("native-pending", "{\"accepted\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try adapter.sendExtensionUiResponse("native-pending", "{\"duplicate\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());

    var agent_tool = (try adapter.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"after-ui\"}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "native-ui-success", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"after-ui\"}", success.content[0].text.text);

    try adapter.shutdown();
    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "native.fixture.echo"));
    try adapter.sendExtensionUiResponse("native-pending", "{\"postShutdown\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
}

test "native host API privileged operations are explicit default-deny boundaries" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_host_api_boundary_descriptor,
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    try adapter.withRegistry(null, expectNativeStaticRegistry);
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 13), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 13), adapter.diagnosticCategoryCount(.host_error));
    const native_boundary_runtime = nativeRuntime(adapter.ptr);
    const expected_capabilities = [_][]const u8{
        "file.read",
        "file.write",
        "network.request",
        "shell.run",
        "env.read",
        "model.call",
        "session.read",
        "session.write",
        "ui.notify",
        "tool.use",
        "agent.spawn",
        "agent.delegate",
    };
    for (expected_capabilities) |capability| {
        var found = false;
        for (native_boundary_runtime.state.diagnostics.items) |diagnostic| {
            if (std.mem.indexOf(u8, diagnostic.message, capability) != null and
                std.mem.indexOf(u8, diagnostic.message, "\"mode\":\"native/host-api\"") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"category\":\"denied_capability\"") != null)
            {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expect(std.mem.indexOf(u8, native_boundary_runtime.state.diagnostics.items[12].message, "unsupported_native_host_event") != null);

    const snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"native.fixture.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "native-denied") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "blocked") == null);
}

test "native runtime same descriptor instances isolate registry pending diagnostics and shutdown" {
    const allocator = std.testing.allocator;
    const first = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_instance_isolation_descriptor,
    } });
    defer first.deinit();
    const second = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_instance_isolation_descriptor,
    } });
    defer second.deinit();

    try first.waitForReady(0);
    try second.waitForReady(0);
    try std.testing.expectEqual(RuntimeKind.native, first.kind);
    try std.testing.expectEqual(RuntimeKind.native, second.kind);
    try std.testing.expectEqual(@as(usize, 1), first.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 1), second.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 1), first.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), second.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), first.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 0), second.diagnosticCount());

    try first.sendExtensionUiResponse("native-shared-pending", "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 0), first.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), second.pendingCount());

    var first_tool = (try first.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &first_tool);
    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":false}", .{});
    defer invalid_params.deinit();
    const invalid = try first_tool.execute.?(allocator, "native-first-invalid", invalid_params.value, first_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, invalid.content);
    try std.testing.expectEqual(@as(usize, 1), first.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 0), second.diagnosticCount());

    const second_snapshot_before_first_shutdown = try second.snapshotRegistryJson(allocator);
    defer allocator.free(second_snapshot_before_first_shutdown);
    try first.shutdown();
    try std.testing.expect(first.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try first.agentTool(allocator, "native.fixture.echo"));
    try std.testing.expectEqual(@as(usize, 1), second.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), second.registryFramesApplied());
    try second.withRegistry(null, expectNativeStaticRegistry);
    const second_snapshot_after_first_shutdown = try second.snapshotRegistryJson(allocator);
    defer allocator.free(second_snapshot_after_first_shutdown);
    try std.testing.expectEqualStrings(second_snapshot_before_first_shutdown, second_snapshot_after_first_shutdown);

    var second_tool = (try second.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &second_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"second\"}", .{});
    defer success_params.deinit();
    const success = try second_tool.execute.?(allocator, "native-second-success", success_params.value, second_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"second\"}", success.content[0].text.text);

    try second.sendExtensionUiResponse("native-shared-pending", "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 0), second.pendingCount());
    try second.shutdown();
    try std.testing.expect(second.hasShutdownComplete());
}

test "wasm manifest handoff starts runtime without capability execution" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    try std.testing.expectEqual(@as(usize, 0), manifest_result.valid.requested_capabilities.len);

    const options = WasmOptions{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    };
    const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = options });
    defer adapter.deinit();

    try std.testing.expectEqual(RuntimeKind.wasm, adapter.kind);
    const requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, requests);
    try std.testing.expectEqual(@as(usize, 0), requests.len);

    const snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"builtin.truncateHead\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"parameters\":{\"type\":\"object\"") != null);
}

test "wasm runtime handoff denies every canonical requested capability before registration" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const base_handoff = WasmManifestHandoff.fromManifest(&manifest_result.valid);
    for (wasm_manifest.CANONICAL_CAPABILITIES) |capability| {
        const requested = [_]wasm_manifest.Capability{capability};
        var handoff = base_handoff;
        handoff.requested_capabilities = requested[0..];

        const denial = handoff.deniedRuntimeCapability(.initialize, "runtime/handoff").?;
        try std.testing.expectEqualStrings("denied_capability", denial.category);
        try std.testing.expectEqual(capability, denial.capability);
        try std.testing.expectEqual(capability.enforcementBranch(), denial.branch);
        try std.testing.expectEqual(wasm_manifest.LifecyclePhase.initialize, denial.phase);
        try std.testing.expectEqualStrings("runtime/handoff", denial.mode);

        try std.testing.expectError(error.UnsupportedRuntimeCapability, handoff.validate());
        try std.testing.expectError(error.UnsupportedRuntimeCapability, startRuntime(allocator, std.testing.io, .{ .wasm = .{
            .manifest = handoff,
        } }));
    }
}

const WasmToolRegistryExpectContext = struct {
    expected_artifact_path: []const u8,
};

fn expectWasmToolOnlyRegistry(context: ?*anyopaque, registry: *const Registry) !void {
    const expected: *WasmToolRegistryExpectContext = @ptrCast(@alignCast(context.?));
    const counts = extension_registry.registrySurfaceCounts(registry);
    try std.testing.expectEqual(@as(usize, 1), counts.tools);
    try std.testing.expectEqual(@as(usize, 0), counts.commands);
    try std.testing.expectEqual(@as(usize, 0), counts.shortcuts);
    try std.testing.expectEqual(@as(usize, 0), counts.flags);
    try std.testing.expectEqual(@as(usize, 0), counts.providers);
    try std.testing.expectEqual(@as(usize, 0), counts.capabilities);
    try std.testing.expectEqual(@as(usize, 0), counts.resource_discoveries);
    try std.testing.expectEqual(@as(usize, 0), counts.header_hooks);
    try std.testing.expectEqual(@as(usize, 0), counts.footer_hooks);
    try std.testing.expectEqual(@as(usize, 0), counts.terminal_input_subscriptions);
    try std.testing.expectEqual(@as(usize, 0), counts.editor_component_hooks);
    try std.testing.expectEqual(@as(usize, 0), counts.widgets);
    try std.testing.expectEqual(@as(usize, 0), counts.message_renderers);
    try std.testing.expectEqual(@as(usize, 0), counts.ui_request_ids);
    try std.testing.expectEqualStrings("builtin.truncateHead", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("Keeps the beginning of content within line and byte limits.", registry.tools.items[0].description);
    try std.testing.expectEqualStrings(expected.expected_artifact_path, registry.tools.items[0].extension_path);
    const parameters = registry.tools.items[0].parameters.object;
    try std.testing.expectEqualStrings("object", parameters.get("type").?.string);
    try std.testing.expect(parameters.get("properties").?.object.get("content").? == .object);
    try std.testing.expect(parameters.get("properties").?.object.get("maxLines").? == .object);
    try std.testing.expect(parameters.get("properties").?.object.get("maxBytes").? == .object);
}

fn expectWasmToolSubsetConformance(allocator: std.mem.Allocator, adapter: RuntimeAdapter, expected_artifact_path: []const u8) !void {
    try std.testing.expectEqual(RuntimeKind.wasm, adapter.kind);
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expect(!adapter.hasRegisteredCommand("builtin.truncateHead"));

    var registry_expect = WasmToolRegistryExpectContext{ .expected_artifact_path = expected_artifact_path };
    try adapter.withRegistry(&registry_expect, expectWasmToolOnlyRegistry);

    var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\\nbravo\\ncharlie\",\"maxLines\":2,\"maxBytes\":1024}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "wasm-subset-success", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqual(@as(usize, 1), success.content.len);
    try std.testing.expect(std.mem.indexOf(u8, success.content[0].text.text, "\"content\":\"alpha\\nbravo\"") != null);

    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    defer invalid_params.deinit();
    const invalid = try agent_tool.execute.?(allocator, "wasm-subset-invalid", invalid_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, invalid.content);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object\"}}",
        invalid.content[0].text.text,
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCategoryCount(.host_error));
    const diagnostic = wasmRuntime(adapter.ptr).state.diagnostics.items[0];
    try std.testing.expectEqual(DiagnosticCategory.host_error, diagnostic.category);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"phase\":\"call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"category\":\"invalid_input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"path\":\"$.execute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"capability\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"message\":\"execute input must be a JSON object\"") != null);
}

test "wasm runtime registers schema preserving tool and executes through agent tool api" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer adapter.deinit();

    try std.testing.expectEqual(RuntimeKind.wasm, adapter.kind);
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    var registry_expect = WasmToolRegistryExpectContext{ .expected_artifact_path = manifest_result.valid.artifact_absolute_path };
    try adapter.withRegistry(&registry_expect, expectWasmToolOnlyRegistry);

    var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    try std.testing.expect(agent_tool.execute != null);
    try std.testing.expectEqualStrings("builtin.truncateHead", agent_tool.name);
    try std.testing.expectEqualStrings("Keeps the beginning of content within line and byte limits.", agent_tool.description);

    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\\nbravo\\ncharlie\\ndelta\",\"maxLines\":2,\"maxBytes\":1024}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "wasm-call-success", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqual(@as(usize, 1), success.content.len);
    try std.testing.expectEqualStrings(
        "{\"content\":\"alpha\\nbravo\",\"truncated\":true,\"truncatedBy\":\"lines\",\"totalLines\":4,\"totalBytes\":25,\"outputLines\":2,\"outputBytes\":11,\"lastLinePartial\":false,\"firstLineExceedsLimit\":false,\"maxLines\":2,\"maxBytes\":1024}",
        success.content[0].text.text,
    );

    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    defer invalid_params.deinit();
    const invalid = try agent_tool.execute.?(allocator, "wasm-call-invalid", invalid_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, invalid.content);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object\"}}",
        invalid.content[0].text.text,
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());

    const recovered = try agent_tool.execute.?(allocator, "wasm-call-recovered", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, recovered.content);
    try std.testing.expectEqualStrings(success.content[0].text.text, recovered.content[0].text.text);

    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "builtin.truncateHead"));
    const unloaded_snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(unloaded_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, unloaded_snapshot, "\"tools\":[]") != null);
}

test "wasm unload shutdown is idempotent and final across repeated cycles" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    var expected_output: ?[]u8 = null;
    defer if (expected_output) |output| allocator.free(output);

    for (0..2) |cycle| {
        const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
            .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
        } });
        defer adapter.deinit();

        try adapter.waitForReady(0);
        try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
        {
            const counts = wasmRuntime(adapter.ptr).host.resourceCounts();
            try std.testing.expect(counts.memory_bytes > 0);
            try std.testing.expect(counts.function_returns > 0);
            try std.testing.expect(counts.function_exports > 0);
        }

        var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
        defer deinitAgentTool(allocator, &agent_tool);

        var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\\nbravo\\ncharlie\\ndelta\",\"maxLines\":2,\"maxBytes\":1024}", .{});
        defer success_params.deinit();
        const success = try agent_tool.execute.?(allocator, "wasm-cycle-success", success_params.value, agent_tool.execute_context, null, null, null);
        defer tools_common.deinitContentBlocks(allocator, success.content);
        try std.testing.expectEqual(@as(usize, 1), success.content.len);
        if (cycle == 0) {
            expected_output = try allocator.dupe(u8, success.content[0].text.text);
        } else {
            try std.testing.expectEqualStrings(expected_output.?, success.content[0].text.text);
        }

        try adapter.shutdown();
        try adapter.shutdown();
        try std.testing.expect(adapter.hasShutdownComplete());
        try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "builtin.truncateHead"));
        const counts_after_shutdown = wasmRuntime(adapter.ptr).host.resourceCounts();
        try std.testing.expectEqual(@as(usize, 0), counts_after_shutdown.memory_bytes);
        try std.testing.expectEqual(@as(usize, 0), counts_after_shutdown.function_returns);
        try std.testing.expectEqual(@as(usize, 0), counts_after_shutdown.function_exports);
        try std.testing.expectError(error.WasmToolNotRegistered, agent_tool.execute.?(allocator, "wasm-cycle-stale", success_params.value, agent_tool.execute_context, null, null, null));

        const unloaded_snapshot = try adapter.snapshotRegistryJson(allocator);
        defer allocator.free(unloaded_snapshot);
        try std.testing.expect(std.mem.indexOf(u8, unloaded_snapshot, "\"tools\":[]") != null);
    }
}

test "wasm cleanup covers load failure call failure shutdown and deinit paths" {
    const allocator = std.testing.allocator;

    var mismatch_manifest = try wasm_manifest.validateManifestText(allocator, "test/fixtures/wasm/pure-truncate-head-v0",
        \\{"schemaVersion":"pi-extension.v0","id":"com.pi.pure-truncate-head","name":"Pure Truncate Head Fixture","version":"0.1.0","description":"Capability-free Wasm migration fixture for the existing truncateHead pure tool implementation.","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"wrong.truncateHead","description":"Keeps the beginning of content within line and byte limits.","inputSchema":{"type":"object","required":["content","maxLines","maxBytes"],"properties":{"content":{"type":"string"},"maxLines":{"type":"number"},"maxBytes":{"type":"number"}}},"outputSchema":{"type":"object"}},"capabilities":[]}
    );
    defer mismatch_manifest.deinit(allocator);
    try std.testing.expect(mismatch_manifest == .valid);
    try std.testing.expectError(error.WasmManifestMetadataMismatch, startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&mismatch_manifest.valid),
    } }));

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    {
        const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
            .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
        } });
        defer adapter.deinit();

        var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
        defer deinitAgentTool(allocator, &agent_tool);
        wasmRuntime(adapter.ptr).host.unload(null, null);
        var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\\nbravo\",\"maxLines\":1,\"maxBytes\":1024}", .{});
        defer success_params.deinit();
        try std.testing.expectError(error.MissingWasmExport, agent_tool.execute.?(allocator, "wasm-call-failure", success_params.value, agent_tool.execute_context, null, null, null));
        try adapter.shutdown();
        try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "builtin.truncateHead"));
        const counts_after_failure_shutdown = wasmRuntime(adapter.ptr).host.resourceCounts();
        try std.testing.expectEqual(@as(usize, 0), counts_after_failure_shutdown.memory_bytes);
        try std.testing.expectEqual(@as(usize, 0), counts_after_failure_shutdown.function_returns);
        try std.testing.expectEqual(@as(usize, 0), counts_after_failure_shutdown.function_exports);
    }

    {
        const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
            .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
        } });
        adapter.deinit();
    }
}

test "wasm runtime rejects metadata schema mismatch before registration" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestText(allocator, "test/fixtures/wasm/pure-truncate-head-v0",
        \\{"schemaVersion":"pi-extension.v0","id":"com.pi.pure-truncate-head","name":"Pure Truncate Head Fixture","version":"0.1.0","description":"Capability-free Wasm migration fixture for the existing truncateHead pure tool implementation.","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"wrong.truncateHead","description":"Keeps the beginning of content within line and byte limits.","inputSchema":{"type":"object","required":["content","maxLines","maxBytes"],"properties":{"content":{"type":"string"},"maxLines":{"type":"number"},"maxBytes":{"type":"number"}}},"outputSchema":{"type":"object"}},"capabilities":[]}
    );
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    try std.testing.expectError(error.WasmManifestMetadataMismatch, startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } }));
}

test "extension runtime mixed process_jsonl and wasm adapters isolate interleaved lifecycle state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "mixed-process-jsonl-capture.jsonl");
    defer allocator.free(capture_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"process-pending\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{{\"text\":\"process\"}}}}\\n'; " ++
            "printf '{{\"type\":\"register_command\",\"name\":\"process-command\",\"description\":\"Process command\",\"extensionPath\":\"fixture/process.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_flag\",\"name\":\"process-flag\",\"valueType\":\"string\",\"default\":\"process-default\",\"extensionPath\":\"fixture/process.ts\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "mixed-process-jsonl-runtime" };

    const process_adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "mixed-process-marker",
            .cwd = "/mixed-process-cwd",
            .fixture = "mixed-process-fixture",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter.deinit();
    try std.testing.expectEqual(RuntimeKind.process_jsonl, process_adapter.kind);
    try process_adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while ((process_adapter.pendingCount() < 1 or process_adapter.registryFramesApplied() < 2) and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), process_adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 2), process_adapter.registryFramesApplied());
    try std.testing.expect(process_adapter.hasRegisteredCommand("process-command"));

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try expectWasmToolSubsetConformance(allocator, wasm_adapter, manifest_result.valid.artifact_absolute_path);

    const native_adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);
    try std.testing.expectEqual(RuntimeKind.native, native_adapter.kind);
    try std.testing.expectEqual(@as(usize, 0), native_adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), native_adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 1), native_adapter.registryFramesApplied());
    try native_adapter.withRegistry(null, expectNativeStaticRegistry);

    const process_snapshot_before_wasm_shutdown = try process_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(process_snapshot_before_wasm_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot_before_wasm_shutdown, "\"name\":\"process-command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot_before_wasm_shutdown, "\"name\":\"builtin.truncateHead\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot_before_wasm_shutdown, "\"name\":\"native.fixture.echo\"") == null);
    const wasm_snapshot_before_shutdown = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(wasm_snapshot_before_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, wasm_snapshot_before_shutdown, "\"name\":\"builtin.truncateHead\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_snapshot_before_shutdown, "\"name\":\"process-command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_snapshot_before_shutdown, "\"name\":\"native.fixture.echo\"") == null);
    const native_snapshot_before_shutdown = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(native_snapshot_before_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot_before_shutdown, "\"name\":\"native.fixture.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot_before_shutdown, "\"name\":\"process-command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot_before_shutdown, "\"name\":\"builtin.truncateHead\"") == null);

    try native_adapter.shutdown();
    try std.testing.expect(native_adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try native_adapter.agentTool(allocator, "native.fixture.echo"));
    try std.testing.expect(process_adapter.hasRegisteredCommand("process-command"));
    try std.testing.expectEqual(@as(usize, 1), process_adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), wasm_adapter.registryFramesApplied());

    try wasm_adapter.shutdown();
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    const wasm_counts_after_shutdown = wasmRuntime(wasm_adapter.ptr).host.resourceCounts();
    try std.testing.expectEqual(@as(usize, 0), wasm_counts_after_shutdown.memory_bytes);
    try std.testing.expectEqual(@as(usize, 0), wasm_counts_after_shutdown.function_returns);
    try std.testing.expectEqual(@as(usize, 0), wasm_counts_after_shutdown.function_exports);
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try wasm_adapter.agentTool(allocator, "builtin.truncateHead"));
    try std.testing.expect(process_adapter.hasRegisteredCommand("process-command"));
    try std.testing.expectEqual(@as(usize, 1), process_adapter.pendingCount());

    try process_adapter.sendExtensionUiResponse("process-pending", "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 0), process_adapter.pendingCount());
    try process_adapter.shutdown();
    try std.testing.expect(process_adapter.hasShutdownComplete());
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    try std.testing.expect(native_adapter.hasShutdownComplete());

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"initialize\",\"marker\":\"mixed-process-marker\",\"cwd\":\"/mixed-process-cwd\",\"fixture\":\"mixed-process-fixture\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"process-pending\",\"payload\":{\"ok\":true}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "builtin.truncateHead") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "native.fixture.echo") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"shutdown\"}\n") != null);
}

test "cross-runtime capability metadata and resource limits do not grant or leak privileges" {
    const allocator = std.testing.allocator;
    const process_script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"register_tool\",\"name\":\"process-display-tool\",\"label\":\"Process Display Tool\",\"description\":\"registry metadata only\",\"parameters\":{\"type\":\"object\"},\"extensionPath\":\"fixture/process-display.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_capability\",\"id\":\"tool.use\",\"kind\":\"display\",\"title\":\"Tool Use Display\",\"description\":\"metadata only\",\"extensionPath\":\"fixture/process-display.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_command\",\"name\":\"process-display-command\",\"description\":\"metadata only\",\"extensionPath\":\"fixture/process-display.ts\"}\\n'; " ++
        "printf '{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"promptPaths\":[],\"themePaths\":[],\"extensionPath\":\"fixture/process-display.ts\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const process_argv = [_][]const u8{ "/bin/sh", "-c", process_script, "process-jsonl-display-metadata" };
    const process_adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "display-metadata-marker",
            .cwd = "/display-metadata-cwd",
            .fixture = "display-metadata",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter.registryFramesApplied() < 4 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 4), process_adapter.registryFramesApplied());
    try std.testing.expect(process_adapter.hasRegisteredCommand("process-display-command"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try process_adapter.agentTool(allocator, "process-display-tool"));

    var wasm_resource_manifest = try wasm_manifest.validateManifestText(allocator, "test/fixtures/wasm/pure-truncate-head-v0",
        \\{"schemaVersion":"pi-extension.v0","id":"com.pi.pure-truncate-head","name":"Pure Truncate Head Fixture","version":"0.1.0","description":"Capability-free Wasm migration fixture for the existing truncateHead pure tool implementation.","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"builtin.truncateHead","description":"Keeps the beginning of content within line and byte limits.","inputSchema":{"type":"object","required":["content","maxLines","maxBytes"],"properties":{"content":{"type":"string"},"maxLines":{"type":"number"},"maxBytes":{"type":"number"}}},"outputSchema":{"type":"object"}},"capabilities":[],"resourceLimits":{"turns":1,"timeoutMs":10,"outputBytes":128,"outputLines":2,"toolScopes":["builtin.truncateHead"]}}
    );
    defer wasm_resource_manifest.deinit(allocator);
    try std.testing.expect(wasm_resource_manifest == .valid);
    try std.testing.expectEqual(@as(usize, 0), wasm_resource_manifest.valid.requested_capabilities.len);
    try std.testing.expectEqual(@as(u64, 1), wasm_resource_manifest.valid.resource_limits.turns.?);
    try std.testing.expectEqual(@as(usize, 1), wasm_resource_manifest.valid.resource_limits.tool_scopes.len);

    var wasm_runtime_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer wasm_runtime_manifest.deinit(allocator);
    try std.testing.expect(wasm_runtime_manifest == .valid);
    const wasm_adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&wasm_runtime_manifest.valid),
    } });
    defer wasm_adapter.deinit();
    try expectWasmToolSubsetConformance(allocator, wasm_adapter, wasm_runtime_manifest.valid.artifact_absolute_path);

    const native_resource_denial_descriptor: NativeDescriptor = .{
        .id = "com.pi.native-resource-denial-isolation",
        .name = "Native Resource Denial Isolation",
        .version = "0.1.0",
        .description = "Resource limits and display metadata must not grant native host API operations",
        .tools = &.{native_static_tool},
        .resource_limits = .{
            .turns = 1,
            .timeout_ms = 10,
            .output_bytes = 128,
            .tool_scopes = &.{ "process-display-tool", "native.fixture.echo" },
        },
        .start = nativeHostApiBoundaryStart,
    };
    const native_adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_resource_denial_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), native_adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 13), native_adapter.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 13), native_adapter.diagnosticCategoryCount(.host_error));

    const native_boundary_runtime = nativeRuntime(native_adapter.ptr);
    for (wasm_manifest.CANONICAL_CAPABILITIES) |capability| {
        const denial = wasm_manifest.denyRuntimeCapability(capability, .initialize, "native/host-api");
        var found = false;
        for (native_boundary_runtime.state.diagnostics.items) |diagnostic| {
            if (std.mem.indexOf(u8, diagnostic.message, denial.capability.jsonName()) != null and
                std.mem.indexOf(u8, diagnostic.message, denial.branch.jsonName()) != null and
                std.mem.indexOf(u8, diagnostic.message, "\"category\":\"denied_capability\"") != null and
                std.mem.indexOf(u8, diagnostic.message, "\"mode\":\"native/host-api\"") != null)
            {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    const process_snapshot = try process_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(process_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot, "\"id\":\"tool.use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot, "\"name\":\"process-display-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot, "native.fixture.echo") == null);
    try std.testing.expect(std.mem.indexOf(u8, process_snapshot, "builtin.truncateHead") == null);

    const wasm_snapshot = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(wasm_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, wasm_snapshot, "\"name\":\"builtin.truncateHead\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_snapshot, "\"id\":\"tool.use\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, wasm_snapshot, "native.fixture.echo") == null);

    const native_snapshot = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(native_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot, "\"name\":\"native.fixture.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot, "\"id\":\"tool.use\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot, "builtin.truncateHead") == null);
    try std.testing.expect(std.mem.indexOf(u8, native_snapshot, "process-display-tool") == null);

    try wasm_adapter.shutdown();
    try native_adapter.shutdown();
    try process_adapter.shutdown();
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    try std.testing.expect(native_adapter.hasShutdownComplete());
    try std.testing.expect(process_adapter.hasShutdownComplete());
}

test "runtime validation failures occur before registration while process_jsonl remains compatible" {
    const allocator = std.testing.allocator;

    var denied_wasm_manifest = try wasm_manifest.validateManifestText(allocator, "test/fixtures/wasm/pure-truncate-head-v0",
        \\{"schemaVersion":"pi-extension.v0","id":"com.pi.denied-before-artifact","name":"Denied Before Artifact","version":"0.1.0","description":"Denied capability before artifact handoff","artifact":{"kind":"wasm-component","path":"wasm/missing.wasm"},"tool":{"id":"builtin.truncateHead","description":"Keeps the beginning of content within line and byte limits.","inputSchema":{},"outputSchema":{}},"capabilities":["file.read"],"resourceLimits":{"timeoutMs":10,"toolScopes":["builtin.truncateHead"]}}
    );
    defer denied_wasm_manifest.deinit(allocator);
    try std.testing.expect(denied_wasm_manifest == .invalid);
    try std.testing.expectEqual(@as(usize, 1), denied_wasm_manifest.invalid.len);
    try std.testing.expectEqualStrings("denied_capability", denied_wasm_manifest.invalid[0].category);
    try std.testing.expectEqual(wasm_manifest.Capability.file_read, denied_wasm_manifest.invalid[0].capability.?);
    try std.testing.expect(std.mem.indexOf(u8, denied_wasm_manifest.invalid[0].message, "artifact file was not found") == null);

    const invalid_native_descriptor: NativeDescriptor = .{
        .id = "com.pi.invalid-native-preregistration",
        .name = "Invalid Native Preregistration",
        .version = "0.1.0",
        .description = "Forbidden fields are rejected before static descriptor registration",
        .tools = &.{native_static_tool},
        .remote_url = "https://example.invalid/remote.wasm",
        .workflow_preset = "workflow",
    };
    try std.testing.expectEqualStrings("remote_url", invalid_native_descriptor.firstForbiddenField().?);
    try std.testing.expectError(error.ForbiddenNativeDescriptorField, startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &invalid_native_descriptor,
    } }));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "validation-process-jsonl-compat.jsonl");
    defer allocator.free(capture_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"compat-pending\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{{\"text\":\"compat\"}}}}\\n'; " ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"compat-tool\",\"label\":\"Compat Tool\",\"description\":\"process registry remains compatible\",\"parameters\":{{\"type\":\"object\"}},\"extensionPath\":\"fixture/compat.ts\"}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);
    const process_argv = [_][]const u8{ "/bin/sh", "-c", script, "process-jsonl-validation-compat" };

    const adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "validation-compat-marker",
            .cwd = "/validation-compat-cwd",
            .fixture = "validation-compat",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while ((adapter.pendingCount() < 1 or adapter.registryFramesApplied() < 1) and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "compat-tool"));
    try adapter.sendExtensionUiResponse("compat-pending", "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"initialize\",\"marker\":\"validation-compat-marker\",\"cwd\":\"/validation-compat-cwd\",\"fixture\":\"validation-compat\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"compat-pending\",\"payload\":{\"ok\":true}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"shutdown\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "denied-before-artifact") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "invalid-native-preregistration") == null);
}

test "process_jsonl runtime adapter preserves registry UI response event and shutdown semantics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-jsonl-adapter-capture.jsonl");
    defer allocator.free(capture_path);
    const cwd_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-jsonl-adapter-cwd.txt");
    defer allocator.free(cwd_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "pwd > {s}; " ++
            "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"notify\",\"method\":\"notice\",\"responseRequired\":false,\"payload\":{{\"ok\":true}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{{\"text\":\"x\"}}}}\\n'; " ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"adapter-tool\",\"label\":\"Adapter Tool\",\"description\":\"Adapter tool\",\"parameters\":{{\"type\":\"object\"}},\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_command\",\"name\":\"adapter-command\",\"description\":\"Adapter\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_shortcut\",\"shortcut\":\"ctrl+a\",\"command\":\"adapter-command\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_flag\",\"name\":\"adapter-flag\",\"valueType\":\"string\",\"default\":\"default\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_provider\",\"name\":\"adapter-provider\",\"displayName\":\"Adapter Provider\",\"api\":\"openai-completions\",\"models\":[{{\"id\":\"adapter-model\",\"name\":\"Adapter Model\"}}],\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_capability\",\"id\":\"adapter-capability\",\"kind\":\"workflow\",\"title\":\"Adapter Capability\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"promptPaths\":[\"fixture/prompts\"],\"themePaths\":[\"fixture/themes\"],\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"set_header\",\"lines\":[\"Adapter header\"],\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"set_footer\",\"lines\":[\"Adapter footer\"],\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_terminal_input\",\"id\":\"adapter-terminal-input\",\"consume\":false,\"transformTo\":\"rewritten\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"set_editor_component\",\"label\":\"Adapter editor\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"set_widget\",\"key\":\"adapter-widget\",\"lines\":[\"Adapter widget\"],\"placement\":\"belowEditor\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_message_renderer\",\"customType\":\"adapter-message\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{ cwd_path, capture_path, capture_path },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "process-jsonl-runtime-adapter" };

    const adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "adapter-marker",
            .cwd = "/adapter-initialize-cwd",
            .fixture = "adapter-fixture",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer adapter.deinit();
    try std.testing.expectEqual(RuntimeKind.process_jsonl, adapter.kind);

    try expectAdapterRegistryUiEventShutdownConformance(allocator, adapter);

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"initialize\",\"marker\":\"adapter-marker\",\"cwd\":\"/adapter-initialize-cwd\",\"fixture\":\"adapter-fixture\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"pending\",\"payload\":{\"accepted\":true}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"unknown\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"agent_start\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"agent_end\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"shutdown\"}\n") != null);

    const child_cwd = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, cwd_path, allocator, .unlimited);
    defer allocator.free(child_cwd);
    try std.testing.expect(std.mem.eql(u8, "/tmp\n", child_cwd) or std.mem.eql(u8, "/private/tmp\n", child_cwd));
}

test "process_jsonl runtime adapter applies duplicate and unregister registry frames deterministically" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"register_tool\",\"name\":\"duplicate-tool\",\"label\":\"Tool One\",\"description\":\"first\",\"parameters\":{\"type\":\"object\",\"properties\":{\"first\":{\"type\":\"string\"}}},\"extensionPath\":\"fixture/duplicate.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_tool\",\"name\":\"duplicate-tool\",\"label\":\"Tool Two\",\"description\":\"second\",\"parameters\":{\"type\":\"object\",\"properties\":{\"second\":{\"type\":\"string\"}}},\"extensionPath\":\"fixture/duplicate.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_provider\",\"name\":\"duplicate-provider\",\"displayName\":\"Duplicate Provider\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"first\",\"name\":\"First\"}],\"extensionPath\":\"fixture/duplicate.ts\"}\\n'; " ++
        "printf '{\"type\":\"unregister_provider\",\"name\":\"missing-provider\"}\\n'; " ++
        "printf '{\"type\":\"unregister_provider\",\"name\":\"duplicate-provider\"}\\n'; " ++
        "printf '{\"type\":\"clear_extension_registrations\",\"extensionPath\":\"fixture/missing.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_tool\",\"label\":\"missing name\",\"extensionPath\":\"fixture/duplicate.ts\"}\\n'; " ++
        "printf '{\"type\":\"unsupported_registry_frame\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "process-jsonl-runtime-duplicate-registry" };

    const adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "duplicate-registry-marker",
            .cwd = "/duplicate-registry-cwd",
            .fixture = "duplicate-registry",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while (adapter.registryFramesApplied() < 6 and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 6), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());

    const snapshot_one = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_one);
    const snapshot_two = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot_two);
    try std.testing.expectEqualStrings(snapshot_one, snapshot_two);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "\"name\":\"duplicate-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "\"label\":\"Tool Two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "\"description\":\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "\"second\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "\"label\":\"Tool One\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_one, "duplicate-provider") == null);

    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
}

test "runtime-owned tool execution conformance preserves process wasm and native contracts" {
    const allocator = std.testing.allocator;
    const process_script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"register_tool\",\"name\":\"process-owned-tool\",\"label\":\"Process Tool\",\"description\":\"registered by process\",\"parameters\":{\"type\":\"object\"},\"extensionPath\":\"fixture/process-tool.ts\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const process_argv = [_][]const u8{ "/bin/sh", "-c", process_script, "process-jsonl-tool-contract" };
    const process_adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "process-tool-contract",
            .cwd = "/process-tool-contract-cwd",
            .fixture = "process-tool-contract",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter.registryFramesApplied() < 1 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), process_adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try process_adapter.agentTool(allocator, "process-owned-tool"));
    try process_adapter.shutdown();
    try std.testing.expect(process_adapter.hasShutdownComplete());

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try expectWasmToolSubsetConformance(allocator, wasm_adapter, manifest_result.valid.artifact_absolute_path);
    try wasm_adapter.shutdown();
    try std.testing.expect(wasm_adapter.hasShutdownComplete());

    const native_adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);
    var native_tool = (try native_adapter.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &native_tool);
    var native_success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"tool-contract\"}", .{});
    defer native_success_params.deinit();
    const native_success = try native_tool.execute.?(allocator, "native-tool-contract-success", native_success_params.value, native_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, native_success.content);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"tool-contract\"}", native_success.content[0].text.text);

    var native_invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    defer native_invalid_params.deinit();
    const native_invalid = try native_tool.execute.?(allocator, "native-tool-contract-invalid", native_invalid_params.value, native_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, native_invalid.content);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with string field value\"}}",
        native_invalid.content[0].text.text,
    );
    try std.testing.expectEqual(@as(usize, 1), native_adapter.diagnosticCategoryCount(.host_error));
    try native_adapter.shutdown();
    try std.testing.expect(native_adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try native_adapter.agentTool(allocator, "native.fixture.echo"));
}

test "process_jsonl runtime adapter carries subscriber readiness envelopes byte stably" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-jsonl-subscriber-envelope-capture.jsonl");
    defer allocator.free(capture_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "process-jsonl-subscriber-envelope" };

    const adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "subscriber-envelope-marker",
            .cwd = "/subscriber-envelope-cwd",
            .fixture = "subscriber-envelope-fixture",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(500);

    const subscriber_envelope =
        "{\"type\":\"before_agent_start\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"task\":{\"taskId\":\"task-opaque\",\"parentAgentId\":\"parent-opaque\",\"input\":{\"text\":\"delegate\"}},\"requestedGrants\":[\"agent.spawn\"],\"cancellation\":{\"signalId\":\"cancel-1\",\"parentRunId\":\"parent-run\",\"state\":\"pending\"},\"limits\":{\"maxChildren\":0,\"depth\":1,\"timeoutMs\":2500,\"outputBytes\":4096,\"toolScopes\":[\"read-only\"]},\"readiness\":{\"kind\":\"sub_agent_task_invocation\",\"sessionId\":\"session-opaque\",\"toolCallId\":\"tool-call-opaque\"}}";
    adapter.sendExtensionEventFrame(subscriber_envelope);

    var elapsed: u64 = 0;
    while (elapsed <= 200) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }

    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    adapter.sendExtensionEventFrame("{\"type\":\"agent_end\",\"messages\":[]}");

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expectEqualStrings(
        subscriber_envelope ++ "\n{\"type\":\"shutdown\"}\n",
        capture,
    );
}

test "wasm runtime ignores subscriber event envelopes without tool or unload side effects" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.diagnosticCount());

    adapter.sendExtensionEventFrame(
        "{\"type\":\"before_agent_start\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"requestedGrants\":[\"agent.spawn\"],\"limits\":{\"maxChildren\":0},\"readiness\":{\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\"}}",
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.diagnosticCount());

    var registry_expect = WasmToolRegistryExpectContext{ .expected_artifact_path = manifest_result.valid.artifact_absolute_path };
    try adapter.withRegistry(&registry_expect, expectWasmToolOnlyRegistry);

    var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\\nbravo\\ncharlie\",\"maxLines\":2,\"maxBytes\":1024}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "wasm-subscriber-envelope-success", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    try std.testing.expectEqual(@as(usize, 1), success.content.len);
    try std.testing.expect(std.mem.indexOf(u8, success.content[0].text.text, "\"content\":\"alpha\\nbravo\"") != null);

    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try adapter.agentTool(allocator, "builtin.truncateHead"));
    const unloaded_snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(unloaded_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, unloaded_snapshot, "\"tools\":[]") != null);
}

test "runtime adapter event surface matrix is explicit across process wasm and native" {
    const allocator = std.testing.allocator;
    const event_surfaces = extension_events.eventSurfaceNames();
    try std.testing.expect(event_surfaces.len > 0);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-jsonl-event-surface-matrix.jsonl");
    defer allocator.free(capture_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
    defer allocator.free(script);
    const process_argv = [_][]const u8{ "/bin/sh", "-c", script, "process-jsonl-event-surface-matrix" };
    const process_adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "event-surface-matrix",
            .cwd = "/event-surface-matrix-cwd",
            .fixture = "event-surface-matrix",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);

    for (event_surfaces, 0..) |event_surface, index| {
        const frame = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"surfaceIndex\":{d}}}", .{ event_surface, index });
        defer allocator.free(frame);
        process_adapter.sendExtensionEventFrame(frame);
    }
    process_adapter.sendExtensionEventFrame("{\"type\":\"unsupported_event_surface\",\"payload\":{\"stable\":true}}");
    process_adapter.sendExtensionEventFrame("{");
    var process_elapsed: u64 = 0;
    while (process_elapsed <= 200) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try process_adapter.shutdown();
    try std.testing.expect(process_adapter.hasShutdownComplete());
    process_adapter.sendExtensionEventFrame("{\"type\":\"post_shutdown_event\"}");

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    for (event_surfaces) |event_surface| {
        const needle = try std.fmt.allocPrint(allocator, "\"type\":\"{s}\"", .{event_surface});
        defer allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, capture, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"unsupported_event_surface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"shutdown\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "post_shutdown_event") == null);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_adapter = try startRuntime(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try wasm_adapter.waitForReady(0);
    const wasm_snapshot_before = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(wasm_snapshot_before);
    for (event_surfaces, 0..) |event_surface, index| {
        const frame = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"surfaceIndex\":{d}}}", .{ event_surface, index });
        defer allocator.free(frame);
        wasm_adapter.sendExtensionEventFrame(frame);
    }
    wasm_adapter.sendExtensionEventFrame("{\"type\":\"unsupported_event_surface\"}");
    wasm_adapter.sendExtensionEventFrame("{");
    const wasm_snapshot_after = try wasm_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(wasm_snapshot_after);
    try std.testing.expectEqualStrings(wasm_snapshot_before, wasm_snapshot_after);
    try std.testing.expectEqual(@as(usize, 0), wasm_adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), wasm_adapter.diagnosticCount());

    const native_adapter = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);
    const native_snapshot_before = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(native_snapshot_before);
    for (event_surfaces, 0..) |event_surface, index| {
        const frame = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"surfaceIndex\":{d}}}", .{ event_surface, index });
        defer allocator.free(frame);
        native_adapter.sendExtensionEventFrame(frame);
    }
    native_adapter.sendExtensionEventFrame("{\"type\":\"unsupported_event_surface\"}");
    native_adapter.sendExtensionEventFrame("{");
    const native_snapshot_after = try native_adapter.snapshotRegistryJson(allocator);
    defer allocator.free(native_snapshot_after);
    try std.testing.expectEqualStrings(native_snapshot_before, native_snapshot_after);
    try std.testing.expectEqual(@as(usize, 0), native_adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), native_adapter.diagnosticCount());

    try wasm_adapter.shutdown();
    try native_adapter.shutdown();
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    try std.testing.expect(native_adapter.hasShutdownComplete());
    wasm_adapter.sendExtensionEventFrame("{\"type\":\"post_shutdown_event\"}");
    native_adapter.sendExtensionEventFrame("{\"type\":\"post_shutdown_event\"}");
    try std.testing.expectEqual(@as(usize, 0), wasm_adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), native_adapter.pendingCount());
}

test "process_jsonl runtime adapter preserves readiness diagnostics timeout and startup errors" {
    const allocator = std.testing.allocator;

    const missing_argv = [_][]const u8{ "/tmp/pi-runtime-adapter-missing-host", "--adapter-startup-failure" };
    try std.testing.expectError(error.FileNotFound, startProcessJsonl(allocator, std.testing.io, .{
        .argv = &missing_argv,
        .initialize = .{
            .marker = "adapter-startup-failure",
            .cwd = "/tmp",
            .fixture = "startup-failure",
        },
        .shutdown_timeout_ms = 50,
    }));

    const timeout_script = "IFS= read -r init; sleep 1";
    const timeout_argv = [_][]const u8{ "/bin/sh", "-c", timeout_script, "process-jsonl-runtime-timeout" };
    const timeout_adapter = try startProcessJsonl(allocator, std.testing.io, .{
        .argv = &timeout_argv,
        .initialize = .{
            .marker = "adapter-timeout",
            .cwd = "/tmp",
            .fixture = "timeout",
        },
        .shutdown_timeout_ms = 50,
    });
    defer timeout_adapter.deinit();
    try std.testing.expectError(error.HostNotReady, timeout_adapter.waitForReady(20));
    try timeout_adapter.shutdown();

    const duplicate_ready_script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const duplicate_ready_argv = [_][]const u8{ "/bin/sh", "-c", duplicate_ready_script, "process-jsonl-runtime-duplicate-ready" };
    const duplicate_ready_adapter = try startProcessJsonl(allocator, std.testing.io, .{
        .argv = &duplicate_ready_argv,
        .initialize = .{
            .marker = "adapter-duplicate-ready",
            .cwd = "/tmp",
            .fixture = "duplicate-ready",
        },
        .shutdown_timeout_ms = 500,
    });
    defer duplicate_ready_adapter.deinit();
    try duplicate_ready_adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while (duplicate_ready_adapter.diagnosticCategoryCount(.duplicate_ready) == 0 and elapsed <= 500) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), duplicate_ready_adapter.diagnosticCategoryCount(.duplicate_ready));
    try std.testing.expect(duplicate_ready_adapter.diagnosticCount() >= 1);
    try duplicate_ready_adapter.shutdown();
    try std.testing.expect(duplicate_ready_adapter.hasShutdownComplete());
}
