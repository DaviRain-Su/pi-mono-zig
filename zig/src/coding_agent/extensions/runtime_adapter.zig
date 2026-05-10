const std = @import("std");
const agent = @import("agent");
const enforcement = @import("enforcement.zig");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");
const native_runtime = @import("native_runtime.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");

pub const DiagnosticCategory = extension_host.DiagnosticCategory;
pub const ExtensionUiRequest = extension_host.ExtensionUiRequest;
pub const ProcessJsonlOptions = extension_host.HostProcessOptions;
pub const Registry = extension_registry.Registry;
pub const RegistryCallback = *const fn (context: ?*anyopaque, registry: *const Registry) anyerror!void;
pub const NativeOptions = native_runtime.NativeOptions;

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
    policy_scope: []const u8 = "user",
    package_root: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    schema_version: []const u8,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    artifact_kind: wasm_manifest.ArtifactKind,
    artifact_path: []const u8,
    artifact_absolute_path: []const u8,
    artifact_sha256: ?[]const u8 = null,
    package_root_sha256: ?[]const u8 = null,
    tool_id: []const u8,
    tool_description: []const u8,
    input_schema_json: []const u8,
    output_schema_json: []const u8,
    hooks: []const RuntimeHookDefinition = &.{},
    requested_capabilities: []const wasm_manifest.Capability = &.{},
    approved_capabilities: []const wasm_manifest.Capability = &.{},
    resource_limits: enforcement.ResourceLimits = .{},
    policy_lookup_key: ?[]const u8 = null,

    pub fn fromManifest(manifest: *const wasm_manifest.Manifest) WasmManifestHandoff {
        return .{
            .package_root = manifest.package_root,
            .manifest_path = manifest.manifest_path,
            .schema_version = manifest.schema_version,
            .id = manifest.id,
            .name = manifest.name,
            .version = manifest.version,
            .description = manifest.description,
            .artifact_kind = manifest.artifact_kind,
            .artifact_path = manifest.artifact_path,
            .artifact_absolute_path = manifest.artifact_absolute_path,
            .artifact_sha256 = manifest.artifact_sha256,
            .package_root_sha256 = manifest.package_root_sha256,
            .tool_id = manifest.tool_id,
            .tool_description = manifest.tool_description,
            .input_schema_json = manifest.input_schema_json,
            .output_schema_json = manifest.output_schema_json,
            .requested_capabilities = manifest.requested_capabilities,
            .resource_limits = .{
                .max_children = manifest.resource_limits.max_children,
                .depth = manifest.resource_limits.depth,
                .turns = manifest.resource_limits.turns,
                .timeout_ms = manifest.resource_limits.timeout_ms,
                .output_bytes = manifest.resource_limits.output_bytes,
                .output_lines = manifest.resource_limits.output_lines,
                .tool_scopes = manifest.resource_limits.tool_scopes,
            },
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
        return wasm_manifest.denyFirstUnapprovedCapability(self.requested_capabilities, self.approved_capabilities, phase, mode);
    }
};

pub const RuntimeHookDefinition = struct {
    event_name: []const u8,
    extension_path: []const u8,
    priority: i64 = 0,
    declaration_order: ?usize = null,
    error_policy: extension_registry.HookErrorPolicy = .@"continue",
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

pub const RuntimeSetupErrorEvent = struct {
    runtime_kind: RuntimeKind,
    extension_id: []const u8,
    error_name: []const u8,
    message: []const u8,
    stop_reason: []const u8 = "error_reason",
};

pub const RuntimeSetupEvent = union(enum) {
    ready: RuntimeAdapter,
    error_event: RuntimeSetupErrorEvent,
};

pub const RuntimeSetupEventStream = struct {
    event: ?RuntimeSetupEvent,

    pub fn next(self: *RuntimeSetupEventStream) ?RuntimeSetupEvent {
        const event = self.event orelse return null;
        self.event = null;
        return event;
    }

    pub fn deinit(self: *RuntimeSetupEventStream) void {
        if (self.event) |event| {
            switch (event) {
                .ready => |adapter| adapter.deinit(),
                .error_event => {},
            }
            self.event = null;
        }
    }
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
        has_registered_hook: *const fn (*anyopaque, []const u8) bool,
        snapshot_registry_json: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        with_registry: *const fn (*anyopaque, ?*anyopaque, RegistryCallback) anyerror!void,
        apply_cli_flag_values: *const fn (*anyopaque, []const extension_registry.ParsedCliFlag) anyerror!void,
        agent_tool: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?agent.AgentTool,
        take_ui_requests: *const fn (*anyopaque, std.mem.Allocator) anyerror![]ExtensionUiRequest,
        send_extension_ui_response: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        send_extension_event_frame: *const fn (*anyopaque, []const u8) void,
        invoke_extension_event: *const fn (*anyopaque, std.mem.Allocator, []const u8, std.json.Value, u64) anyerror!?std.json.Value,
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

    pub fn hasRegisteredHook(self: RuntimeAdapter, event_name: []const u8) bool {
        return self.vtable.has_registered_hook(self.ptr, event_name);
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

    pub fn invokeExtensionEvent(
        self: RuntimeAdapter,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        event: std.json.Value,
        timeout_ms: u64,
    ) !?std.json.Value {
        return try self.vtable.invoke_extension_event(self.ptr, allocator, event_name, event, timeout_ms);
    }

    pub fn shutdown(self: RuntimeAdapter) !void {
        try self.vtable.shutdown(self.ptr);
    }

    pub fn deinit(self: RuntimeAdapter) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const RuntimeAdapterDispatch = struct {
    process_jsonl: *const fn (std.mem.Allocator, std.Io, ProcessJsonlOptions) anyerror!RuntimeAdapter,
    wasm: *const fn (std.mem.Allocator, std.Io, WasmOptions) anyerror!RuntimeAdapter,
    native: *const fn (std.mem.Allocator, std.Io, NativeOptions) anyerror!RuntimeAdapter,
};

pub fn startRuntimeWithDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
    dispatch: RuntimeAdapterDispatch,
) !RuntimeSetupEventStream {
    const adapter = startRuntimeAdapterWithDispatch(allocator, io, options, dispatch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .event = .{ .error_event = .{
            .runtime_kind = runtimeSetupKind(options),
            .extension_id = runtimeSetupExtensionId(options),
            .error_name = @errorName(err),
            .message = "runtime setup failed before extension activation completed",
        } } },
    };
    return .{ .event = .{ .ready = adapter } };
}

pub fn streamRuntimeSetupWithDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
    dispatch: RuntimeAdapterDispatch,
) !RuntimeSetupEventStream {
    return try startRuntimeWithDispatch(allocator, io, options, dispatch);
}

pub fn startRuntimeAdapterWithDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
    dispatch: RuntimeAdapterDispatch,
) !RuntimeAdapter {
    return switch (options) {
        .process_jsonl => |process_options| try dispatch.process_jsonl(allocator, io, process_options),
        .wasm => |wasm_options| try dispatch.wasm(allocator, io, wasm_options),
        .native => |native_options| try dispatch.native(allocator, io, native_options),
        .remote => error.UnsupportedRuntime,
    };
}

fn runtimeSetupKind(options: RuntimeOptions) RuntimeKind {
    return switch (options) {
        .process_jsonl => .process_jsonl,
        .wasm => .wasm,
        .native => .native,
        .remote => .remote,
    };
}

fn runtimeSetupExtensionId(options: RuntimeOptions) []const u8 {
    return switch (options) {
        .process_jsonl => |process_options| process_options.extension_path orelse "process_jsonl",
        .wasm => |wasm_options| wasm_options.manifest.id,
        .native => |native_options| native_options.descriptor.id,
        .remote => |remote_options| remote_options.label orelse "remote",
    };
}
