// TODO(review-B9): This file is 6286 LOC and covers too many concerns
// (extension discovery, Bun host, native extension, WASM, event bridge,
// JSON-RPC, workflow, package install). Split into extension_loader.zig,
// extension_lifecycle.zig, extension_event_bridge.zig.
const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const config_mod = @import("../config/config.zig");
const enforcement = @import("enforcement.zig");
const extension_events = @import("extension_events.zig");
const extension_host = @import("extension_host.zig");
const extension_manifest = @import("extension_manifest.zig");
const extension_registry = @import("extension_registry.zig");
const workflow_execution = @import("workflow_execution.zig");
const native_runtime = @import("native_runtime.zig");
const sdk = @import("sdk.zig");
const resources_mod = @import("../resources/resources.zig");
const tools_common = @import("../tools/common.zig");
const wasm_host = @import("wasm/wasm_host_spike.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");
const lifecycle_support = @import("lifecycle_support.zig");

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
pub const NativeHookDefinition = native_runtime.NativeHookDefinition;
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

pub const default_extension_handler_timeout_ms = lifecycle_support.default_extension_handler_timeout_ms;
pub const LifecycleSupportRuntime = lifecycle_support.LifecycleSupportRuntime;
pub const LifecycleSupportEntry = lifecycle_support.LifecycleSupportEntry;
pub const lifecycleSupportMatrix = lifecycle_support.lifecycleSupportMatrix;

pub const TypeScriptPolicyLookupOptions = struct {
    configured_path: []const u8,
    resolved_path: []const u8,
    source_info: resources_mod.SourceInfo,
};

pub fn typeScriptPolicyLookupKey(allocator: std.mem.Allocator, options: TypeScriptPolicyLookupOptions) ![]u8 {
    const configured_path = try toPolicyPathAlloc(allocator, options.configured_path);
    defer allocator.free(configured_path);
    const resolved_path = try toPolicyPathAlloc(allocator, options.resolved_path);
    defer allocator.free(resolved_path);

    if (configured_path.len >= 2 and configured_path[0] == '<' and configured_path[configured_path.len - 1] == '>') {
        const source = if (options.source_info.source.len > 0) options.source_info.source else "temporary";
        return std.fmt.allocPrint(allocator, "typescript:inline:{s}:{s}", .{ source, configured_path });
    }

    const scope = sourceScopeName(options.source_info.scope);
    if (options.source_info.origin == .package) {
        const entry_path = try relativePolicyPathAlloc(allocator, options.source_info.base_dir, resolved_path) orelse
            try allocator.dupe(u8, resolved_path);
        defer allocator.free(entry_path);
        return std.fmt.allocPrint(
            allocator,
            "typescript:package:{s}:{s}:{s}:{s}",
            .{ scope, options.source_info.source, entry_path, resolved_path },
        );
    }

    return std.fmt.allocPrint(allocator, "typescript:local:{s}:{s}", .{ scope, resolved_path });
}

pub const WasmManifestPolicyLookupOptions = struct {
    schema_version: []const u8,
    id: []const u8,
    version: []const u8,
    package_root: []const u8,
    manifest_path: []const u8,
    artifact_path: []const u8,
};

pub fn wasmManifestPolicyLookupKey(allocator: std.mem.Allocator, options: WasmManifestPolicyLookupOptions) ![]u8 {
    const package_root = try toPolicyPathAlloc(allocator, options.package_root);
    defer allocator.free(package_root);
    const manifest_path = try toPolicyPathAlloc(allocator, options.manifest_path);
    defer allocator.free(manifest_path);
    const artifact_path = try toPolicyPathAlloc(allocator, options.artifact_path);
    defer allocator.free(artifact_path);
    return std.fmt.allocPrint(
        allocator,
        "wasm:manifest:{s}:{s}:{s}:{s}:{s}:{s}",
        .{ options.schema_version, options.id, options.version, package_root, manifest_path, artifact_path },
    );
}

pub fn wasmPolicyLookupKey(allocator: std.mem.Allocator, manifest: WasmManifestHandoff) ![]u8 {
    const manifest_path = try toPolicyPathAlloc(allocator, manifest.manifest_path orelse "");
    defer allocator.free(manifest_path);
    const artifact_absolute_path = try toPolicyPathAlloc(allocator, manifest.artifact_absolute_path);
    defer allocator.free(artifact_absolute_path);
    return std.fmt.allocPrint(
        allocator,
        "wasm:locked:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}",
        .{
            manifest.policy_scope,
            manifest.schema_version,
            manifest.id,
            manifest.version,
            manifest.package_root_sha256 orelse "",
            manifest.artifact_sha256 orelse "",
            manifest_path,
            artifact_absolute_path,
        },
    );
}

pub fn nativePolicyLookupKey(allocator: std.mem.Allocator, descriptor: NativeDescriptor) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "native:{s}:{s}:{s}",
        .{ descriptor.id, descriptor.version, descriptor.name },
    );
}

pub fn processJsonlPolicyLookupKey(allocator: std.mem.Allocator, options: ProcessJsonlOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("process_jsonl:{\"argv\":[");
    for (options.argv, 0..) |arg, index| {
        if (index > 0) try out.writer.writeAll(",");
        const normalized = try toPolicyPathAlloc(allocator, arg);
        defer allocator.free(normalized);
        try writeJsonString(&out.writer, normalized);
    }
    try out.writer.writeAll("]");
    if (options.extension_path) |extension_path| {
        const normalized = try toPolicyPathAlloc(allocator, extension_path);
        defer allocator.free(normalized);
        try out.writer.writeAll(",\"extensionPath\":");
        try writeJsonString(&out.writer, normalized);
    }
    if (options.cwd) |cwd| {
        const resolved = try std.fs.path.resolve(allocator, &.{cwd});
        defer allocator.free(resolved);
        const normalized = try toPolicyPathAlloc(allocator, resolved);
        defer allocator.free(normalized);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonString(&out.writer, normalized);
    }
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn toPolicyPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, value);
    for (normalized) |*char| {
        if (char.* == '\\') char.* = '/';
    }
    return normalized;
}

fn sourceScopeName(scope: resources_mod.SourceScope) []const u8 {
    return switch (scope) {
        .temporary => "temporary",
        .project => "project",
        .user => "user",
    };
}

fn relativePolicyPathAlloc(allocator: std.mem.Allocator, base_dir: ?[]const u8, file_path: []const u8) !?[]u8 {
    const raw_base = base_dir orelse return null;
    const base = try toPolicyPathAlloc(allocator, raw_base);
    defer allocator.free(base);
    var base_len = base.len;
    while (base_len > 0 and base[base_len - 1] == '/') base_len -= 1;
    const trimmed_base = base[0..base_len];
    if (trimmed_base.len == 0) return null;
    if (std.mem.eql(u8, trimmed_base, file_path)) return null;
    if (!std.mem.startsWith(u8, file_path, trimmed_base)) return null;
    if (file_path.len <= trimmed_base.len or file_path[trimmed_base.len] != '/') return null;
    return try allocator.dupe(u8, file_path[trimmed_base.len + 1 ..]);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

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

pub fn startRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
) !RuntimeSetupEventStream {
    const adapter = startRuntimeAdapter(allocator, io, options) catch |err| switch (err) {
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

pub fn streamRuntimeSetup(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
) !RuntimeSetupEventStream {
    return try startRuntime(allocator, io, options);
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

pub fn approvedCapabilitiesFromExtensionPolicy(
    allocator: std.mem.Allocator,
    policy: config_mod.ExtensionPolicy,
) ![]wasm_manifest.Capability {
    const approved_grants = policy.approved_grants orelse return allocator.alloc(wasm_manifest.Capability, 0);
    var capabilities = std.ArrayList(wasm_manifest.Capability).empty;
    errdefer capabilities.deinit(allocator);
    for (approved_grants) |grant| {
        if (wasm_manifest.parseCapability(grant)) |capability| {
            try capabilities.append(allocator, capability);
        }
    }
    return capabilities.toOwnedSlice(allocator);
}

pub fn enforcementResourceLimitsFromExtensionPolicy(
    limits: ?config_mod.ExtensionResourceLimits,
) enforcement.ResourceLimits {
    const resource_limits = limits orelse return .{};
    return .{
        .max_children = resource_limits.max_children,
        .depth = resource_limits.depth,
        .turns = resource_limits.turns,
        .timeout_ms = resource_limits.timeout_ms,
        .output_bytes = resource_limits.output_bytes,
        .output_lines = resource_limits.output_lines,
        .tool_scopes = resource_limits.tool_scopes orelse &.{},
    };
}

pub fn nativeResourceLimitsFromExtensionPolicy(
    policy_limits: ?config_mod.ExtensionResourceLimits,
    descriptor_limits: NativeResourceLimits,
) NativeResourceLimits {
    const limits = policy_limits orelse return descriptor_limits;
    return .{
        .max_children = narrowOptionalLimit(limits.max_children, descriptor_limits.max_children),
        .depth = narrowOptionalLimit(limits.depth, descriptor_limits.depth),
        .turns = narrowOptionalLimit(limits.turns, descriptor_limits.turns),
        .timeout_ms = narrowOptionalLimit(limits.timeout_ms, descriptor_limits.timeout_ms),
        .output_bytes = narrowOptionalLimit(limits.output_bytes, descriptor_limits.output_bytes),
        .output_lines = narrowOptionalLimit(limits.output_lines, descriptor_limits.output_lines),
        .tool_scopes = limits.tool_scopes orelse descriptor_limits.tool_scopes,
    };
}

fn narrowOptionalLimit(policy_limit: ?u64, descriptor_limit: ?u64) ?u64 {
    if (policy_limit) |policy_value| {
        if (descriptor_limit) |descriptor_value| return @min(policy_value, descriptor_value);
        return policy_value;
    }
    return descriptor_limit;
}

pub fn deinitAgentTool(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    tools_common.deinitJsonValue(allocator, tool.parameters);
    if (tool.deinit_execute_context) |deinit_context| deinit_context(allocator, tool.execute_context);
    tool.* = undefined;
}

pub fn startRuntimeAdapter(allocator: std.mem.Allocator, io: std.Io, options: RuntimeOptions) !RuntimeAdapter {
    return switch (options) {
        .process_jsonl => |process_options| try startProcessJsonl(allocator, io, process_options),
        .wasm => |wasm_options| try startWasm(allocator, io, wasm_options),
        .native => |native_options| try startNative(allocator, io, native_options),
        .remote => error.UnsupportedRuntime,
    };
}

pub const LockedWasmRuntimeEntry = struct {
    package_root: []u8,
    manifest_path: []u8,
    tool_id: []u8,
    policy_lookup_key: []u8,
    adapter: RuntimeAdapter,

    fn deinit(self: *LockedWasmRuntimeEntry, allocator: std.mem.Allocator) void {
        self.adapter.shutdown() catch {};
        self.adapter.deinit();
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.tool_id);
        allocator.free(self.policy_lookup_key);
        self.* = undefined;
    }
};

pub const LockedWasmRuntimeSet = struct {
    allocator: std.mem.Allocator,
    entries: []LockedWasmRuntimeEntry,
    retired_entries: []LockedWasmRuntimeEntry = &.{},
    diagnostics: []resources_mod.Diagnostic,

    pub fn deinit(self: *LockedWasmRuntimeSet) void {
        for (self.entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.entries);
        for (self.retired_entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.retired_entries);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(self.allocator);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn agentTool(self: *LockedWasmRuntimeSet, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
        for (self.entries) |entry| {
            if (try entry.adapter.agentTool(allocator, name)) |tool| return tool;
        }
        return null;
    }

    pub fn unloadPackage(self: *LockedWasmRuntimeSet, package_root: []const u8) !bool {
        var list = std.ArrayList(LockedWasmRuntimeEntry).fromOwnedSlice(self.entries);
        self.entries = &.{};
        var retired = std.ArrayList(LockedWasmRuntimeEntry).fromOwnedSlice(self.retired_entries);
        self.retired_entries = &.{};
        var removed = false;
        var index: usize = 0;
        while (index < list.items.len) {
            if (!std.mem.eql(u8, list.items[index].package_root, package_root)) {
                index += 1;
                continue;
            }
            try retired.ensureUnusedCapacity(self.allocator, 1);
            var entry = list.orderedRemove(index);
            entry.adapter.shutdown() catch {};
            retired.appendAssumeCapacity(entry);
            removed = true;
        }
        self.entries = try list.toOwnedSlice(self.allocator);
        self.retired_entries = try retired.toOwnedSlice(self.allocator);
        return removed;
    }

    pub fn addDiagnostic(
        self: *LockedWasmRuntimeSet,
        kind: []const u8,
        message: []const u8,
        path: []const u8,
    ) !void {
        const expanded = try self.allocator.alloc(resources_mod.Diagnostic, self.diagnostics.len + 1);
        errdefer self.allocator.free(expanded);
        @memcpy(expanded[0..self.diagnostics.len], self.diagnostics);
        expanded[self.diagnostics.len] = try makeResourceDiagnostic(self.allocator, kind, message, path);
        self.allocator.free(self.diagnostics);
        self.diagnostics = expanded;
    }
};

pub fn startLockedWasmPackageRuntimes(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    options: resources_mod.ResolveResourcesOptions,
) !LockedWasmRuntimeSet {
    var resolved = try resources_mod.resolveConfiguredLockedWasmPackages(allocator, io, options);
    defer resolved.deinit(allocator);

    var diagnostics = std.ArrayList(resources_mod.Diagnostic).empty;
    errdefer deinitResourceDiagnosticsList(allocator, &diagnostics);
    for (resolved.diagnostics) |diagnostic| {
        try diagnostics.append(allocator, try cloneResourceDiagnostic(allocator, diagnostic));
    }

    var entries = std.ArrayList(LockedWasmRuntimeEntry).empty;
    errdefer deinitLockedWasmRuntimeEntryList(allocator, &entries);
    var seen_tools = std.StringHashMap(void).init(allocator);
    defer seen_tools.deinit();

    for (resolved.packages) |package| {
        var handoff = WasmManifestHandoff.fromManifest(&package.manifest);
        handoff.policy_scope = package.lock_entry.scope.jsonName();
        const policy_key = try wasmPolicyLookupKey(allocator, handoff);
        defer allocator.free(policy_key);
        handoff.policy_lookup_key = policy_key;

        const policy = runtime_config.getExtensionPolicy(policy_key) orelse {
            if (try findStaleLockedWasmPolicyKey(allocator, runtime_config, handoff)) |attempted_policy| {
                defer allocator.free(attempted_policy);
                const message = try std.fmt.allocPrint(
                    allocator,
                    "phase=registration; tool={s}; source={s}; scope={s}; packageRoot={s}; packageRootSha256={s}; artifactSha256={s}; attemptedPolicy={s}; requiredPolicy={s}; stale digest-bound wasm extension policy",
                    .{
                        package.manifest.tool_id,
                        package.source_info.source,
                        package.lock_entry.scope.jsonName(),
                        package.manifest.package_root,
                        package.manifest.package_root_sha256,
                        package.manifest.artifact_sha256,
                        attempted_policy,
                        policy_key,
                    },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, "policy_digest_mismatch", message, package.manifest.manifest_path));
            } else {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "phase=registration; tool={s}; source={s}; scope={s}; packageRoot={s}; packageRootSha256={s}; artifactSha256={s}; requiredPolicy={s}; missing exact digest-bound wasm extension policy",
                    .{
                        package.manifest.tool_id,
                        package.source_info.source,
                        package.lock_entry.scope.jsonName(),
                        package.manifest.package_root,
                        package.manifest.package_root_sha256,
                        package.manifest.artifact_sha256,
                        policy_key,
                    },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, "missing_policy", message, package.manifest.manifest_path));
            }
            continue;
        };
        const approved_capabilities = try approvedCapabilitiesFromExtensionPolicy(allocator, policy);
        defer allocator.free(approved_capabilities);
        handoff.approved_capabilities = approved_capabilities;
        handoff.resource_limits = enforcementResourceLimitsFromExtensionPolicy(policy.resource_limits);

        if (handoff.deniedRuntimeCapability(.initialize, "runtime/handoff")) |denial| {
            const message = try std.fmt.allocPrint(
                allocator,
                "phase={s}; category={s}; capability={s}; branch={s}; mode={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; policyDigest={s}; requiredPolicy={s}; wasm extension capability denied before runtime registration",
                .{
                    denial.phase.jsonName(),
                    denial.category,
                    denial.capability.jsonName(),
                    denial.branch.jsonName(),
                    denial.mode,
                    package.manifest.tool_id,
                    package.source_info.source,
                    package.lock_entry.scope.jsonName(),
                    package.manifest.package_root,
                    package.manifest.manifest_path,
                    package.manifest.artifact_absolute_path,
                    package.manifest.package_root_sha256,
                    package.manifest.artifact_sha256,
                    policy_key,
                    policy_key,
                },
            );
            defer allocator.free(message);
            try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, denial.category, message, package.manifest.manifest_path));
            continue;
        }

        const seen = try seen_tools.getOrPut(package.manifest.tool_id);
        if (seen.found_existing) {
            const message = try std.fmt.allocPrint(
                allocator,
                "phase=registration; tool={s}; packageRoot={s}; duplicate locked wasm tool id",
                .{ package.manifest.tool_id, package.manifest.package_root },
            );
            defer allocator.free(message);
            try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, "duplicate_wasm_tool", message, package.manifest.manifest_path));
            continue;
        }

        const adapter = startRuntimeAdapter(allocator, io, .{ .wasm = .{ .manifest = handoff } }) catch |err| {
            _ = seen_tools.remove(package.manifest.tool_id);
            const message = try std.fmt.allocPrint(
                allocator,
                "phase=load; category={s}; extension={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; abi=wasm-component; contract={s}; reason={s}; wasm runtime contract failed closed before tool registration",
                .{
                    runtimeContractCategory(err),
                    package.manifest.id,
                    package.manifest.tool_id,
                    package.source_info.source,
                    package.lock_entry.scope.jsonName(),
                    package.manifest.package_root,
                    package.manifest.manifest_path,
                    package.manifest.artifact_absolute_path,
                    package.manifest.package_root_sha256,
                    package.manifest.artifact_sha256,
                    package.manifest.schema_version,
                    @errorName(err),
                },
            );
            defer allocator.free(message);
            try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, runtimeContractCategory(err), message, package.manifest.manifest_path));
            continue;
        };
        {
            var entry = LockedWasmRuntimeEntry{
                .package_root = try allocator.dupe(u8, package.manifest.package_root),
                .manifest_path = try allocator.dupe(u8, package.manifest.manifest_path),
                .tool_id = try allocator.dupe(u8, package.manifest.tool_id),
                .policy_lookup_key = try allocator.dupe(u8, policy_key),
                .adapter = adapter,
            };
            errdefer entry.deinit(allocator);
            try entries.append(allocator, entry);
        }
    }

    return .{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(allocator),
        .retired_entries = &.{},
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn findStaleLockedWasmPolicyKey(
    allocator: std.mem.Allocator,
    runtime_config: *const config_mod.RuntimeConfig,
    manifest: WasmManifestHandoff,
) !?[]u8 {
    var policies = runtime_config.settings.extension_policies orelse return null;
    const prefix = try std.fmt.allocPrint(
        allocator,
        "wasm:locked:{s}:{s}:{s}:{s}:",
        .{ manifest.policy_scope, manifest.schema_version, manifest.id, manifest.version },
    );
    defer allocator.free(prefix);
    var iterator = policies.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
            return try allocator.dupe(u8, entry.key_ptr.*);
        }
    }
    return null;
}

fn deinitLockedWasmRuntimeEntryList(allocator: std.mem.Allocator, entries: *std.ArrayList(LockedWasmRuntimeEntry)) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn cloneResourceDiagnostic(allocator: std.mem.Allocator, diagnostic: resources_mod.Diagnostic) !resources_mod.Diagnostic {
    return .{
        .kind = try allocator.dupe(u8, diagnostic.kind),
        .message = try allocator.dupe(u8, diagnostic.message),
        .path = if (diagnostic.path) |value| try allocator.dupe(u8, value) else null,
    };
}

fn makeResourceDiagnostic(allocator: std.mem.Allocator, kind: []const u8, message: []const u8, path: []const u8) !resources_mod.Diagnostic {
    const redacted_message = try resources_mod.redactDiagnosticValue(allocator, message);
    errdefer allocator.free(redacted_message);
    const redacted_path = try resources_mod.redactDiagnosticValue(allocator, path);
    errdefer allocator.free(redacted_path);
    return .{
        .kind = try allocator.dupe(u8, kind),
        .message = redacted_message,
        .path = redacted_path,
    };
}

fn runtimeContractCategory(_: anyerror) []const u8 {
    return "runtime_contract_failed";
}

fn deinitResourceDiagnosticsList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(resources_mod.Diagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
    diagnostics.deinit(allocator);
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

const ProcessAgentToolContext = struct {
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

pub fn attachWorkflowDispatchAdapters(
    allocator: std.mem.Allocator,
    tools: []agent.AgentTool,
    adapters: []const RuntimeAdapter,
) !void {
    for (tools) |tool| {
        if (tool.source != .extension) continue;
        if (tool.execute == null or tool.execute.? != processAgentToolExecute) continue;
        const context: *ProcessAgentToolContext = @ptrCast(@alignCast(tool.execute_context orelse continue));
        if (context.workflow_id == null) continue;
        if (context.dispatch_adapters.len > 0) allocator.free(context.dispatch_adapters);
        context.dispatch_adapters = try allocator.dupe(RuntimeAdapter, adapters);
    }
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
    return try processToolValidationErrorResultWithContext(
        allocator,
        context,
        tool_call_id,
        params,
        failure,
    );
}

fn deinitProcessAgentToolContext(allocator: std.mem.Allocator, tool_context: ?*anyopaque) void {
    const context: *ProcessAgentToolContext = @ptrCast(@alignCast(tool_context orelse return));
    context.deinit(allocator);
}

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
        return try processWorkflowToolExecute(allocator, context, tool_call_id, params, signal);
    }
    validateProcessToolArguments(context.host, context.tool_name, params) catch |err| {
        return processToolErrorResultWithContext(allocator, context, tool_call_id, params, @errorName(err), @errorName(err));
    };
    const response = context.host.executeTool(
        allocator,
        context.tool_name,
        tool_call_id,
        params,
        30_000,
    ) catch |err| {
        return processToolErrorResultWithContext(allocator, context, tool_call_id, params, @errorName(err), @errorName(err));
    };
    defer {
        var owned_response = response;
        owned_response.deinit(allocator);
    }
    return .{
        .content = try cloneAgentContentBlocks(allocator, response.content),
        .details = try processToolResultDetails(
            allocator,
            context,
            tool_call_id,
            params,
            response.details,
        ),
        .is_error = response.is_error,
    };
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
            try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, content[0].text.text) });
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

fn processWorkflowToolExecute(
    allocator: std.mem.Allocator,
    context: *ProcessAgentToolContext,
    tool_call_id: []const u8,
    params: std.json.Value,
    signal: ?*const std.atomic.Value(bool),
) !agent.AgentToolResult {
    const self_adapter = RuntimeAdapter{
        .ptr = @ptrCast(context.host),
        .vtable = &process_jsonl_vtable,
        .kind = .process_jsonl,
    };
    var dispatch_context = WorkflowCapabilityDispatchContext{
        .adapters = if (context.dispatch_adapters.len > 0) context.dispatch_adapters else @as([]const RuntimeAdapter, &.{self_adapter}),
    };
    var fallback_dispatch_context = SingleRuntimeWorkflowCapabilityDispatchContext{
        .adapter = .{
            .ptr = @ptrCast(context.host),
            .vtable = &process_jsonl_vtable,
            .kind = .process_jsonl,
        },
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

    try details.object.put(allocator, try allocator.dupe(u8, "code"), .{ .string = try allocator.dupe(u8, "workflow.execution") });
    try details.object.put(allocator, try allocator.dupe(u8, "state"), .{ .string = try allocator.dupe(u8, result.state.jsonName()) });
    try details.object.put(allocator, try allocator.dupe(u8, "extension"), try processToolExtensionDetails(allocator, context));
    try details.object.put(allocator, try allocator.dupe(u8, "toolName"), .{ .string = try allocator.dupe(u8, context.tool_name) });
    try details.object.put(allocator, try allocator.dupe(u8, "toolCallId"), .{ .string = try allocator.dupe(u8, tool_call_id) });
    try details.object.put(allocator, try allocator.dupe(u8, "input"), try tools_common.cloneJsonValue(allocator, params));
    try details.object.put(allocator, try allocator.dupe(u8, "workflow"), try workflowMetadataJson(allocator, result));
    try details.object.put(allocator, try allocator.dupe(u8, "diagnostics"), try workflowDiagnosticsJson(allocator, result.diagnostics.items));
    return details;
}

pub fn workflowExecutionResultDataJson(allocator: std.mem.Allocator, result: workflow_execution.ExecutionResult) ![]u8 {
    var data = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    errdefer tools_common.deinitJsonValue(allocator, data);

    try data.object.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, "workflow") });
    try data.object.put(allocator, try allocator.dupe(u8, "state"), .{ .string = try allocator.dupe(u8, result.state.jsonName()) });
    if (result.output) |output| {
        try data.object.put(allocator, try allocator.dupe(u8, "output"), try tools_common.cloneJsonValue(allocator, output));
    } else {
        try data.object.put(allocator, try allocator.dupe(u8, "output"), .null);
    }
    try data.object.put(allocator, try allocator.dupe(u8, "workflow"), try workflowMetadataJson(allocator, result));
    try data.object.put(allocator, try allocator.dupe(u8, "diagnostics"), try workflowDiagnosticsJson(allocator, result.diagnostics.items));

    const json = try std.json.Stringify.valueAlloc(allocator, data, .{});
    tools_common.deinitJsonValue(allocator, data);
    return json;
}

fn workflowMetadataJson(allocator: std.mem.Allocator, result: workflow_execution.ExecutionResult) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = object });
    try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, result.replay_metadata.workflow_id) });
    try object.put(allocator, try allocator.dupe(u8, "terminalState"), .{ .string = try allocator.dupe(u8, result.replay_metadata.terminal_state.jsonName()) });
    try object.put(allocator, try allocator.dupe(u8, "cancellationPoint"), optionalStringValue(allocator, result.replay_metadata.cancellation_point));
    try object.put(allocator, try allocator.dupe(u8, "permissions"), try tools_common.cloneJsonValue(allocator, result.replay_metadata.permissions));
    try object.put(allocator, try allocator.dupe(u8, "childAgentLimits"), try workflowChildAgentLimitsJson(allocator, result.replay_metadata.child_agent_limits));

    var steps = std.json.Array.init(allocator);
    for (result.replay_metadata.steps.items) |step| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "stepId"), .{ .string = try allocator.dupe(u8, step.step_id) });
        try entry.put(allocator, try allocator.dupe(u8, "order"), .{ .integer = @intCast(step.order) });
        try entry.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, step.kind) });
        try entry.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, step.mode) });
        try entry.put(allocator, try allocator.dupe(u8, "state"), .{ .string = try allocator.dupe(u8, step.state) });
        try entry.put(allocator, try allocator.dupe(u8, "input"), try tools_common.cloneJsonValue(allocator, step.input));
        try entry.put(allocator, try allocator.dupe(u8, "sideEffect"), .{ .bool = step.side_effect });
        try entry.put(allocator, try allocator.dupe(u8, "selectedCapability"), optionalStringValue(allocator, step.selected_capability));
        try steps.append(.{ .object = entry });
    }
    try object.put(allocator, try allocator.dupe(u8, "steps"), .{ .array = steps });

    var usage = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try usage.put(allocator, try allocator.dupe(u8, "childrenStarted"), .{ .integer = @intCast(result.child_usage.children_started) });
    try usage.put(allocator, try allocator.dupe(u8, "turns"), .{ .integer = @intCast(result.child_usage.turns) });
    try usage.put(allocator, try allocator.dupe(u8, "toolCalls"), .{ .integer = @intCast(result.child_usage.tool_calls) });
    try usage.put(allocator, try allocator.dupe(u8, "tokens"), .{ .integer = @intCast(result.child_usage.tokens) });
    try usage.put(allocator, try allocator.dupe(u8, "elapsedMs"), .{ .integer = @intCast(result.child_usage.elapsed_ms) });
    try object.put(allocator, try allocator.dupe(u8, "childUsage"), .{ .object = usage });
    return .{ .object = object };
}

fn workflowChildAgentLimitsJson(allocator: std.mem.Allocator, limits: workflow_execution.ChildAgentLimits) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = object });
    try object.put(allocator, try allocator.dupe(u8, "maxChildren"), optionalIntegerValue(limits.max_children));
    try object.put(allocator, try allocator.dupe(u8, "maxTurns"), optionalIntegerValue(limits.max_turns));
    try object.put(allocator, try allocator.dupe(u8, "maxToolCalls"), optionalIntegerValue(limits.max_tool_calls));
    try object.put(allocator, try allocator.dupe(u8, "maxTokens"), optionalIntegerValue(limits.max_tokens));
    try object.put(allocator, try allocator.dupe(u8, "timeoutMs"), optionalIntegerValue(limits.timeout_ms));
    if (limits.permission_grants_json) |permissions| {
        try object.put(allocator, try allocator.dupe(u8, "permissionGrants"), try tools_common.cloneJsonValue(allocator, permissions));
    } else if (limits.workflow_permissions_json) |permissions| {
        try object.put(allocator, try allocator.dupe(u8, "permissionGrants"), try tools_common.cloneJsonValue(allocator, permissions));
    } else {
        var grants = std.json.Array.init(allocator);
        for (limits.permission_grants) |grant| {
            try grants.append(.{ .string = try allocator.dupe(u8, grant) });
        }
        try object.put(allocator, try allocator.dupe(u8, "permissionGrants"), .{ .array = grants });
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
        try entry.put(allocator, try allocator.dupe(u8, "code"), .{ .string = try allocator.dupe(u8, diagnostic.code) });
        try entry.put(allocator, try allocator.dupe(u8, "workflowId"), .{ .string = try allocator.dupe(u8, diagnostic.workflow_id) });
        try entry.put(allocator, try allocator.dupe(u8, "stepId"), optionalStringValue(allocator, diagnostic.step_id));
        try entry.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, diagnostic.path) });
        try entry.put(allocator, try allocator.dupe(u8, "message"), .{ .string = try allocator.dupe(u8, diagnostic.message) });
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

fn processToolResultDetails(
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

fn validateProcessToolArguments(host: *extension_host.HostProcess, tool_name: []const u8, params: std.json.Value) anyerror!void {
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

fn processToolErrorResult(allocator: std.mem.Allocator, message: []const u8) !agent.AgentToolResult {
    return .{
        .content = try tools_common.makeTextContent(allocator, message),
        .is_error = true,
    };
}

fn processToolErrorResultWithContext(
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

fn processToolValidationErrorResultWithContext(
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

fn cloneEnforcementResourceLimits(
    allocator: std.mem.Allocator,
    limits: enforcement.ResourceLimits,
) !enforcement.ResourceLimits {
    const tool_scopes = try cloneConstStringList(allocator, limits.tool_scopes);
    errdefer freeConstStringList(allocator, tool_scopes);
    return .{
        .max_children = limits.max_children,
        .depth = limits.depth,
        .turns = limits.turns,
        .timeout_ms = limits.timeout_ms,
        .output_bytes = limits.output_bytes,
        .output_lines = limits.output_lines,
        .tool_scopes = tool_scopes,
    };
}

fn deinitEnforcementResourceLimits(allocator: std.mem.Allocator, limits: *enforcement.ResourceLimits) void {
    freeConstStringList(allocator, limits.tool_scopes);
    limits.* = .{};
}

fn cloneConstStringList(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        errdefer allocator.free(cloned[index]);
    }
    return cloned;
}

fn freeConstStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

const WasmRuntime = struct {
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

const wasm_vtable: RuntimeAdapter.VTable = .{
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

fn nativeHasRegisteredHook(ptr: *anyopaque, event_name: []const u8) bool {
    return nativeRuntime(ptr).hasRegisteredHook(event_name);
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

fn nativeInvokeExtensionEvent(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    event_name: []const u8,
    event: std.json.Value,
    timeout_ms: u64,
) !?std.json.Value {
    return try nativeRuntime(ptr).invokeExtensionEvent(allocator, event_name, event, timeout_ms);
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
    .has_registered_hook = nativeHasRegisteredHook,
    .snapshot_registry_json = nativeSnapshotRegistryJson,
    .with_registry = nativeWithRegistry,
    .apply_cli_flag_values = nativeApplyCliFlagValues,
    .agent_tool = nativeAgentTool,
    .take_ui_requests = nativeTakeUiRequests,
    .send_extension_ui_response = nativeSendExtensionUiResponse,
    .send_extension_event_frame = nativeSendExtensionEventFrame,
    .invoke_extension_event = nativeInvokeExtensionEvent,
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
        try std.testing.expectError(error.UnsupportedRuntime, startRuntimeAdapter(allocator, std.testing.io, options));
    }
    try std.testing.expectEqualStrings("process_jsonl", RuntimeKind.process_jsonl.jsonName());
    try std.testing.expectEqualStrings("wasm", RuntimeKind.wasm.jsonName());
    try std.testing.expectEqualStrings("native", RuntimeKind.native.jsonName());
    try std.testing.expectEqualStrings("remote", RuntimeKind.remote.jsonName());
}

test "normal runtime setup entrypoint returns terminal event for setup outcomes" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const base_handoff = WasmManifestHandoff.fromManifest(&manifest_result.valid);
    const requested = [_]wasm_manifest.Capability{.file_read};
    var denied_handoff = base_handoff;
    denied_handoff.requested_capabilities = requested[0..];
    var wasm_stream = try startRuntime(allocator, std.testing.io, .{ .wasm = .{ .manifest = denied_handoff } });
    const wasm_event = wasm_stream.next().?;
    try std.testing.expect(wasm_event == .error_event);
    try std.testing.expectEqual(RuntimeKind.wasm, wasm_event.error_event.runtime_kind);
    try std.testing.expectEqualStrings("com.pi.pure-truncate-head", wasm_event.error_event.extension_id);
    try std.testing.expectEqualStrings("UnsupportedRuntimeCapability", wasm_event.error_event.error_name);
    try std.testing.expectEqualStrings("error_reason", wasm_event.error_event.stop_reason);
    try std.testing.expect(wasm_stream.next() == null);

    var native_stream = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_partial_failure_descriptor,
    } });
    const native_event = native_stream.next().?;
    try std.testing.expect(native_event == .error_event);
    try std.testing.expectEqual(RuntimeKind.native, native_event.error_event.runtime_kind);
    try std.testing.expectEqualStrings("com.pi.native-partial-failure", native_event.error_event.extension_id);
    try std.testing.expectEqualStrings("NativeFixtureInjectedFailure", native_event.error_event.error_name);
    try std.testing.expectEqualStrings("error_reason", native_event.error_event.stop_reason);
    try std.testing.expect(native_stream.next() == null);

    var remote_stream = try startRuntime(allocator, std.testing.io, .{ .remote = .{ .label = "unsupported-remote" } });
    const remote_event = remote_stream.next().?;
    try std.testing.expect(remote_event == .error_event);
    try std.testing.expectEqual(RuntimeKind.remote, remote_event.error_event.runtime_kind);
    try std.testing.expectEqualStrings("unsupported-remote", remote_event.error_event.extension_id);
    try std.testing.expectEqualStrings("UnsupportedRuntime", remote_event.error_event.error_name);
    try std.testing.expect(remote_stream.next() == null);

    var success_stream = try startRuntime(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    const success_event = success_stream.next().?;
    try std.testing.expect(success_event == .ready);
    var success_adapter = success_event.ready;
    defer success_adapter.deinit();
    try std.testing.expectEqual(RuntimeKind.native, success_adapter.kind);
    try success_adapter.waitForReady(0);
    try std.testing.expect(success_stream.next() == null);
}

test "extension runtime policy lookup keys are canonical per runtime source" {
    const allocator = std.testing.allocator;
    const local_source_info = resources_mod.SourceInfo{
        .path = @constCast("/workspace/project/.pi/extensions/local.ts"),
        .source = @constCast("local"),
        .scope = .project,
        .origin = .top_level,
        .base_dir = @constCast("/workspace/project/.pi"),
    };
    const local_ts_key = try typeScriptPolicyLookupKey(allocator, .{
        .configured_path = "/workspace/project/.pi/extensions/local.ts",
        .resolved_path = "/workspace/project/.pi/extensions/local.ts",
        .source_info = local_source_info,
    });
    defer allocator.free(local_ts_key);
    try std.testing.expectEqualStrings("typescript:local:project:/workspace/project/.pi/extensions/local.ts", local_ts_key);

    const package_source_info = resources_mod.SourceInfo{
        .path = @constCast("/workspace/pkg/extensions/entry.ts"),
        .source = @constCast("/workspace/pkg"),
        .scope = .user,
        .origin = .package,
        .base_dir = @constCast("/workspace/pkg"),
    };
    const package_ts_key = try typeScriptPolicyLookupKey(allocator, .{
        .configured_path = "/workspace/pkg/extensions/entry.ts",
        .resolved_path = "/workspace/pkg/extensions/entry.ts",
        .source_info = package_source_info,
    });
    defer allocator.free(package_ts_key);
    try std.testing.expectEqualStrings("typescript:package:user:/workspace/pkg:extensions/entry.ts:/workspace/pkg/extensions/entry.ts", package_ts_key);

    const inline_source_info = resources_mod.SourceInfo{
        .path = @constCast("<inline:1>"),
        .source = @constCast("inline"),
        .scope = .temporary,
        .origin = .top_level,
    };
    const inline_ts_key = try typeScriptPolicyLookupKey(allocator, .{
        .configured_path = "<inline:1>",
        .resolved_path = "<inline:1>",
        .source_info = inline_source_info,
    });
    defer allocator.free(inline_ts_key);
    try std.testing.expectEqualStrings("typescript:inline:inline:<inline:1>", inline_ts_key);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const wasm_handoff = WasmManifestHandoff.fromManifest(&manifest_result.valid);
    const wasm_key = try wasmPolicyLookupKey(allocator, wasm_handoff);
    defer allocator.free(wasm_key);
    const expected_wasm_key = try std.fmt.allocPrint(
        allocator,
        "wasm:locked:user:pi-extension.v0:com.pi.pure-truncate-head:0.1.0:{s}:fffac4554b1c0f2e8a8f44372f0766826ba4a06d60a314b67b7e78dca95c952e:{s}:{s}",
        .{ manifest_result.valid.package_root_sha256, manifest_result.valid.manifest_path, manifest_result.valid.artifact_absolute_path },
    );
    defer allocator.free(expected_wasm_key);
    try std.testing.expectEqualStrings(expected_wasm_key, wasm_key);

    const wasm_manifest_key = try wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = manifest_result.valid.schema_version,
        .id = manifest_result.valid.id,
        .version = manifest_result.valid.version,
        .package_root = manifest_result.valid.package_root,
        .manifest_path = manifest_result.valid.manifest_path,
        .artifact_path = manifest_result.valid.artifact_path,
    });
    defer allocator.free(wasm_manifest_key);
    const expected_wasm_manifest_key = try std.fmt.allocPrint(
        allocator,
        "wasm:manifest:pi-extension.v0:com.pi.pure-truncate-head:0.1.0:{s}:{s}:wasm/plugin.wasm",
        .{ manifest_result.valid.package_root, manifest_result.valid.manifest_path },
    );
    defer allocator.free(expected_wasm_manifest_key);
    try std.testing.expectEqualStrings(expected_wasm_manifest_key, wasm_manifest_key);

    const native_key = try nativePolicyLookupKey(allocator, native_static_descriptor);
    defer allocator.free(native_key);
    try std.testing.expectEqualStrings("native:com.pi.native-static-fixture:0.1.0:Native Static Fixture", native_key);

    const process_a = try processJsonlPolicyLookupKey(allocator, .{
        .argv = &.{ "/bin/pi-extension-host", "--runtime", "process_jsonl", "/workspace/ext-a" },
        .cwd = "/workspace",
        .extension_path = "/workspace/ext-a",
        .initialize = .{ .marker = "marker", .cwd = "/workspace", .fixture = "same-protocol" },
    });
    defer allocator.free(process_a);
    const process_b = try processJsonlPolicyLookupKey(allocator, .{
        .argv = &.{ "/bin/pi-extension-host", "--runtime", "process_jsonl", "/workspace/ext-b" },
        .cwd = "/workspace",
        .extension_path = "/workspace/ext-b",
        .initialize = .{ .marker = "marker", .cwd = "/workspace", .fixture = "same-protocol" },
    });
    defer allocator.free(process_b);
    try std.testing.expect(!std.mem.eql(u8, process_a, process_b));
    try std.testing.expectEqualStrings(
        "process_jsonl:{\"argv\":[\"/bin/pi-extension-host\",\"--runtime\",\"process_jsonl\",\"/workspace/ext-a\"],\"extensionPath\":\"/workspace/ext-a\",\"cwd\":\"/workspace\"}",
        process_a,
    );
}

test "extension runtime factory constructs wasm adapter and keeps native remote unsupported" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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

    try std.testing.expectError(error.UnsupportedRuntime, startRuntimeAdapter(allocator, std.testing.io, .{ .remote = .{} }));
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

fn nativePersistedPolicyLimitStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_static_tool);
    try api.spawnAgent("{\"task\":\"first\"}");
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.spawnAgent("{\"task\":\"second\"}"));
}

const native_persisted_policy_limit_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-persisted-policy-limit",
    .name = "Native Persisted Policy Limit",
    .version = "0.1.0",
    .description = "Native fixture whose effective limits come from extension policy.",
    .tools = &.{native_static_tool},
    .requested_capabilities = &.{.agent_spawn},
    .start = nativePersistedPolicyLimitStart,
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

fn nativeFixtureEchoExecute(ctx: *sdk.ToolContext) !agent.AgentToolResult {
    const allocator = ctx.allocator;
    const params = ctx.params;
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
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    try std.testing.expectError(error.UnsupportedRuntime, startRuntimeAdapter(allocator, std.testing.io, .{ .remote = .{} }));
}

test "native descriptor template executes pure tool and recovers after invalid input" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
        try std.testing.expectError(error.InvalidRuntimeOptions, startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
            .descriptor = &descriptor,
        } }));
    }

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const resource_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    try std.testing.expectError(error.UnsupportedRuntimeCapability, startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &capability_descriptor,
    } }));

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_static_descriptor,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(0);
    try adapter.withRegistry(null, expectNativeStaticRegistry);
}

test "persisted native extension policy resource limits drive enforcement diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");

    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const native_key = try nativePolicyLookupKey(allocator, native_persisted_policy_limit_descriptor);
    defer allocator.free(native_key);
    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{"extensionPolicies":{{"{s}":{{"approvedGrants":["agent.spawn"],"resourceLimits":{{"maxChildren":1}}}}}}}}
    , .{native_key});
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer @import("ai").model_registry.resetForTesting();

    const policy = runtime_config.getExtensionPolicy(native_key).?;
    const approved = try approvedCapabilitiesFromExtensionPolicy(allocator, policy);
    defer allocator.free(approved);
    const effective_limits = nativeResourceLimitsFromExtensionPolicy(policy.resource_limits, native_persisted_policy_limit_descriptor.resource_limits);
    var effects = native_runtime.NativeHostEffects{};
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_persisted_policy_limit_descriptor,
        .approved_capabilities = approved,
        .resource_limits = effective_limits,
        .policy_lookup_key = native_key,
        .host_effects = &effects,
    } });
    defer adapter.deinit();

    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(u64, 1), effects.agent_spawns);
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCount());
    const diagnostic = nativeRuntime(adapter.ptr).state.diagnostics.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"operation\":\"agent.spawn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"category\":\"resource_limit_exceeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"reason\":\"resource limit exceeded: maxChildren\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"limit\":{\"name\":\"maxChildren\",\"configuredValue\":1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"target\":{\"id\":\"[redacted]\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"policyLookupKey\":\"native:com.pi.native-persisted-policy-limit:0.1.0:Native Persisted Policy Limit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"source\":{\"runtimeKind\":\"native\"") != null);
}

test "native runtime preserves ready boundary duplicate readiness and deterministic snapshots" {
    const allocator = std.testing.allocator;
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
        try std.testing.expectError(error.ForbiddenNativeDescriptorField, startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
            .descriptor = &descriptor,
        } }));
    }
}

test "native runtime partial setup failure cleans registry tool and UI state" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NativeFixtureInjectedFailure, startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_partial_failure_descriptor,
    } }));

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const first = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_instance_isolation_descriptor,
    } });
    defer first.deinit();
    const second = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = options });
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
        try std.testing.expectError(error.UnsupportedRuntimeCapability, startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
            .manifest = handoff,
        } }));
    }
}

test "wasm runtime handoff exact approved grants permit matching requested capabilities" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const requested = [_]wasm_manifest.Capability{.file_read};
    const approved = [_]wasm_manifest.Capability{.file_read};
    var handoff = WasmManifestHandoff.fromManifest(&manifest_result.valid);
    handoff.requested_capabilities = requested[0..];
    handoff.approved_capabilities = approved[0..];

    try std.testing.expect(handoff.deniedRuntimeCapability(.initialize, "runtime/handoff") == null);
    try handoff.validate();

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = handoff,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
}

test "persisted wasm extension policy resource limits reach tool enforcement diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");

    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_key = try wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(wasm_key);
    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{"extensionPolicies":{{"{s}":{{"resourceLimits":{{"toolScopes":["policy.allowed.tool"]}}}}}}}}
    , .{wasm_key});
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer @import("ai").model_registry.resetForTesting();

    const policy = runtime_config.getExtensionPolicy(wasm_key).?;
    var handoff = WasmManifestHandoff.fromManifest(&manifest_result.valid);
    handoff.resource_limits = enforcementResourceLimitsFromExtensionPolicy(policy.resource_limits);
    handoff.policy_lookup_key = wasm_key;
    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{ .manifest = handoff } });
    defer adapter.deinit();
    try adapter.waitForReady(0);

    var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\",\"maxLines\":1,\"maxBytes\":1024}", .{});
    defer params.deinit();
    try std.testing.expectError(
        error.UnsupportedRuntimeCapability,
        agent_tool.execute.?(allocator, "wasm-policy-tool-scope", params.value, agent_tool.execute_context, null, null, null),
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCount());
    const diagnostic = wasmRuntime(adapter.ptr).state.diagnostics.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"operation\":\"tool.use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"category\":\"resource_limit_exceeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"reason\":\"tool target is outside toolScopes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"policyLookupKey\":\"wasm:locked:user:pi-extension.v0:com.pi.pure-truncate-head:0.1.0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"source\":{\"manifestPath\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"toolId\":\"builtin.truncateHead\"") != null);
}

test "locked wasm packages resolve to policy gated runtime set and unload cleanly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/pkg/wasm");

    const fixture_manifest = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json", allocator, .limited(1024 * 1024));
    defer allocator.free(fixture_manifest);
    const fixture_wasm = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm", allocator, .limited(1024 * 1024));
    defer allocator.free(fixture_wasm);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/pkg/pi-extension.json", .data = fixture_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/pkg/wasm/plugin.wasm", .data = fixture_wasm });

    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const package_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/pkg");
    defer allocator.free(package_root);

    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    var lock_entry = try @import("../packages/provenance_lockfile.zig").createWasmLockEntry(allocator, .user, manifest_result.valid.package_root, &manifest_result.valid);
    defer lock_entry.deinit(allocator);
    const lock_path = try @import("../packages/provenance_lockfile.zig").lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    try @import("../packages/provenance_lockfile.zig").writeEntry(allocator, std.testing.io, .user, lock_path, lock_entry);

    const policy_key = try wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(policy_key);
    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{"packages":["{s}"],"extensionPolicies":{{"{s}":{{"resourceLimits":{{"toolScopes":["builtin.truncateHead"]}}}}}}}}
    , .{ package_root, policy_key });
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer @import("ai").model_registry.resetForTesting();

    var runtime_set = try startLockedWasmPackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = resources_mod.SettingsResources{ .packages = runtime_config.global_settings.packages },
        .project = resources_mod.SettingsResources{ .packages = runtime_config.project_settings.packages },
    });
    defer runtime_set.deinit();

    try std.testing.expectEqual(@as(usize, 1), runtime_set.entries.len);
    try std.testing.expectEqual(@as(usize, 0), runtime_set.diagnostics.len);
    var agent_tool = (try runtime_set.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\\nbravo\\ncharlie\",\"maxLines\":2,\"maxBytes\":1024}", .{});
    defer success_params.deinit();
    const success = try agent_tool.execute.?(allocator, "locked-package-success", success_params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    defer if (success.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expect(std.mem.indexOf(u8, success.content[0].text.text, "\"content\":\"alpha\\nbravo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wasmRuntime(runtime_set.entries[0].adapter.ptr).manifest.policy_lookup_key.?, manifest_result.valid.artifact_sha256) != null);

    try std.testing.expect(try runtime_set.unloadPackage(package_root));
    try std.testing.expectEqual(@as(usize, 0), runtime_set.entries.len);
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try runtime_set.agentTool(allocator, "builtin.truncateHead"));
    try std.testing.expectError(
        error.WasmToolNotRegistered,
        agent_tool.execute.?(allocator, "locked-package-stale-after-unload", success_params.value, agent_tool.execute_context, null, null, null),
    );
}

test "locked wasm runtime set omits missing policy, capability-denied, and abi invalid packages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/no-policy/wasm");
    try tmp.dir.createDirPath(std.testing.io, "project/capability-denied/wasm");
    try tmp.dir.createDirPath(std.testing.io, "project/invalid-abi-token=pi-secret/wasm");

    const manifest_template =
        \\{{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "{s}",
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "description": "Runtime omission fixture.",
        \\  "artifact": {{ "kind": "wasm-component", "path": "wasm/plugin.wasm" }},
        \\  "tool": {{
        \\    "id": "{s}",
        \\    "description": "Runtime omission tool.",
        \\    "inputSchema": {{}},
        \\    "outputSchema": {{}}
        \\  }},
        \\  "capabilities": [{s}]
        \\}}
    ;
    const no_policy_manifest = try std.fmt.allocPrint(allocator, manifest_template, .{ "com.example.no-policy", "No Policy", "example.noPolicy", "" });
    defer allocator.free(no_policy_manifest);
    const capability_denied_manifest = try std.fmt.allocPrint(allocator, manifest_template, .{ "com.example.capability-denied", "Capability Denied", "example.capabilityDenied", "\"file.read\"" });
    defer allocator.free(capability_denied_manifest);
    const invalid_abi_manifest = try std.fmt.allocPrint(allocator, manifest_template, .{ "com.example.invalid-abi", "Invalid ABI", "example.invalidAbi", "" });
    defer allocator.free(invalid_abi_manifest);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/no-policy/pi-extension.json", .data = no_policy_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/no-policy/wasm/plugin.wasm", .data = "\x00asm" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/capability-denied/pi-extension.json", .data = capability_denied_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/capability-denied/wasm/plugin.wasm", .data = "\x00asm" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/invalid-abi-token=pi-secret/pi-extension.json", .data = invalid_abi_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/invalid-abi-token=pi-secret/wasm/plugin.wasm", .data = "\x00asm" });

    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const no_policy_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/no-policy");
    defer allocator.free(no_policy_root);
    const capability_denied_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/capability-denied");
    defer allocator.free(capability_denied_root);
    const invalid_abi_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/invalid-abi-token=pi-secret");
    defer allocator.free(invalid_abi_root);

    const provenance_lockfile = @import("../packages/provenance_lockfile.zig");
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);

    var no_policy_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, no_policy_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer no_policy_result.deinit(allocator);
    try std.testing.expect(no_policy_result == .valid);
    var no_policy_lock = try provenance_lockfile.createWasmLockEntry(allocator, .user, no_policy_result.valid.package_root, &no_policy_result.valid);
    defer no_policy_lock.deinit(allocator);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, no_policy_lock);

    var capability_denied_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, capability_denied_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer capability_denied_result.deinit(allocator);
    try std.testing.expect(capability_denied_result == .valid);
    var capability_denied_lock = try provenance_lockfile.createWasmLockEntry(allocator, .user, capability_denied_result.valid.package_root, &capability_denied_result.valid);
    defer capability_denied_lock.deinit(allocator);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, capability_denied_lock);

    var invalid_abi_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, invalid_abi_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer invalid_abi_result.deinit(allocator);
    try std.testing.expect(invalid_abi_result == .valid);
    var invalid_abi_lock = try provenance_lockfile.createWasmLockEntry(allocator, .user, invalid_abi_result.valid.package_root, &invalid_abi_result.valid);
    defer invalid_abi_lock.deinit(allocator);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, invalid_abi_lock);

    const capability_policy_key = try wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&capability_denied_result.valid));
    defer allocator.free(capability_policy_key);
    const invalid_policy_key = try wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&invalid_abi_result.valid));
    defer allocator.free(invalid_policy_key);
    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{"packages":["{s}","{s}","{s}"],"extensionPolicies":{{"{s}":{{"resourceLimits":{{"toolScopes":["example.capabilityDenied"]}}}},"{s}":{{"resourceLimits":{{"toolScopes":["example.invalidAbi"]}}}}}}}}
    , .{ no_policy_root, capability_denied_root, invalid_abi_root, capability_policy_key, invalid_policy_key });
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer @import("ai").model_registry.resetForTesting();

    var runtime_set = try startLockedWasmPackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = resources_mod.SettingsResources{ .packages = runtime_config.global_settings.packages },
        .project = resources_mod.SettingsResources{ .packages = runtime_config.project_settings.packages },
    });
    defer runtime_set.deinit();

    try std.testing.expectEqual(@as(usize, 0), runtime_set.entries.len);
    try std.testing.expectEqual(@as(usize, 3), runtime_set.diagnostics.len);
    var missing_policy_seen = false;
    var denied_capability_seen = false;
    var runtime_contract_seen = false;
    for (runtime_set.diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.kind, "missing_policy")) missing_policy_seen = true;
        if (std.mem.eql(u8, diagnostic.kind, "denied_capability")) {
            denied_capability_seen = true;
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "capability=file.read") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "tool=example.capabilityDenied") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "scope=user") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "requiredPolicy=") != null);
        }
        if (std.mem.eql(u8, diagnostic.kind, "runtime_contract_failed")) {
            runtime_contract_seen = true;
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "phase=load") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "tool=example.invalidAbi") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "artifactPath=") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "contract=pi-extension.v0") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "pi-secret") == null);
        }
    }
    try std.testing.expect(missing_policy_seen);
    try std.testing.expect(denied_capability_seen);
    try std.testing.expect(runtime_contract_seen);
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try runtime_set.agentTool(allocator, "example.noPolicy"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try runtime_set.agentTool(allocator, "example.capabilityDenied"));
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try runtime_set.agentTool(allocator, "example.invalidAbi"));
}

test "wasm manifest handoff owns and enforces tool scopes after source deinit" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    try std.testing.expect(manifest_result == .valid);
    allocator.free(manifest_result.valid.resource_limits.tool_scopes);
    manifest_result.valid.resource_limits.tool_scopes = try allocator.alloc([]u8, 1);
    manifest_result.valid.resource_limits.tool_scopes[0] = try allocator.dupe(u8, "policy.allowed.tool");
    try std.testing.expectEqual(@as(usize, 1), manifest_result.valid.resource_limits.tool_scopes.len);
    const source_scopes_ptr = manifest_result.valid.resource_limits.tool_scopes.ptr;
    const source_scope_ptr = manifest_result.valid.resource_limits.tool_scopes[0].ptr;

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer adapter.deinit();
    try adapter.waitForReady(0);

    const runtime = wasmRuntime(adapter.ptr);
    try std.testing.expectEqual(@as(usize, 1), runtime.manifest.resource_limits.tool_scopes.len);
    try std.testing.expect(runtime.manifest.resource_limits.tool_scopes.ptr != source_scopes_ptr);
    try std.testing.expect(runtime.manifest.resource_limits.tool_scopes[0].ptr != source_scope_ptr);
    try std.testing.expectEqualStrings("policy.allowed.tool", runtime.manifest.resource_limits.tool_scopes[0]);

    manifest_result.deinit(allocator);

    var agent_tool = (try adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"alpha\",\"maxLines\":1,\"maxBytes\":1024}", .{});
    defer params.deinit();
    try std.testing.expectError(
        error.UnsupportedRuntimeCapability,
        agent_tool.execute.?(allocator, "wasm-manifest-owned-tool-scope", params.value, agent_tool.execute_context, null, null, null),
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.diagnosticCount());
    const diagnostic = runtime.state.diagnostics.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"reason\":\"tool target is outside toolScopes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"category\":\"resource_limit_exceeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\"toolId\":\"builtin.truncateHead\"") != null);
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

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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
        const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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
    try std.testing.expectError(error.WasmManifestMetadataMismatch, startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&mismatch_manifest.valid),
    } }));

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    {
        const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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
        const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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

    try std.testing.expectError(error.WasmManifestMetadataMismatch, startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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

    const process_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "mixed-process-marker",
            .cwd = "/mixed-process-cwd",
            .fixture = "mixed-process-fixture",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
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
    const wasm_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try expectWasmToolSubsetConformance(allocator, wasm_adapter, manifest_result.valid.artifact_absolute_path);

    const native_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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
    const process_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "display-metadata-marker",
            .cwd = "/display-metadata-cwd",
            .fixture = "display-metadata",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter.registryFramesApplied() < 4 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 4), process_adapter.registryFramesApplied());
    try std.testing.expect(process_adapter.hasRegisteredCommand("process-display-command"));
    var process_display_tool = (try process_adapter.agentTool(allocator, "process-display-tool")).?;
    defer deinitAgentTool(allocator, &process_display_tool);
    try std.testing.expectEqualStrings("process-display-tool", process_display_tool.name);
    try std.testing.expect(process_display_tool.execute != null);

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
    const wasm_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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
    const native_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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

test "cross-runtime install discovery reload hook and workflow flow uses live capabilities" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const process_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/.pi/extensions/process");
    defer allocator.free(process_root);
    const wasm_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/.pi/extensions/wasm");
    defer allocator.free(wasm_root);
    const native_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/.pi/extensions/native");
    defer allocator.free(native_root);
    const workflow_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/.pi/extensions/workflow");
    defer allocator.free(workflow_root);

    const process_manifest_path = try std.fs.path.join(allocator, &.{ process_root, "pi-extension.json" });
    defer allocator.free(process_manifest_path);
    const wasm_manifest_path = try std.fs.path.join(allocator, &.{ wasm_root, "pi-extension.json" });
    defer allocator.free(wasm_manifest_path);
    const native_manifest_path = try std.fs.path.join(allocator, &.{ native_root, "pi-extension.json" });
    defer allocator.free(native_manifest_path);
    const workflow_manifest_path = try std.fs.path.join(allocator, &.{ workflow_root, "pi-extension.json" });
    defer allocator.free(workflow_manifest_path);

    const process_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"process.pkg","name":"Process Runtime Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","-u","index.py"]}},"tools":[{"name":"process.echo","description":"Process echo","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"process.input","priority":-30,"declarationOrder":0}],"capabilities":{"exports":[{"id":"process.echo","kind":"tool","version":"1.0.0"}]}}
    ;
    const wasm_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"wasm.pkg","name":"WASM Runtime Package","version":"1.0.0","runtime":{"kind":"wasm","entrypoint":{"artifactPath":"wasm/plugin.wasm"}},"dependencies":[{"id":"process.pkg","version":"^1.0.0"}],"tools":[{"name":"builtin.truncateHead","description":"WASM truncate","inputSchema":{"type":"object"}}],"hooks":[{"event":"input","hookId":"wasm.input","priority":-20,"declarationOrder":0}],"capabilities":{"exports":[{"id":"builtin.truncateHead","kind":"tool","version":"1.0.0"}]}}
    ;
    const native_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"native.pkg","name":"Native Runtime Package","version":"1.0.0","runtime":{"kind":"native","entrypoint":{"descriptor":"native_static_descriptor"}},"dependencies":[{"id":"wasm.pkg","version":"^1.0.0"}],"tools":[{"name":"native.fixture.echo","description":"Native echo","inputSchema":{"type":"object"}}],"hooks":[{"event":"input","hookId":"native.input","priority":-10,"declarationOrder":0}],"capabilities":{"exports":[{"id":"native.fixture.echo","kind":"tool","version":"1.0.0"}]}}
    ;
    const workflow_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"workflow.pkg","name":"Workflow Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","-u","workflow.py"]}},"dependencies":[{"id":"native.pkg","version":"^1.0.0"}],"capabilities":{"imports":[{"id":"process.echo","kind":"tool","version":"^1.0.0"},{"id":"builtin.truncateHead","kind":"tool","version":"^1.0.0"},{"id":"native.fixture.echo","kind":"tool","version":"^1.0.0"}]},"workflows":[{"id":"workflow.cross","description":"Cross-runtime workflow","exposure":{"tool":"workflow.cross"},"inputSchema":{"type":"object","required":["request"],"properties":{"request":{"type":"string"}},"additionalProperties":false},"outputSchema":{"type":"object","required":["ok","tool","echo"],"properties":{"ok":{"type":"boolean"},"tool":{"type":"string"},"echo":{"type":"string"}}},"steps":[{"id":"process","kind":"side_effect","replayMode":"recorded","selectedCapability":"process.echo"},{"id":"wasm","kind":"side_effect","replayMode":"recorded","selectedCapability":"builtin.truncateHead"},{"id":"native","kind":"side_effect","replayMode":"recorded","selectedCapability":"native.fixture.echo"}]}]}
    ;

    var install_set = try extension_manifest.resolveManifestSources(allocator, &.{
        .{ .package_root = process_root, .manifest_path = process_manifest_path, .manifest_text = process_manifest, .source_scope = "project-installed", .precedence_rank = 0 },
        .{ .package_root = wasm_root, .manifest_path = wasm_manifest_path, .manifest_text = wasm_manifest_text, .source_scope = "project-installed", .precedence_rank = 1 },
        .{ .package_root = native_root, .manifest_path = native_manifest_path, .manifest_text = native_manifest_text, .source_scope = "project-installed", .precedence_rank = 2 },
        .{ .package_root = workflow_root, .manifest_path = workflow_manifest_path, .manifest_text = workflow_manifest_text, .source_scope = "project-installed", .precedence_rank = 3 },
    });
    defer install_set.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), install_set.diagnostics.len);
    for (install_set.records) |record| try std.testing.expect(record.active);
    const install_order = try extension_manifest.activationOrderIndices(allocator, install_set.records);
    defer allocator.free(install_order);
    try std.testing.expectEqual(@as(usize, 4), install_order.len);
    try std.testing.expectEqualStrings("process.pkg", install_set.records[install_order[0]].manifest.id);
    try std.testing.expectEqualStrings("wasm.pkg", install_set.records[install_order[1]].manifest.id);
    try std.testing.expectEqualStrings("native.pkg", install_set.records[install_order[2]].manifest.id);
    try std.testing.expectEqualStrings("workflow.pkg", install_set.records[install_order[3]].manifest.id);

    const install_snapshot = try install_set.registrySnapshotJson(allocator);
    defer allocator.free(install_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, install_snapshot, "\"sourceScope\":\"project-installed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, install_snapshot, "\"id\":\"workflow.cross\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, install_snapshot, "\"activationOrder\":[\"process.pkg\",\"wasm.pkg\",\"native.pkg\",\"workflow.pkg\"]") != null);

    var startup_set = try extension_manifest.resolveManifestSources(allocator, &.{
        .{ .package_root = process_root, .manifest_path = process_manifest_path, .manifest_text = process_manifest, .source_scope = "project-auto", .precedence_rank = 0 },
        .{ .package_root = wasm_root, .manifest_path = wasm_manifest_path, .manifest_text = wasm_manifest_text, .source_scope = "project-auto", .precedence_rank = 1 },
        .{ .package_root = native_root, .manifest_path = native_manifest_path, .manifest_text = native_manifest_text, .source_scope = "project-auto", .precedence_rank = 2 },
        .{ .package_root = workflow_root, .manifest_path = workflow_manifest_path, .manifest_text = workflow_manifest_text, .source_scope = "project-auto", .precedence_rank = 3 },
    });
    defer startup_set.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), startup_set.diagnostics.len);
    const startup_snapshot = try startup_set.registrySnapshotJson(allocator);
    defer allocator.free(startup_snapshot);
    for ([_][]const u8{ "process.pkg", "wasm.pkg", "native.pkg", "workflow.pkg", "workflow.cross" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, install_snapshot, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, startup_snapshot, needle) != null);
    }

    var startup_snapshot_json = try std.json.parseFromSlice(std.json.Value, allocator, startup_snapshot, .{});
    defer startup_snapshot_json.deinit();
    const hook_chains = startup_snapshot_json.value.object.get("hookChains").?.array.items;
    var input_hook_count: usize = 0;
    for (hook_chains) |hook| {
        const hook_object = hook.object;
        if (!std.mem.eql(u8, hook_object.get("event").?.string, "input")) continue;
        const expected = switch (input_hook_count) {
            0 => "process.input",
            1 => "wasm.input",
            2 => "native.input",
            else => return error.UnexpectedHookOrder,
        };
        try std.testing.expectEqualStrings(expected, hook_object.get("hookId").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(input_hook_count)), hook_object.get("chainOrder").?.integer);
        input_hook_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), input_hook_count);

    const host_script =
        \\import json
        \\import sys
        \\
        \\capture = open(sys.argv[1], "w", encoding="utf-8")
        \\version = sys.argv[2]
        \\init = sys.stdin.readline()
        \\capture.write(init)
        \\capture.flush()
        \\
        \\def emit(value):
        \\    print(json.dumps(value, separators=(",", ":")), flush=True)
        \\
        \\tool_name = "process.echo" if version == "v1" else "process.echo.v2"
        \\emit({"type": "ready"})
        \\emit({"type": "register_tool", "name": tool_name, "label": "Process Echo", "description": "Process echo " + version, "parameters": {"type": "object", "required": ["value"], "properties": {"value": {"type": "string"}}, "additionalProperties": False}, "extensionPath": "fixture/process-" + version + ".ts"})
        \\if version == "v1":
        \\    emit({"type": "register_hook", "event": "input", "hookId": "process.input", "priority": -30, "declarationOrder": 0, "extensionPath": "fixture/process-v1.ts"})
        \\    emit({"type": "register_workflow", "id": "workflow.cross", "description": "Cross-runtime workflow", "toolName": "workflow.cross", "inputSchema": {"type": "object", "required": ["request"], "properties": {"request": {"type": "string"}}, "additionalProperties": False}, "outputSchema": {"type": "object", "required": ["ok", "tool", "echo"], "properties": {"ok": {"type": "boolean"}, "tool": {"type": "string"}, "echo": {"type": "string"}}}, "steps": [{"id": "process", "kind": "side_effect", "input": {"value": "alpha\nbravo\ncharlie"}, "replayMode": "recorded", "selectedCapability": "process.echo"}, {"id": "wasm", "kind": "side_effect", "input": {"content": "v1:alpha\nbravo\ncharlie", "maxLines": 2, "maxBytes": 1024}, "replayMode": "recorded", "selectedCapability": "builtin.truncateHead"}, {"id": "native", "kind": "side_effect", "input": {"value": "native-flow"}, "replayMode": "recorded", "selectedCapability": "native.fixture.echo"}], "extensionPath": "fixture/workflow.ts"})
        \\
        \\for line in sys.stdin:
        \\    capture.write(line)
        \\    capture.flush()
        \\    try:
        \\        frame = json.loads(line)
        \\    except Exception:
        \\        continue
        \\    if frame.get("type") == "shutdown":
        \\        emit({"type": "shutdown_complete"})
        \\        break
        \\    if frame.get("type") == "extension_event":
        \\        event = frame.get("event") or {}
        \\        emit({"type": "extension_event_result", "eventId": frame.get("eventId"), "result": {"runtime": "process_jsonl", "version": version, "eventType": event.get("type", "input"), "text": event.get("text", "") + "|process_jsonl"}})
        \\        continue
        \\    if frame.get("type") == "tool_call" and frame.get("toolName") == tool_name:
        \\        value = (frame.get("input") or {}).get("value", "")
        \\        emit({"type": "tool_result", "toolCallId": frame.get("toolCallId"), "content": [{"type": "text", "text": version + ":" + value}], "details": {"runtime": "process_jsonl", "capability": tool_name, "version": version}})
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "process_host.py", .data = host_script });
    const host_script_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process_host.py");
    defer allocator.free(host_script_path);
    const process_capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "realistic-process-v1.jsonl");
    defer allocator.free(process_capture_path);
    const process_argv_v1 = [_][]const u8{ "python3", "-u", host_script_path, process_capture_path, "v1" };

    const process_adapter_v1 = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv_v1,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "cross-runtime-realistic",
            .cwd = "/cross-runtime-realistic-cwd",
            .fixture = "process-v1",
        },
        .extension_path = "fixture/process-v1.ts",
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter_v1.deinit();
    try process_adapter_v1.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter_v1.registryFramesApplied() < 3 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 3), process_adapter_v1.registryFramesApplied());
    try std.testing.expect(process_adapter_v1.hasRegisteredHook("input"));

    var input_event = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"input\",\"text\":\"hello\"}", .{});
    defer input_event.deinit();
    var process_hook_result = (try process_adapter_v1.invokeExtensionEvent(allocator, "input", input_event.value, 500)).?;
    defer tools_common.deinitJsonValue(allocator, process_hook_result);
    try std.testing.expectEqualStrings("process_jsonl", process_hook_result.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("v1", process_hook_result.object.get("version").?.string);

    var process_tool = (try process_adapter_v1.agentTool(allocator, "process.echo")).?;
    defer deinitAgentTool(allocator, &process_tool);
    var process_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"alpha\\nbravo\\ncharlie\"}", .{});
    defer process_params.deinit();
    const process_result = try process_tool.execute.?(allocator, "cross-process-call", process_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, process_result.content);
    defer if (process_result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), process_result.is_error);
    try std.testing.expectEqualStrings("v1:alpha\nbravo\ncharlie", process_result.content[0].text.text);

    var wasm_runtime_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer wasm_runtime_manifest.deinit(allocator);
    try std.testing.expect(wasm_runtime_manifest == .valid);
    const wasm_hooks = [_]RuntimeHookDefinition{.{
        .event_name = "input",
        .extension_path = "fixture/wasm-hook.wasm",
        .priority = -20,
        .declaration_order = 0,
    }};
    var wasm_handoff = WasmManifestHandoff.fromManifest(&wasm_runtime_manifest.valid);
    wasm_handoff.hooks = &wasm_hooks;
    const wasm_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = wasm_handoff,
    } });
    defer wasm_adapter.deinit();
    try wasm_adapter.waitForReady(0);
    try std.testing.expect(wasm_adapter.hasRegisteredHook("input"));
    var wasm_hook_result = (try wasm_adapter.invokeExtensionEvent(allocator, "input", process_hook_result, 500)).?;
    defer tools_common.deinitJsonValue(allocator, wasm_hook_result);
    try std.testing.expectEqualStrings("wasm", wasm_hook_result.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("hello|process_jsonl|wasm", wasm_hook_result.object.get("text").?.string);
    var wasm_tool = (try wasm_adapter.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &wasm_tool);
    var wasm_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"content\":\"v1:alpha\\nbravo\\ncharlie\",\"maxLines\":2,\"maxBytes\":1024}", .{});
    defer wasm_params.deinit();
    const wasm_result = try wasm_tool.execute.?(allocator, "cross-wasm-call", wasm_params.value, wasm_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, wasm_result.content);
    try std.testing.expect(std.mem.indexOf(u8, wasm_result.content[0].text.text, "\"content\":\"v1:alpha\\nbravo\"") != null);

    const native_hooks = [_]NativeHookDefinition{.{
        .event_name = "input",
        .extension_path = "native://hook/input",
        .priority = -10,
        .declaration_order = 0,
    }};
    const native_cross_runtime_descriptor = NativeDescriptor{
        .id = "com.pi.native-static-fixture",
        .name = "Native Static Fixture",
        .version = "0.1.0",
        .description = "Statically linked native runtime fixture",
        .tools = &.{native_static_tool},
        .hooks = &native_hooks,
    };
    const native_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
        .descriptor = &native_cross_runtime_descriptor,
    } });
    defer native_adapter.deinit();
    try native_adapter.waitForReady(0);
    try std.testing.expect(native_adapter.hasRegisteredHook("input"));
    var native_hook_result = (try native_adapter.invokeExtensionEvent(allocator, "input", wasm_hook_result, 500)).?;
    defer tools_common.deinitJsonValue(allocator, native_hook_result);
    try std.testing.expectEqualStrings("native", native_hook_result.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("hello|process_jsonl|wasm|native", native_hook_result.object.get("text").?.string);
    var failing_native_hook_input = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"input\",\"text\":\"hello\",\"failRuntime\":\"native\"}", .{});
    defer failing_native_hook_input.deinit();
    const failing_native_hook = try native_adapter.invokeExtensionEvent(allocator, "input", failing_native_hook_input.value, 500);
    try std.testing.expect(failing_native_hook == null);
    try std.testing.expectEqual(@as(usize, 1), native_adapter.diagnosticCategoryCount(.host_error));
    var native_tool = (try native_adapter.agentTool(allocator, "native.fixture.echo")).?;
    defer deinitAgentTool(allocator, &native_tool);
    var native_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"native-flow\"}", .{});
    defer native_params.deinit();
    const native_result = try native_tool.execute.?(allocator, "cross-native-call", native_params.value, native_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, native_result.content);
    try std.testing.expectEqualStrings("{\"ok\":true,\"tool\":\"native.fixture.echo\",\"echo\":\"native-flow\"}", native_result.content[0].text.text);

    var workflow_input_schema = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"object\",\"required\":[\"request\"],\"properties\":{\"request\":{\"type\":\"string\"}},\"additionalProperties\":false}", .{});
    defer workflow_input_schema.deinit();
    var workflow_output_schema = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"object\",\"required\":[\"ok\",\"tool\",\"echo\"],\"properties\":{\"ok\":{\"type\":\"boolean\"},\"tool\":{\"type\":\"string\"},\"echo\":{\"type\":\"string\"}}}", .{});
    defer workflow_output_schema.deinit();
    var workflow_input = try std.json.parseFromSlice(std.json.Value, allocator, "{\"request\":\"alpha\"}", .{});
    defer workflow_input.deinit();
    const workflow_descriptor = workflow_execution.WorkflowDescriptor{
        .id = "workflow.cross",
        .extension_path = "fixture/workflow.ts",
        .input_schema = workflow_input_schema.value,
        .output_schema = workflow_output_schema.value,
        .permissions = startup_set.records[install_order[3]].manifest.permissions,
    };
    const workflow_steps = [_]workflow_execution.StepSpec{
        .{ .id = "process", .kind = .side_effect, .input = process_params.value, .replay_mode = .recorded, .selected_capability = "process.echo" },
        .{ .id = "wasm", .kind = .side_effect, .input = wasm_params.value, .replay_mode = .recorded, .selected_capability = "builtin.truncateHead" },
        .{ .id = "native", .kind = .side_effect, .input = native_params.value, .replay_mode = .recorded, .selected_capability = "native.fixture.echo" },
    };

    const WorkflowDispatchContext = struct {
        process_adapter: RuntimeAdapter,
        wasm_adapter: RuntimeAdapter,
        native_adapter: RuntimeAdapter,
        trace: std.ArrayList([]u8) = .empty,

        fn deinit(self: *@This(), dispatch_allocator: std.mem.Allocator) void {
            for (self.trace.items) |entry| dispatch_allocator.free(entry);
            self.trace.deinit(dispatch_allocator);
        }

        fn dispatch(
            dispatch_allocator: std.mem.Allocator,
            capability_id: []const u8,
            dispatch_input: std.json.Value,
            context: ?*anyopaque,
        ) !std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try self.trace.append(dispatch_allocator, try dispatch_allocator.dupe(u8, capability_id));
            const adapter = if (std.mem.eql(u8, capability_id, "process.echo"))
                self.process_adapter
            else if (std.mem.eql(u8, capability_id, "builtin.truncateHead"))
                self.wasm_adapter
            else if (std.mem.eql(u8, capability_id, "native.fixture.echo"))
                self.native_adapter
            else
                return error.UnknownWorkflowCapability;

            var tool = (try adapter.agentTool(dispatch_allocator, capability_id)) orelse return error.WorkflowCapabilityNotRegistered;
            defer deinitAgentTool(dispatch_allocator, &tool);
            const result = try tool.execute.?(dispatch_allocator, capability_id, dispatch_input, tool.execute_context, null, null, null);
            defer tools_common.deinitContentBlocks(dispatch_allocator, result.content);
            defer if (result.details) |details| tools_common.deinitJsonValue(dispatch_allocator, details);
            if (result.is_error) return error.WorkflowCapabilityExecutionFailed;
            if (result.content.len == 0 or result.content[0] != .text) return error.WorkflowCapabilityInvalidOutput;

            if (std.mem.eql(u8, capability_id, "process.echo")) {
                var object = try std.json.ObjectMap.init(dispatch_allocator, &.{}, &.{});
                errdefer tools_common.deinitJsonValue(dispatch_allocator, .{ .object = object });
                try object.put(dispatch_allocator, try dispatch_allocator.dupe(u8, "text"), .{ .string = try dispatch_allocator.dupe(u8, result.content[0].text.text) });
                return .{ .object = object };
            }
            var parsed = try std.json.parseFromSlice(std.json.Value, dispatch_allocator, result.content[0].text.text, .{});
            defer parsed.deinit();
            return try tools_common.cloneJsonValue(dispatch_allocator, parsed.value);
        }
    };
    var workflow_dispatch = WorkflowDispatchContext{
        .process_adapter = process_adapter_v1,
        .wasm_adapter = wasm_adapter,
        .native_adapter = native_adapter,
    };
    defer workflow_dispatch.deinit(allocator);
    var workflow_result = (try executeRegisteredWorkflowSurface(
        allocator,
        &processHost(process_adapter_v1.ptr).state.registry,
        .tool,
        "workflow.cross",
        workflow_input.value,
        .{
            .capability_dispatch = WorkflowDispatchContext.dispatch,
            .capability_dispatch_context = &workflow_dispatch,
        },
    )).?;
    defer workflow_result.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.completed, workflow_result.state);
    try std.testing.expectEqualStrings("native-flow", workflow_result.output.?.object.get("echo").?.string);
    try std.testing.expectEqual(@as(usize, 3), workflow_dispatch.trace.items.len);
    try std.testing.expectEqualStrings("process.echo", workflow_dispatch.trace.items[0]);
    try std.testing.expectEqualStrings("builtin.truncateHead", workflow_dispatch.trace.items[1]);
    try std.testing.expectEqualStrings("native.fixture.echo", workflow_dispatch.trace.items[2]);
    try std.testing.expectEqual(@as(usize, 3), workflow_result.replay_metadata.steps.items.len);
    try std.testing.expectEqualStrings("process.echo", workflow_result.replay_metadata.steps.items[0].selected_capability.?);
    try std.testing.expectEqualStrings("builtin.truncateHead", workflow_result.replay_metadata.steps.items[1].selected_capability.?);
    try std.testing.expectEqualStrings("native.fixture.echo", workflow_result.replay_metadata.steps.items[2].selected_capability.?);

    const process_text_json = try std.json.Stringify.valueAlloc(allocator, process_result.content[0].text.text, .{});
    defer allocator.free(process_text_json);
    const process_step_output_text = try std.fmt.allocPrint(allocator, "{{\"text\":{s}}}", .{process_text_json});
    defer allocator.free(process_step_output_text);
    var process_step_output = try std.json.parseFromSlice(std.json.Value, allocator, process_step_output_text, .{});
    defer process_step_output.deinit();
    var wasm_step_output = try std.json.parseFromSlice(std.json.Value, allocator, wasm_result.content[0].text.text, .{});
    defer wasm_step_output.deinit();
    var native_step_output = try std.json.parseFromSlice(std.json.Value, allocator, native_result.content[0].text.text, .{});
    defer native_step_output.deinit();

    const recorded_steps = [_]workflow_execution.RecordedReplayStep{
        .{ .step_id = "process", .mode = .recorded, .order = 0, .kind = .side_effect, .input = process_params.value, .selected_capability_present = true, .selected_capability = "process.echo", .output = process_step_output.value },
        .{ .step_id = "wasm", .mode = .recorded, .order = 1, .kind = .side_effect, .input = wasm_params.value, .selected_capability_present = true, .selected_capability = "builtin.truncateHead", .output = wasm_step_output.value },
        .{ .step_id = "native", .mode = .recorded, .order = 2, .kind = .side_effect, .input = native_params.value, .selected_capability_present = true, .selected_capability = "native.fixture.echo", .output = native_step_output.value },
    };
    var replay_result = try workflow_execution.executeWorkflow(allocator, workflow_descriptor, workflow_input.value, &workflow_steps, .{ .replay = true, .recorded_steps = &recorded_steps, .recorded_terminal_state = .completed });
    defer replay_result.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.completed, replay_result.state);
    try std.testing.expectEqualStrings("native-flow", replay_result.output.?.object.get("echo").?.string);

    var inflight_work = workflow_execution.ActiveRuntimeWork{};
    const cancel_steps = [_]workflow_execution.StepSpec{.{
        .id = "process-inflight",
        .kind = .side_effect,
        .runtime_work = &inflight_work,
        .cancel_after_start = true,
        .selected_capability = "process.echo",
    }};
    var cancelled_workflow = try workflow_execution.executeWorkflow(allocator, workflow_descriptor, workflow_input.value, &cancel_steps, .{});
    defer cancelled_workflow.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.cancelled, cancelled_workflow.state);
    try std.testing.expect(inflight_work.started);
    try std.testing.expect(inflight_work.cancelled);
    try std.testing.expectEqualStrings("process-inflight", cancelled_workflow.replay_metadata.cancellation_point.?);

    try process_adapter_v1.shutdown();
    try std.testing.expect(process_adapter_v1.hasShutdownComplete());
    process_adapter_v1.sendExtensionEventFrame("{\"type\":\"input\",\"text\":\"stale-after-shutdown\"}");
    const stale_result = try process_tool.execute.?(allocator, "cross-process-stale", process_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, stale_result.content);
    defer if (stale_result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), stale_result.is_error);

    const process_capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture_path, allocator, .unlimited);
    defer allocator.free(process_capture);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "cross-process-call") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "stale-after-shutdown") == null);

    const process_capture_path_v2 = try absoluteTmpPath(allocator, &tmp.sub_path, "realistic-process-v2.jsonl");
    defer allocator.free(process_capture_path_v2);
    const process_argv_v2 = [_][]const u8{ "python3", "-u", host_script_path, process_capture_path_v2, "v2" };
    const process_adapter_v2 = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv_v2,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "cross-runtime-realistic",
            .cwd = "/cross-runtime-realistic-cwd",
            .fixture = "process-v2",
        },
        .extension_path = "fixture/process-v2.ts",
        .shutdown_timeout_ms = 500,
    } });
    defer process_adapter_v2.deinit();
    try process_adapter_v2.waitForReady(500);
    var process_v2_elapsed: u64 = 0;
    while (process_adapter_v2.registryFramesApplied() < 1 and process_v2_elapsed <= 1000) : (process_v2_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try process_adapter_v2.agentTool(allocator, "process.echo"));
    var process_tool_v2 = (try process_adapter_v2.agentTool(allocator, "process.echo.v2")).?;
    defer deinitAgentTool(allocator, &process_tool_v2);
    var process_v2_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"reload\"}", .{});
    defer process_v2_params.deinit();
    const process_v2_result = try process_tool_v2.execute.?(allocator, "cross-process-v2-call", process_v2_params.value, process_tool_v2.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, process_v2_result.content);
    defer if (process_v2_result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), process_v2_result.is_error);
    try std.testing.expectEqualStrings("v2:reload", process_v2_result.content[0].text.text);

    try process_adapter_v2.shutdown();
    try wasm_adapter.shutdown();
    try native_adapter.shutdown();
    try std.testing.expect(process_adapter_v2.hasShutdownComplete());
    try std.testing.expect(wasm_adapter.hasShutdownComplete());
    try std.testing.expect(native_adapter.hasShutdownComplete());
    try std.testing.expect(!wasm_adapter.hasRegisteredHook("input"));
    try std.testing.expect(!native_adapter.hasRegisteredHook("input"));
    const stale_wasm_hook = try wasm_adapter.invokeExtensionEvent(allocator, "input", input_event.value, 500);
    try std.testing.expect(stale_wasm_hook == null);
    const stale_native_hook = try native_adapter.invokeExtensionEvent(allocator, "input", input_event.value, 500);
    try std.testing.expect(stale_native_hook == null);
    try std.testing.expect(wasm_adapter.diagnosticCategoryCount(.host_error) >= 1);
    try std.testing.expect(native_adapter.diagnosticCategoryCount(.host_error) >= 2);
}

test "process_jsonl workflow surfaces execute through workflow engine" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "workflow-surface-routing-capture.jsonl");
    defer allocator.free(capture_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"workflow.capability\",\"label\":\"Workflow Capability\",\"description\":\"Capability used by workflow surfaces\",\"parameters\":{{\"type\":\"object\",\"required\":[\"issue\"],\"properties\":{{\"issue\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"success\",\"description\":\"Success workflow\",\"inputSchema\":{{\"type\":\"object\",\"required\":[\"issue\"],\"properties\":{{\"issue\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"required\":[\"summary\"],\"properties\":{{\"summary\":{{\"type\":\"string\"}}}}}},\"toolName\":\"workflow.success\",\"commandName\":\"workflow-success\",\"presetId\":\"workflow-success-preset\",\"steps\":[{{\"id\":\"produce\",\"input\":{{\"issue\":\"from-workflow\"}},\"selectedCapability\":\"workflow.capability\"}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"timeout\",\"description\":\"Timeout workflow\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{}},\"timeoutMs\":5,\"toolName\":\"workflow.timeout\",\"steps\":[{{\"id\":\"slow\",\"elapsedMs\":10,\"runtimeWork\":true,\"output\":{{}}}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"cancel\",\"description\":\"Cancel workflow\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{}},\"toolName\":\"workflow.cancel\",\"steps\":[{{\"id\":\"active\",\"runtimeWork\":true,\"output\":{{}}}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"replay\",\"description\":\"Replay workflow\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"__workflowReplay\":{{\"type\":\"boolean\"}}}}}},\"outputSchema\":{{}},\"toolName\":\"workflow.replay\",\"steps\":[{{\"id\":\"shell\",\"kind\":\"side_effect\",\"replayMode\":\"blocked\",\"selectedCapability\":\"shell.run\"}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"child\",\"description\":\"Child workflow\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{}},\"toolName\":\"workflow.child\",\"presetId\":\"workflow-child-preset\",\"childAgentLimits\":{{\"maxChildren\":0,\"maxTurns\":1,\"maxToolCalls\":0,\"timeoutMs\":100}},\"steps\":[{{\"id\":\"delegate\",\"kind\":\"child_agent\",\"childDelta\":{{\"childrenStarted\":1}},\"selectedCapability\":\"agent.delegate\",\"output\":{{}}}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_workflow\",\"id\":\"child-granted\",\"description\":\"Child granted workflow\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{}},\"permissions\":[\"read\"],\"toolName\":\"workflow.child-granted\",\"childAgentLimits\":{{\"maxChildren\":1,\"maxTurns\":2,\"maxToolCalls\":1,\"timeoutMs\":100}},\"steps\":[{{\"id\":\"delegate\",\"kind\":\"child_agent\",\"input\":{{\"task\":\"triage\"}},\"childDelta\":{{\"childrenStarted\":1,\"turns\":1,\"toolCalls\":1,\"elapsedMs\":50,\"permission\":\"read\"}},\"selectedCapability\":\"agent.delegate\",\"output\":{{}}}}],\"extensionPath\":\"fixture/workflows.ts\"}}\\n'; " ++
            "while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"toolName\":\"workflow.capability\"'*) tool_call_id=$(printf '%s' \"$line\" | sed -n 's/.*\"toolCallId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"tool_result\",\"toolCallId\":\"%s\",\"content\":[{{\"type\":\"text\",\"text\":\"done via capability\"}}],\"details\":{{\"summary\":\"done via capability\"}}}}\\n' \"$tool_call_id\";; *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "workflow-surface-routing" };

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "workflow-routing-marker",
            .cwd = "/workflow-routing-cwd",
            .fixture = "workflow-routing",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer adapter.deinit();
    try adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while (adapter.registryFramesApplied() < 7 and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 7), adapter.registryFramesApplied());

    var success_tool = (try adapter.agentTool(allocator, "workflow.success")).?;
    defer deinitAgentTool(allocator, &success_tool);
    var success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"issue\":\"bug\"}", .{});
    defer success_params.deinit();
    const success = try success_tool.execute.?(allocator, "workflow-success-call", success_params.value, success_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, success.content);
    defer if (success.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), success.is_error);
    try std.testing.expectEqualStrings("{\"summary\":\"done via capability\"}", success.content[0].text.text);
    try std.testing.expectEqualStrings("completed", success.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("success", success.details.?.object.get("workflow").?.object.get("id").?.string);

    var surface_dispatch_context = SingleRuntimeWorkflowCapabilityDispatchContext{ .adapter = adapter };
    var command_success = (try executeRegisteredWorkflowSurface(
        allocator,
        &processHost(adapter.ptr).state.registry,
        .command,
        "workflow-success",
        success_params.value,
        .{
            .capability_dispatch = dispatchWorkflowCapabilityFromAdapter,
            .capability_dispatch_context = &surface_dispatch_context,
        },
    )).?;
    defer command_success.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.completed, command_success.state);
    try std.testing.expectEqualStrings("done via capability", command_success.output.?.object.get("summary").?.string);

    var preset_success = (try executeRegisteredWorkflowSurface(
        allocator,
        &processHost(adapter.ptr).state.registry,
        .preset,
        "workflow-success-preset",
        success_params.value,
        .{
            .capability_dispatch = dispatchWorkflowCapabilityFromAdapter,
            .capability_dispatch_context = &surface_dispatch_context,
        },
    )).?;
    defer preset_success.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.completed, preset_success.state);
    try std.testing.expectEqualStrings("done via capability", preset_success.output.?.object.get("summary").?.string);

    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer invalid_params.deinit();
    const invalid = try success_tool.execute.?(allocator, "workflow-invalid-call", invalid_params.value, success_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, invalid.content);
    defer if (invalid.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), invalid.is_error);
    try std.testing.expectEqualStrings("failed", invalid.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("workflow.input_schema_invalid", invalid.details.?.object.get("diagnostics").?.array.items[0].object.get("code").?.string);

    var empty_params = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer empty_params.deinit();
    var timeout_tool = (try adapter.agentTool(allocator, "workflow.timeout")).?;
    defer deinitAgentTool(allocator, &timeout_tool);
    const timeout = try timeout_tool.execute.?(allocator, "workflow-timeout-call", empty_params.value, timeout_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, timeout.content);
    defer if (timeout.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), timeout.is_error);
    try std.testing.expectEqualStrings("timed_out", timeout.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("workflow.timeout", timeout.details.?.object.get("diagnostics").?.array.items[0].object.get("code").?.string);

    var cancel_signal = std.atomic.Value(bool).init(true);
    var cancel_tool = (try adapter.agentTool(allocator, "workflow.cancel")).?;
    defer deinitAgentTool(allocator, &cancel_tool);
    const cancelled = try cancel_tool.execute.?(allocator, "workflow-cancel-call", empty_params.value, cancel_tool.execute_context, &cancel_signal, null, null);
    defer tools_common.deinitContentBlocks(allocator, cancelled.content);
    defer if (cancelled.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), cancelled.is_error);
    try std.testing.expectEqualStrings("cancelled", cancelled.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("active", cancelled.details.?.object.get("workflow").?.object.get("cancellationPoint").?.string);

    var replay_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"__workflowReplay\":true}", .{});
    defer replay_params.deinit();
    var replay_tool = (try adapter.agentTool(allocator, "workflow.replay")).?;
    defer deinitAgentTool(allocator, &replay_tool);
    const replay = try replay_tool.execute.?(allocator, "workflow-replay-call", replay_params.value, replay_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, replay.content);
    defer if (replay.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), replay.is_error);
    try std.testing.expectEqualStrings("replay_blocked", replay.details.?.object.get("state").?.string);
    try std.testing.expectEqualStrings("workflow.replay_side_effect_blocked", replay.details.?.object.get("diagnostics").?.array.items[0].object.get("code").?.string);

    var child_tool = (try adapter.agentTool(allocator, "workflow.child")).?;
    defer deinitAgentTool(allocator, &child_tool);
    const child = try child_tool.execute.?(allocator, "workflow-child-call", empty_params.value, child_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, child.content);
    defer if (child.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), child.is_error);
    try std.testing.expectEqualStrings("workflow.child_agent_limit_exceeded", child.details.?.object.get("diagnostics").?.array.items[0].object.get("code").?.string);

    var child_granted_tool = (try adapter.agentTool(allocator, "workflow.child-granted")).?;
    defer deinitAgentTool(allocator, &child_granted_tool);
    const child_granted = try child_granted_tool.execute.?(allocator, "workflow-child-granted-call", empty_params.value, child_granted_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, child_granted.content);
    defer if (child_granted.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), child_granted.is_error);
    const child_granted_workflow = child_granted.details.?.object.get("workflow").?.object;
    try std.testing.expectEqualStrings("completed", child_granted.details.?.object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 1), child_granted_workflow.get("childUsage").?.object.get("childrenStarted").?.integer);
    try std.testing.expectEqualStrings("read", child_granted_workflow.get("permissions").?.array.items[0].string);
    try std.testing.expectEqualStrings("read", child_granted_workflow.get("childAgentLimits").?.object.get("permissionGrants").?.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 0), child_granted_workflow.get("steps").?.array.items[0].object.get("order").?.integer);
    try std.testing.expectEqualStrings("child_agent", child_granted_workflow.get("steps").?.array.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("triage", child_granted_workflow.get("steps").?.array.items[0].object.get("input").?.object.get("task").?.string);

    const PresetContext = struct {
        allocator: std.mem.Allocator,
        input: std.json.Value,
        state: ?workflow_execution.ExecutionState = null,

        fn run(context: ?*anyopaque, registry: *const Registry) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var result = (try executeRegisteredWorkflowSurface(self.allocator, registry, .preset, "workflow-child-preset", self.input, .{})).?;
            defer result.deinit(self.allocator);
            self.state = result.state;
        }
    };
    var preset_context = PresetContext{ .allocator = allocator, .input = empty_params.value };
    try adapter.withRegistry(&preset_context, PresetContext.run);
    try std.testing.expectEqual(workflow_execution.ExecutionState.failed, preset_context.state.?);

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "workflow-success-call") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "workflow.capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "workflow-workflow.capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "workflow-invalid-call") == null);
    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
}

test "registered workflow surface replay consumes recorded metadata" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_workflow", "id": "live-replay", "description": "Live replay", "inputSchema": { "type": "object", "properties": { "issue": { "type": "string" } }, "required": ["issue"], "additionalProperties": false }, "outputSchema": {}, "toolName": "workflow.live-replay", "steps": [{ "id": "first", "kind": "side_effect", "input": { "query": "current" }, "output": { "value": "current" }, "replayMode": "recorded", "selectedCapability": "provider.current" }], "extensionPath": "fixture/workflows.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try extension_registry.applyHostFrameStream(&registry, frames));

    var replay_input = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"issue":"bug","__workflowReplay":true,"__workflowReplayMetadata":{"terminalState":"completed","permissions":[],"childAgentLimits":{"maxChildren":1,"maxTurns":1,"maxToolCalls":0,"maxTokens":0,"timeoutMs":30000},"steps":[{"stepId":"first","order":0,"kind":"side_effect","mode":"recorded","input":{"query":"current"},"selectedCapability":"provider.current","output":{"value":"recorded"}}]}}
    , .{});
    defer replay_input.deinit();

    var replayed = (try executeRegisteredWorkflowSurface(allocator, &registry, .tool, "workflow.live-replay", replay_input.value, .{})).?;
    defer replayed.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.completed, replayed.state);
    try std.testing.expectEqualStrings("recorded", replayed.output.?.object.get("value").?.string);

    var mismatched_input = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"issue":"bug","__workflowReplay":true,"__workflowReplayMetadata":{"terminalState":"completed","steps":[{"stepId":"first","order":0,"kind":"side_effect","mode":"recorded","input":{"query":"original"},"selectedCapability":"provider.current","output":{"value":"recorded"}}]}}
    , .{});
    defer mismatched_input.deinit();

    var mismatch = (try executeRegisteredWorkflowSurface(allocator, &registry, .tool, "workflow.live-replay", mismatched_input.value, .{})).?;
    defer mismatch.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.replay_blocked, mismatch.state);
    try std.testing.expectEqualStrings("$.replay.steps[].input", mismatch.diagnostics.items[0].path);

    var terminal_mismatch_input = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"issue":"bug","__workflowReplay":true,"__workflowReplayMetadata":{"terminalState":"failed","steps":[{"stepId":"first","order":0,"kind":"side_effect","mode":"recorded","input":{"query":"current"},"selectedCapability":"provider.current","output":{"value":"recorded"}}]}}
    , .{});
    defer terminal_mismatch_input.deinit();

    var terminal_mismatch = (try executeRegisteredWorkflowSurface(allocator, &registry, .tool, "workflow.live-replay", terminal_mismatch_input.value, .{})).?;
    defer terminal_mismatch.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.replay_blocked, terminal_mismatch.state);
    try std.testing.expectEqualStrings("$.replay.terminalState", terminal_mismatch.diagnostics.items[0].path);

    var extra_step_input = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"issue":"bug","__workflowReplay":true,"__workflowReplayMetadata":{"terminalState":"completed","steps":[{"stepId":"first","order":0,"kind":"side_effect","mode":"recorded","input":{"query":"current"},"selectedCapability":"provider.current","output":{"value":"recorded"}},{"stepId":"removed","order":1,"kind":"side_effect","mode":"recorded","output":{"value":"stale"}}]}}
    , .{});
    defer extra_step_input.deinit();

    var extra_step = (try executeRegisteredWorkflowSurface(allocator, &registry, .tool, "workflow.live-replay", extra_step_input.value, .{})).?;
    defer extra_step.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.replay_blocked, extra_step.state);
    try std.testing.expectEqualStrings("$.replay.steps", extra_step.diagnostics.items[0].path);

    var null_capability_input = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"issue":"bug","__workflowReplay":true,"__workflowReplayMetadata":{"terminalState":"completed","steps":[{"stepId":"first","order":0,"kind":"side_effect","mode":"recorded","input":{"query":"current"},"selectedCapability":null,"output":{"value":"recorded"}}]}}
    , .{});
    defer null_capability_input.deinit();

    var null_capability = (try executeRegisteredWorkflowSurface(allocator, &registry, .tool, "workflow.live-replay", null_capability_input.value, .{})).?;
    defer null_capability.deinit(allocator);
    try std.testing.expectEqual(workflow_execution.ExecutionState.replay_blocked, null_capability.state);
    try std.testing.expectEqualStrings("$.replay.steps[].selectedCapability", null_capability.diagnostics.items[0].path);
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
    try std.testing.expectError(error.ForbiddenNativeDescriptorField, startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "validation-compat-marker",
            .cwd = "/validation-compat-cwd",
            .fixture = "validation-compat",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
    } });
    defer adapter.deinit();
    try adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while ((adapter.pendingCount() < 1 or adapter.registryFramesApplied() < 1) and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), adapter.registryFramesApplied());
    var compat_tool = (try adapter.agentTool(allocator, "compat-tool")).?;
    defer deinitAgentTool(allocator, &compat_tool);
    try std.testing.expectEqualStrings("compat-tool", compat_tool.name);
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

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "adapter-marker",
            .cwd = "/adapter-initialize-cwd",
            .fixture = "adapter-fixture",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
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

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "duplicate-registry-marker",
            .cwd = "/duplicate-registry-cwd",
            .fixture = "duplicate-registry",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const process_capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-owned-tool-capture.jsonl");
    defer allocator.free(process_capture_path);
    const process_script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"process-owned-tool\",\"label\":\"Process Tool\",\"description\":\"registered by process\",\"parameters\":{{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{{\"value\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"executionMode\":\"sequential\",\"extensionPath\":\"fixture/process-tool.ts\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in " ++
            "*'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; " ++
            "*'\"toolCallId\":\"process-success\"'*) printf '{{\"type\":\"tool_result\",\"toolCallId\":\"process-success\",\"content\":[{{\"type\":\"text\",\"text\":\"process ok\"}}],\"details\":{{\"source\":\"process\"}}}}\\n';; " ++
            "*'\"toolCallId\":\"process-fail\"'*) printf '{{\"type\":\"tool_error\",\"toolCallId\":\"process-fail\",\"message\":\"process failed\"}}\\n';; " ++
            "esac; done",
        .{process_capture_path},
    );
    defer allocator.free(process_script);
    const process_argv = [_][]const u8{ "/bin/sh", "-c", process_script, "process-jsonl-tool-contract" };
    const process_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &process_argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "process-tool-contract",
            .cwd = "/process-tool-contract-cwd",
            .fixture = "process-tool-contract",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
    } });
    defer process_adapter.deinit();
    try process_adapter.waitForReady(500);
    var process_elapsed: u64 = 0;
    while (process_adapter.registryFramesApplied() < 1 and process_elapsed <= 1000) : (process_elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), process_adapter.registryFramesApplied());
    var process_tool = (try process_adapter.agentTool(allocator, "process-owned-tool")).?;
    defer deinitAgentTool(allocator, &process_tool);
    try std.testing.expectEqualStrings("process-owned-tool", process_tool.name);
    try std.testing.expectEqualStrings("Process Tool", process_tool.label);
    try std.testing.expectEqualStrings("registered by process", process_tool.description);
    try std.testing.expect(process_tool.execute != null);
    try std.testing.expectEqualStrings("object", process_tool.parameters.object.get("type").?.string);

    var process_success_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"ok\"}", .{});
    defer process_success_params.deinit();
    const process_success = try process_tool.execute.?(allocator, "process-success", process_success_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, process_success.content);
    defer if (process_success.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), process_success.is_error);
    try std.testing.expectEqualStrings("process ok", process_success.content[0].text.text);
    try std.testing.expectEqualStrings("process", process_success.details.?.object.get("source").?.string);
    try std.testing.expectEqualStrings("process-success", process_success.details.?.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("ok", process_success.details.?.object.get("input").?.object.get("value").?.string);
    const process_success_extension = process_success.details.?.object.get("extension").?.object;
    try std.testing.expectEqualStrings("process_jsonl", process_success_extension.get("runtime").?.string);
    try std.testing.expectEqualStrings("process-owned-tool", process_success_extension.get("toolName").?.string);
    try std.testing.expectEqualStrings("fixture/process-tool.ts", process_success_extension.get("extensionPath").?.string);

    var process_fail_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"fail\"}", .{});
    defer process_fail_params.deinit();
    const process_fail = try process_tool.execute.?(allocator, "process-fail", process_fail_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, process_fail.content);
    defer if (process_fail.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), process_fail.is_error);
    try std.testing.expectEqualStrings("process failed", process_fail.content[0].text.text);
    try std.testing.expectEqualStrings("process-fail", process_fail.details.?.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("process_jsonl_tool_error", process_fail.details.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("process failed", process_fail.details.?.object.get("message").?.string);

    var process_invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":42}", .{});
    defer process_invalid_params.deinit();
    const process_invalid = try process_tool.execute.?(allocator, "process-invalid", process_invalid_params.value, process_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, process_invalid.content);
    defer if (process_invalid.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), process_invalid.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", process_invalid.content[0].text.text);

    const process_capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture_path, allocator, .unlimited);
    defer allocator.free(process_capture);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "\"toolCallId\":\"process-success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "\"toolCallId\":\"process-fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, process_capture, "process-invalid") == null);

    try process_adapter.shutdown();
    try std.testing.expect(process_adapter.hasShutdownComplete());

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const wasm_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } });
    defer wasm_adapter.deinit();
    try expectWasmToolSubsetConformance(allocator, wasm_adapter, manifest_result.valid.artifact_absolute_path);
    try wasm_adapter.shutdown();
    try std.testing.expect(wasm_adapter.hasShutdownComplete());

    const native_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
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

    const adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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
    const process_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .process_jsonl = .{
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
    const wasm_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
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

    const native_adapter = try startRuntimeAdapter(allocator, std.testing.io, .{ .native = .{
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

fn stringSliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "lifecycle support matrix documents timeouts reasons results and shutdown per runtime" {
    const matrix = lifecycleSupportMatrix();
    const canonical_event_surface = extension_events.eventSurfaceNames();
    try std.testing.expectEqual(@as(usize, 5), matrix.len);
    for (matrix) |entry| {
        try std.testing.expect(entry.event_names.len > 0);
        try std.testing.expect(stringSliceContains(entry.event_names, "session_start"));
        try std.testing.expect(stringSliceContains(entry.event_names, "session_shutdown"));
        try std.testing.expect(stringSliceContains(entry.event_names, "resources_discover"));
        try std.testing.expectEqualStrings("startup", entry.reasons[0]);
        try std.testing.expectEqualStrings("reload", entry.reasons[1]);
        try std.testing.expectEqualStrings("new", entry.reasons[2]);
        try std.testing.expectEqualStrings("resume", entry.reasons[3]);
        try std.testing.expectEqualStrings("fork", entry.reasons[4]);
        try std.testing.expect(entry.result_types.len >= 3);
        try std.testing.expect(entry.shutdown_supported);
        try std.testing.expect(entry.shutdown_exactly_once);
        try std.testing.expectEqual(default_extension_handler_timeout_ms, entry.timeout_default_ms);
        try std.testing.expectEqualStrings("lifecycle-handler-timeout-ms", entry.timeout_source);
        try std.testing.expectEqualStrings("ignored", entry.late_results);
        switch (entry.runtime) {
            .typescript, .process_jsonl, .zig => {
                try std.testing.expectEqual(canonical_event_surface.len, entry.event_names.len);
                for (canonical_event_surface, 0..) |event_name, index| {
                    try std.testing.expectEqualStrings(event_name, entry.event_names[index]);
                }
            },
            .wasm, .native => {},
        }
    }
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
