// Shared fixtures and helpers for extension_runtime_behavior_test.zig split modules.

pub const std = @import("std");
pub const agent = @import("agent");
pub const ai = @import("ai");
pub const config_mod = @import("../../config/config.zig");
pub const enforcement = @import("../enforcement.zig");
pub const extension_events = @import("../extension_events.zig");
pub const extension_manifest = @import("../extension_manifest.zig");
pub const extension_registry = @import("../extension_registry.zig");
pub const extension_runtime = @import("../extension_runtime.zig");
pub const workflow_execution = @import("../workflow_execution.zig");
pub const native_loader = @import("../native/native_loader.zig");
pub const native_manifest = @import("../native/native_manifest.zig");
pub const native_runtime = @import("../native_runtime.zig");
pub const native_sdk = @import("../native/pi_native_extension_sdk.zig");
pub const provenance_lockfile = @import("../../packages/provenance_lockfile.zig");
pub const sdk = @import("../sdk.zig");
pub const resources_mod = @import("../../resources/resources.zig");
pub const tools_common = @import("../../tools/common.zig");
pub const wasm_manifest = @import("../wasm/wasm_manifest.zig");
pub const policy_key_mod = @import("../policy_key.zig");
pub const native_adapter_bridge = @import("../native_adapter_bridge.zig");
pub const wasm_runtime_adapter = @import("../wasm_runtime_adapter.zig");
pub const process_runtime_adapter = @import("../process_runtime_adapter.zig");

pub const DiagnosticCategory = extension_runtime.DiagnosticCategory;
pub const ExtensionUiRequest = extension_runtime.ExtensionUiRequest;
pub const Registry = extension_runtime.Registry;
pub const NativeDescriptor = extension_runtime.NativeDescriptor;
pub const NativeHostApi = extension_runtime.NativeHostApi;
pub const NativeResourceLimits = extension_runtime.NativeResourceLimits;
pub const NativeHookDefinition = extension_runtime.NativeHookDefinition;
pub const NativeToolDefinition = extension_runtime.NativeToolDefinition;
pub const RuntimeKind = extension_runtime.RuntimeKind;
pub const WasmManifestHandoff = extension_runtime.WasmManifestHandoff;
pub const RuntimeHookDefinition = extension_runtime.RuntimeHookDefinition;
pub const WasmOptions = extension_runtime.WasmOptions;
pub const RuntimeOptions = extension_runtime.RuntimeOptions;
pub const RuntimeAdapter = extension_runtime.RuntimeAdapter;
pub const startRuntime = extension_runtime.startRuntime;
pub const startRuntimeAdapter = extension_runtime.startRuntimeAdapter;
pub const startLockedWasmPackageRuntimes = extension_runtime.startLockedWasmPackageRuntimes;
pub const startLockedNativePackageRuntimes = extension_runtime.startLockedNativePackageRuntimes;
pub const startLockedNativePackageRuntimesWithLoader = extension_runtime.startLockedNativePackageRuntimesWithLoader;
pub const startProcessJsonl = extension_runtime.startProcessJsonl;
pub const SingleRuntimeWorkflowCapabilityDispatchContext = extension_runtime.SingleRuntimeWorkflowCapabilityDispatchContext;
pub const dispatchWorkflowCapabilityFromAdapter = extension_runtime.dispatchWorkflowCapabilityFromAdapter;
pub const executeRegisteredWorkflowSurface = extension_runtime.executeRegisteredWorkflowSurface;
pub const lifecycleSupportMatrix = extension_runtime.lifecycleSupportMatrix;
pub const default_extension_handler_timeout_ms = extension_runtime.default_extension_handler_timeout_ms;
pub const approvedCapabilitiesFromExtensionPolicy = extension_runtime.approvedCapabilitiesFromExtensionPolicy;
pub const enforcementResourceLimitsFromExtensionPolicy = extension_runtime.enforcementResourceLimitsFromExtensionPolicy;
pub const nativeResourceLimitsFromExtensionPolicy = extension_runtime.nativeResourceLimitsFromExtensionPolicy;
pub const deinitAgentTool = extension_runtime.deinitAgentTool;

pub const nativeRuntime = native_adapter_bridge.nativeRuntime;
pub const wasmRuntime = wasm_runtime_adapter.wasmRuntime;
pub const processHost = process_runtime_adapter.processHost;

pub fn absoluteTmpPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, name });
}

pub fn nativeDynamicArtifactName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "plugin.dylib",
        .windows => "plugin.dll",
        else => "plugin.so",
    };
}

pub fn nativeDynamicHostOs() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "macos",
        .windows => "windows",
        else => "linux",
    };
}

pub fn nativeDynamicHostArch() []const u8 {
    return switch (@import("builtin").cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @tagName(@import("builtin").cpu.arch),
    };
}

pub fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub const CountingNativeLoader = struct {
    calls: usize = 0,
    opened_path: ?[]u8 = null,

    pub fn deinit(self: *CountingNativeLoader, allocator: std.mem.Allocator) void {
        if (self.opened_path) |path| allocator.free(path);
        self.* = .{};
    }
};

pub fn countingNativeLoader(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    manifest: *const native_manifest.Manifest,
    host_api: *const native_sdk.HostApiV0,
) !native_loader.LoadResult {
    _ = host_api;
    const state: *CountingNativeLoader = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    if (state.opened_path) |path| allocator.free(path);
    state.opened_path = try allocator.dupe(u8, manifest.selected_artifact_absolute_path);
    return .{ .invalid = .{
        .phase = "load",
        .code = "native_fixture_loader_failure",
        .message = "test loader rejected selected artifact",
        .artifact_path = manifest.selected_artifact_absolute_path,
        .cause = "injected",
    } };
}

pub fn writeNativeDynamicRuntimePackage(
    allocator: std.mem.Allocator,
    tmp: anytype,
    package_dir: []const u8,
    id: []const u8,
    name: []const u8,
    tool_name: []const u8,
    permissions_json: []const u8,
) ![]u8 {
    const native_dir = try std.fs.path.join(allocator, &.{ package_dir, "native" });
    defer allocator.free(native_dir);
    try tmp.dir.createDirPath(std.testing.io, native_dir);
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ package_dir, "native", nativeDynamicArtifactName() });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = "native-loader-test-bytes" });
    const manifest_path = try std.fs.path.join(allocator, &.{ package_dir, "pi-extension.json" });
    defer allocator.free(manifest_path);
    const manifest_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "{s}",
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "description": "Native loader fixture.",
        \\  "runtime": {{ "kind": "native", "entrypoint": {{ "descriptor": "native://dynamic/{s}" }} }},
        \\  "artifacts": [{{ "kind": "native-dynamic", "os": "{s}", "arch": "{s}", "path": "native/{s}" }}],
        \\  "tools": [{{ "name": "{s}", "description": "Native loader fixture.", "inputSchema": {{}}, "outputSchema": {{}} }}],
        \\  "capabilities": {{ "exports": [{{ "id": "{s}", "kind": "tool" }}], "imports": [] }},
        \\  "permissions": [{s}]
        \\}}
    , .{ id, name, id, nativeDynamicHostOs(), nativeDynamicHostArch(), nativeDynamicArtifactName(), tool_name, tool_name, permissions_json });
    defer allocator.free(manifest_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest_json });
    return absoluteTmpPath(allocator, &tmp.sub_path, package_dir);
}

pub fn writeExecutableNativeDynamicRuntimePackage(
    allocator: std.mem.Allocator,
    tmp: anytype,
    package_dir: []const u8,
    id: []const u8,
    name: []const u8,
    tool_name: []const u8,
    permissions_json: []const u8,
    output_bytes: u64,
    shutdown_status: i32,
) ![]u8 {
    const src_dir = try std.fs.path.join(allocator, &.{ package_dir, "src" });
    defer allocator.free(src_dir);
    const native_dir = try std.fs.path.join(allocator, &.{ package_dir, "native" });
    defer allocator.free(native_dir);
    try tmp.dir.createDirPath(std.testing.io, src_dir);
    try tmp.dir.createDirPath(std.testing.io, native_dir);
    const source_sub_path = try std.fs.path.join(allocator, &.{ package_dir, "src", "plugin.zig" });
    defer allocator.free(source_sub_path);
    const metadata = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":\"pi-extension.v1\",\"runtime\":\"native\",\"abi\":{{\"name\":\"pi_native_extension_abi_v0\",\"minVersion\":0,\"maxVersion\":0}},\"id\":\"{s}\",\"name\":\"{s}\",\"version\":\"0.1.0\",\"description\":\"Native runtime executable fixture.\",\"tool\":{{\"name\":\"{s}\",\"description\":\"Native executable fixture.\",\"inputSchema\":{{\"type\":\"object\"}},\"outputSchema\":{{\"type\":\"object\"}}}},\"capabilities\":{{\"exports\":[{{\"id\":\"{s}\",\"kind\":\"tool\"}}],\"imports\":[]}}}}",
        .{ id, name, tool_name, tool_name },
    );
    defer allocator.free(metadata);
    const source = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const HostApiV0 = extern struct {{
        \\    abi_version: u32,
        \\    table_bytes: usize,
        \\    allowed_capabilities_ptr: ?[*]const u8,
        \\    allowed_capabilities_len: usize,
        \\    host_context: ?*anyopaque,
        \\    reserved: ?*anyopaque,
        \\}};
        \\const abi_name = "pi_native_extension_abi_v0";
        \\const metadata = "{f}";
        \\const success = "{{\"ok\":true,\"output\":{{\"message\":\"native-ok\"}}}}";
        \\const failure = "{{\"ok\":false,\"error\":{{\"category\":\"execute_failed\",\"message\":\"native requested failure\"}}}}";
        \\var output: [512]u8 = undefined;
        \\var output_len: usize = 0;
        \\export fn pi_native_extension_abi_version() u32 {{ return 0; }}
        \\export fn pi_native_extension_abi_name_ptr() [*]const u8 {{ return abi_name.ptr; }}
        \\export fn pi_native_extension_abi_name_len() usize {{ return abi_name.len; }}
        \\export fn pi_native_extension_metadata_ptr() [*]const u8 {{ return metadata.ptr; }}
        \\export fn pi_native_extension_metadata_len() usize {{ return metadata.len; }}
        \\export fn pi_native_extension_validate() i32 {{ return 0; }}
        \\export fn pi_native_extension_init(host_api: *const HostApiV0) i32 {{
        \\    if (host_api.abi_version != 0) return 1;
        \\    if (host_api.table_bytes < @sizeOf(HostApiV0)) return 2;
        \\    const ptr = host_api.allowed_capabilities_ptr orelse return 3;
        \\    const caps = ptr[0..host_api.allowed_capabilities_len];
        \\    if (std.mem.indexOf(u8, caps, "file.read") == null) return 4;
        \\    return 0;
        \\}}
        \\export fn pi_native_extension_execute(input_ptr: [*]const u8, input_len: usize) [*]const u8 {{
        \\    const input = input_ptr[0..input_len];
        \\    const chosen = if (std.mem.indexOf(u8, input, "fail") != null) failure else success;
        \\    @memcpy(output[0..chosen.len], chosen);
        \\    output_len = chosen.len;
        \\    return &output;
        \\}}
        \\export fn pi_native_extension_execute_len() usize {{ return output_len; }}
        \\export fn pi_native_extension_free(_: [*]const u8, _: usize) void {{}}
        \\export fn pi_native_extension_shutdown() i32 {{ return {d}; }}
    , .{ std.zig.fmtString(metadata), shutdown_status });
    defer allocator.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = source_sub_path, .data = source });

    const package_root = try absoluteTmpPath(allocator, &tmp.sub_path, package_dir);
    errdefer allocator.free(package_root);
    const source_path = try std.fs.path.join(allocator, &.{ package_root, "src", "plugin.zig" });
    defer allocator.free(source_path);
    const artifact_rel = try std.fs.path.join(allocator, &.{ "native", nativeDynamicArtifactName() });
    defer allocator.free(artifact_rel);
    const artifact_path = try std.fs.path.join(allocator, &.{ package_root, artifact_rel });
    defer allocator.free(artifact_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{artifact_path});
    defer allocator.free(emit_arg);
    const build_result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build-lib", "-dynamic", "-O", "ReleaseSafe", source_path, emit_arg },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    if (exitCodeFromTerm(build_result.term) != 0) {
        std.debug.print("native executable fixture build stdout:\n{s}\nstderr:\n{s}\n", .{ build_result.stdout, build_result.stderr });
        return error.NativeExecutableFixtureBuildFailed;
    }

    const manifest_path = try std.fs.path.join(allocator, &.{ package_dir, "pi-extension.json" });
    defer allocator.free(manifest_path);
    const manifest_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "{s}",
        \\  "name": "{s}",
        \\  "version": "0.1.0",
        \\  "description": "Native runtime executable fixture.",
        \\  "runtime": {{ "kind": "native", "entrypoint": {{ "descriptor": "native://dynamic/{s}" }}, "limits": {{ "timeoutMs": 1000, "outputBytes": {d}, "toolScopes": ["{s}"] }} }},
        \\  "artifacts": [{{ "kind": "native-dynamic", "os": "{s}", "arch": "{s}", "path": "native/{s}" }}],
        \\  "tools": [{{ "name": "{s}", "description": "Native executable fixture.", "inputSchema": {{}}, "outputSchema": {{}} }}],
        \\  "capabilities": {{ "exports": [{{ "id": "{s}", "kind": "tool" }}], "imports": [] }},
        \\  "permissions": [{s}]
        \\}}
    , .{ id, name, id, output_bytes, tool_name, nativeDynamicHostOs(), nativeDynamicHostArch(), nativeDynamicArtifactName(), tool_name, tool_name, permissions_json });
    defer allocator.free(manifest_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest_json });
    return package_root;
}

pub fn nativePolicyForLockedPackage(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    scope: provenance_lockfile.Scope,
    lock_path: []const u8,
) ![]u8 {
    var manifest_result = try native_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    var lock_entry = try provenance_lockfile.createNativeLockEntry(allocator, scope, manifest_result.valid.package_root, &manifest_result.valid);
    defer lock_entry.deinit(allocator);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, scope, lock_path, lock_entry);
    return provenance_lockfile.nativePolicyLookupKeyFromLockEntry(allocator, lock_entry);
}

pub fn freeUiRequests(allocator: std.mem.Allocator, requests: []ExtensionUiRequest) void {
    for (requests) |*request| request.deinit(allocator);
    allocator.free(requests);
}

pub const RegistryExpectContext = struct {
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

pub fn expectRegistryEntriesCallback(context: ?*anyopaque, registry: *const Registry) !void {
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

pub fn expectAdapterRegistryUiEventShutdownConformance(allocator: std.mem.Allocator, adapter: RuntimeAdapter) !void {
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
pub const native_static_tool: NativeToolDefinition = .{
    .name = "native.fixture.echo",
    .label = "Native Fixture Echo",
    .description = "Echoes a string through the static native fixture.",
    .input_schema_json = "{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{\"value\":{\"type\":\"string\",\"description\":\"Value to echo\"}},\"additionalProperties\":false}",
    .output_schema_json = "{\"type\":\"object\",\"required\":[\"ok\",\"tool\",\"echo\"],\"properties\":{\"ok\":{\"type\":\"boolean\"},\"tool\":{\"type\":\"string\"},\"echo\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    .extension_path = "native://template/pure-tool-v0",
    .execute = nativeFixtureEchoExecute,
};

pub const native_static_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-static-fixture",
    .name = "Native Static Fixture",
    .version = "0.1.0",
    .description = "Statically linked native runtime fixture",
    .tools = &.{native_static_tool},
};

pub fn nativePersistedPolicyLimitStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_static_tool);
    try api.spawnAgent("{\"task\":\"first\"}");
    try std.testing.expectError(error.UnsupportedRuntimeCapability, api.spawnAgent("{\"task\":\"second\"}"));
}

pub const native_persisted_policy_limit_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-persisted-policy-limit",
    .name = "Native Persisted Policy Limit",
    .version = "0.1.0",
    .description = "Native fixture whose effective limits come from extension policy.",
    .tools = &.{native_static_tool},
    .requested_capabilities = &.{.agent_spawn},
    .start = nativePersistedPolicyLimitStart,
};

pub const native_preready_tool: NativeToolDefinition = .{
    .name = "native.fixture.preready",
    .label = "Native Preready Tool",
    .description = "Attempts to register before readiness.",
    .input_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://fixture/preready",
    .execute = nativeFixtureEchoExecute,
};

pub const native_partial_failure_tool: NativeToolDefinition = .{
    .name = "native.fixture.partial",
    .label = "Native Partial Fixture",
    .description = "Native fixture registered before injected setup failure",
    .input_schema_json = "{\"type\":\"object\"}",
    .extension_path = "native://fixture/partial-failure",
};

pub fn nativeFixtureEchoExecute(ctx: *sdk.ToolContext) !agent.AgentToolResult {
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

pub fn nativeFailAfterReadyRegistryAndUi(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_partial_failure_tool);
    try api.requestUi("native-partial-pending", "input", true, "{\"prompt\":\"partial\"}");
    return error.NativeFixtureInjectedFailure;
}

pub fn nativeReadyBoundaryStart(api: *NativeHostApi) !void {
    try api.registerTool(native_preready_tool);
    try api.ready();
    try api.ready();
    try api.registerTool(native_static_tool);
}

pub const native_ready_boundary_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-ready-boundary",
    .name = "Native Ready Boundary Fixture",
    .version = "0.1.0",
    .description = "Native fixture that attempts pre-ready and duplicate-ready registration",
    .tools = &.{ native_preready_tool, native_static_tool },
    .start = nativeReadyBoundaryStart,
};

pub const native_partial_failure_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-partial-failure",
    .name = "Native Partial Failure Fixture",
    .version = "0.1.0",
    .description = "Native fixture that fails after partial setup",
    .tools = &.{native_partial_failure_tool},
    .start = nativeFailAfterReadyRegistryAndUi,
};

pub fn nativeHostApiBoundaryStart(api: *NativeHostApi) !void {
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

pub const native_host_api_boundary_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-host-api-boundary",
    .name = "Native Host API Boundary Fixture",
    .version = "0.1.0",
    .description = "Native fixture that exercises declared host API boundaries",
    .tools = &.{native_static_tool},
    .start = nativeHostApiBoundaryStart,
};

pub fn nativeInstanceIsolationStart(api: *NativeHostApi) !void {
    try api.ready();
    try api.registerTool(native_static_tool);
    try api.requestUi("native-shared-pending", "input", true, "{\"prompt\":\"native-instance\"}");
}

pub const native_instance_isolation_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-instance-isolation",
    .name = "Native Instance Isolation Fixture",
    .version = "0.1.0",
    .description = "Native fixture used to prove same-module adapter instance isolation",
    .tools = &.{native_static_tool},
    .start = nativeInstanceIsolationStart,
};

pub fn nativeUiLifecycleStart(api: *NativeHostApi) !void {
    try api.requestUi("native-pre-ready", "input", true, "{\"title\":\"Pre-ready\"}");
    try api.ready();
    try api.requestUi("native-notify", "notify", false, "{\"message\":\"Native notice\"}");
    try api.requestUi("native-pending", "input", true, "{\"title\":\"Native input\"}");
    try api.requestUi("native-pending", "input", true, "{\"title\":\"Duplicate\"}");
    try api.registerTool(native_static_tool);
}

pub const native_ui_lifecycle_descriptor: NativeDescriptor = .{
    .id = "com.pi.native-ui-lifecycle",
    .name = "Native UI Lifecycle Fixture",
    .version = "0.1.0",
    .description = "Native fixture used to prove UI request and response lifecycle safety",
    .tools = &.{native_static_tool},
    .start = nativeUiLifecycleStart,
};

pub fn expectNativeStaticRegistry(context: ?*anyopaque, registry: *const Registry) !void {
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
pub const WasmToolRegistryExpectContext = struct {
    expected_artifact_path: []const u8,
};

pub fn expectWasmToolOnlyRegistry(context: ?*anyopaque, registry: *const Registry) !void {
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

pub fn expectWasmToolSubsetConformance(allocator: std.mem.Allocator, adapter: RuntimeAdapter, expected_artifact_path: []const u8) !void {
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
pub fn stringSliceContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
