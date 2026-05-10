const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const config_mod = @import("../config/config.zig");
const enforcement = @import("enforcement.zig");
const extension_events = @import("extension_events.zig");
const extension_manifest = @import("extension_manifest.zig");
const extension_registry = @import("extension_registry.zig");
const extension_runtime = @import("extension_runtime.zig");
const workflow_execution = @import("workflow_execution.zig");
const native_loader = @import("native/native_loader.zig");
const native_manifest = @import("native/native_manifest.zig");
const native_runtime = @import("native_runtime.zig");
const native_sdk = @import("native/pi_native_extension_sdk.zig");
const provenance_lockfile = @import("../packages/provenance_lockfile.zig");
const sdk = @import("sdk.zig");
const resources_mod = @import("../resources/resources.zig");
const tools_common = @import("../tools/common.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");
const policy_key_mod = @import("policy_key.zig");
const native_adapter_bridge = @import("native_adapter_bridge.zig");
const wasm_runtime_adapter = @import("wasm_runtime_adapter.zig");
const process_runtime_adapter = @import("process_runtime_adapter.zig");

const DiagnosticCategory = extension_runtime.DiagnosticCategory;
const ExtensionUiRequest = extension_runtime.ExtensionUiRequest;
const Registry = extension_runtime.Registry;
const NativeDescriptor = extension_runtime.NativeDescriptor;
const NativeHostApi = extension_runtime.NativeHostApi;
const NativeResourceLimits = extension_runtime.NativeResourceLimits;
const NativeHookDefinition = extension_runtime.NativeHookDefinition;
const NativeToolDefinition = extension_runtime.NativeToolDefinition;
const RuntimeKind = extension_runtime.RuntimeKind;
const WasmManifestHandoff = extension_runtime.WasmManifestHandoff;
const RuntimeHookDefinition = extension_runtime.RuntimeHookDefinition;
const WasmOptions = extension_runtime.WasmOptions;
const RuntimeOptions = extension_runtime.RuntimeOptions;
const RuntimeAdapter = extension_runtime.RuntimeAdapter;
const startRuntime = extension_runtime.startRuntime;
const startRuntimeAdapter = extension_runtime.startRuntimeAdapter;
const startLockedWasmPackageRuntimes = extension_runtime.startLockedWasmPackageRuntimes;
const startLockedNativePackageRuntimes = extension_runtime.startLockedNativePackageRuntimes;
const startLockedNativePackageRuntimesWithLoader = extension_runtime.startLockedNativePackageRuntimesWithLoader;
const startProcessJsonl = extension_runtime.startProcessJsonl;
const SingleRuntimeWorkflowCapabilityDispatchContext = extension_runtime.SingleRuntimeWorkflowCapabilityDispatchContext;
const dispatchWorkflowCapabilityFromAdapter = extension_runtime.dispatchWorkflowCapabilityFromAdapter;
const executeRegisteredWorkflowSurface = extension_runtime.executeRegisteredWorkflowSurface;
const lifecycleSupportMatrix = extension_runtime.lifecycleSupportMatrix;
const default_extension_handler_timeout_ms = extension_runtime.default_extension_handler_timeout_ms;
const approvedCapabilitiesFromExtensionPolicy = extension_runtime.approvedCapabilitiesFromExtensionPolicy;
const enforcementResourceLimitsFromExtensionPolicy = extension_runtime.enforcementResourceLimitsFromExtensionPolicy;
const nativeResourceLimitsFromExtensionPolicy = extension_runtime.nativeResourceLimitsFromExtensionPolicy;
const deinitAgentTool = extension_runtime.deinitAgentTool;

const nativeRuntime = native_adapter_bridge.nativeRuntime;
const wasmRuntime = wasm_runtime_adapter.wasmRuntime;
const processHost = process_runtime_adapter.processHost;

fn absoluteTmpPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, name });
}

fn nativeDynamicArtifactName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "plugin.dylib",
        .windows => "plugin.dll",
        else => "plugin.so",
    };
}

fn nativeDynamicHostOs() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "macos",
        .windows => "windows",
        else => "linux",
    };
}

fn nativeDynamicHostArch() []const u8 {
    return switch (@import("builtin").cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @tagName(@import("builtin").cpu.arch),
    };
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

const CountingNativeLoader = struct {
    calls: usize = 0,
    opened_path: ?[]u8 = null,

    fn deinit(self: *CountingNativeLoader, allocator: std.mem.Allocator) void {
        if (self.opened_path) |path| allocator.free(path);
        self.* = .{};
    }
};

fn countingNativeLoader(
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

fn writeNativeDynamicRuntimePackage(
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

fn writeExecutableNativeDynamicRuntimePackage(
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

fn nativePolicyForLockedPackage(
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
    const local_ts_key = try policy_key_mod.typeScriptPolicyLookupKey(allocator, .{
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
    const package_ts_key = try policy_key_mod.typeScriptPolicyLookupKey(allocator, .{
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
    const inline_ts_key = try policy_key_mod.typeScriptPolicyLookupKey(allocator, .{
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
    const wasm_key = try policy_key_mod.wasmPolicyLookupKey(allocator, wasm_handoff);
    defer allocator.free(wasm_key);
    const expected_wasm_key = try std.fmt.allocPrint(
        allocator,
        "wasm:locked:user:pi-extension.v0:com.pi.pure-truncate-head:0.1.0:{s}:fffac4554b1c0f2e8a8f44372f0766826ba4a06d60a314b67b7e78dca95c952e:{s}:{s}",
        .{ manifest_result.valid.package_root_sha256, manifest_result.valid.manifest_path, manifest_result.valid.artifact_absolute_path },
    );
    defer allocator.free(expected_wasm_key);
    try std.testing.expectEqualStrings(expected_wasm_key, wasm_key);

    const wasm_manifest_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
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

    const native_key = try policy_key_mod.nativePolicyLookupKey(allocator, native_static_descriptor);
    defer allocator.free(native_key);
    try std.testing.expectEqualStrings("native:com.pi.native-static-fixture:0.1.0:Native Static Fixture", native_key);

    const process_a = try policy_key_mod.processJsonlPolicyLookupKey(allocator, .{
        .argv = &.{ "/bin/pi-extension-host", "--runtime", "process_jsonl", "/workspace/ext-a" },
        .cwd = "/workspace",
        .extension_path = "/workspace/ext-a",
        .initialize = .{ .marker = "marker", .cwd = "/workspace", .fixture = "same-protocol" },
    });
    defer allocator.free(process_a);
    const process_b = try policy_key_mod.processJsonlPolicyLookupKey(allocator, .{
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

test "native dynamic loader requires exact policy before opening selected artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/no-policy");

    const package_root = try writeNativeDynamicRuntimePackage(allocator, tmp, "project/no-policy", "com.example.native.no-policy", "Native No Policy", "native.noPolicy", "");
    defer allocator.free(package_root);
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    const policy_key = try nativePolicyForLockedPackage(allocator, package_root, .user, lock_path);
    defer allocator.free(policy_key);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = "{\"extensionPolicies\":{}}" });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer ai.model_registry.resetForTesting();

    var package_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_root) };
    defer package_config.deinit(allocator);
    var loader_state = CountingNativeLoader{};
    defer loader_state.deinit(allocator);
    var set = try startLockedNativePackageRuntimesWithLoader(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
    }, .{
        .context = &loader_state,
        .load = countingNativeLoader,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), loader_state.calls);
    try std.testing.expectEqual(@as(usize, 0), set.entries.len);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("missing_policy", set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, policy_key) != null);
}

test "native dynamic loader opens only locked selected artifact and fails closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/locked");
    try tmp.dir.createDirPath(std.testing.io, "project/decoy/native");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/decoy/native/plugin.dylib", .data = "decoy" });

    const package_root = try writeNativeDynamicRuntimePackage(allocator, tmp, "project/locked", "com.example.native.locked", "Native Locked", "native.locked", "");
    defer allocator.free(package_root);
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    const policy_key = try nativePolicyForLockedPackage(allocator, package_root, .user, lock_path);
    defer allocator.free(policy_key);
    const settings_json = try std.fmt.allocPrint(
        allocator,
        "{{\"extensionPolicies\":{{\"{s}\":{{\"approvedGrants\":[]}}}}}}",
        .{policy_key},
    );
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer ai.model_registry.resetForTesting();

    var package_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_root) };
    defer package_config.deinit(allocator);
    var loader_state = CountingNativeLoader{};
    defer loader_state.deinit(allocator);
    var set = try startLockedNativePackageRuntimesWithLoader(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
    }, .{
        .context = &loader_state,
        .load = countingNativeLoader,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 1), loader_state.calls);
    try std.testing.expectEqual(@as(usize, 0), set.entries.len);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("native_fixture_loader_failure", set.diagnostics[0].kind);
    try std.testing.expect(loader_state.opened_path != null);
    try std.testing.expect(std.mem.indexOf(u8, loader_state.opened_path.?, package_root) != null);
    try std.testing.expect(std.mem.indexOf(u8, loader_state.opened_path.?, "project/decoy") == null);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "failed closed before tool registration") != null);
}

test "native dynamic loader denies capabilities before opening library" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/capability-denied");

    const package_root = try writeNativeDynamicRuntimePackage(allocator, tmp, "project/capability-denied", "com.example.native.capability", "Native Capability", "native.capability", "{\"id\":\"file.read\"}");
    defer allocator.free(package_root);
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    const policy_key = try nativePolicyForLockedPackage(allocator, package_root, .user, lock_path);
    defer allocator.free(policy_key);
    const settings_json = try std.fmt.allocPrint(
        allocator,
        "{{\"extensionPolicies\":{{\"{s}\":{{\"approvedGrants\":[]}}}}}}",
        .{policy_key},
    );
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer ai.model_registry.resetForTesting();

    var package_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_root) };
    defer package_config.deinit(allocator);
    var loader_state = CountingNativeLoader{};
    defer loader_state.deinit(allocator);
    var set = try startLockedNativePackageRuntimesWithLoader(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
    }, .{
        .context = &loader_state,
        .load = countingNativeLoader,
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), loader_state.calls);
    try std.testing.expectEqual(@as(usize, 0), set.entries.len);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("denied_capability", set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "before library load") != null);
}

test "locked native duplicate tool packages fail closed for duplicate entry only" {
    if (native_loader.unsupportedPlatformReasonForTesting()) |_| return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/pkg-a");
    try tmp.dir.createDirPath(std.testing.io, "project/pkg-b");

    const package_a_root = try writeExecutableNativeDynamicRuntimePackage(
        allocator,
        tmp,
        "project/pkg-a",
        "com.example.native.duplicate.a",
        "Native Duplicate A",
        "native.duplicate",
        "{\"id\":\"file.read\"}",
        4096,
        0,
    );
    defer allocator.free(package_a_root);
    const package_b_root = try writeExecutableNativeDynamicRuntimePackage(
        allocator,
        tmp,
        "project/pkg-b",
        "com.example.native.duplicate.b",
        "Native Duplicate B",
        "native.duplicate",
        "{\"id\":\"file.read\"}",
        4096,
        0,
    );
    defer allocator.free(package_b_root);
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    const policy_a_key = try nativePolicyForLockedPackage(allocator, package_a_root, .user, lock_path);
    defer allocator.free(policy_a_key);
    const policy_b_key = try nativePolicyForLockedPackage(allocator, package_b_root, .user, lock_path);
    defer allocator.free(policy_b_key);
    const settings_json = try std.fmt.allocPrint(
        allocator,
        "{{\"extensionPolicies\":{{\"{s}\":{{\"approvedGrants\":[\"file.read\"]}},\"{s}\":{{\"approvedGrants\":[\"file.read\"]}}}}}}",
        .{ policy_a_key, policy_b_key },
    );
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer ai.model_registry.resetForTesting();

    var package_a_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_a_root) };
    defer package_a_config.deinit(allocator);
    var package_b_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_b_root) };
    defer package_b_config.deinit(allocator);
    var set = try startLockedNativePackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{ package_a_config, package_b_config } },
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 1), set.entries.len);
    try std.testing.expectEqualStrings("native.duplicate", set.entries[0].tool_name);
    try std.testing.expectEqualStrings(package_a_root, set.entries[0].package_root);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("duplicate_native_tool", set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "phase=registration") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "tool=native.duplicate") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "duplicate locked native tool id") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, package_b_root) != null);
    try std.testing.expect(!try set.unloadPackage(package_b_root));

    var tool = (try set.agentTool(allocator, "native.duplicate")).?;
    defer deinitAgentTool(allocator, &tool);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"hello\"}", .{});
    defer params.deinit();
    const result = try tool.execute.?(allocator, "native-duplicate-ok", params.value, tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, result.content);
    defer if (result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), result.is_error);
    try std.testing.expectEqualStrings("{\"message\":\"native-ok\"}", result.content[0].text.text);
}

test "locked native runtime invokes through agent tool path and unload rejects stale handles" {
    if (native_loader.unsupportedPlatformReasonForTesting()) |_| return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/executable");

    const package_root = try writeExecutableNativeDynamicRuntimePackage(
        allocator,
        tmp,
        "project/executable",
        "com.example.native.executable",
        "Native Executable",
        "native.executable",
        "{\"id\":\"file.read\"}",
        4096,
        7,
    );
    defer allocator.free(package_root);
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    const policy_key = try nativePolicyForLockedPackage(allocator, package_root, .user, lock_path);
    defer allocator.free(policy_key);
    const settings_json = try std.fmt.allocPrint(
        allocator,
        "{{\"extensionPolicies\":{{\"{s}\":{{\"approvedGrants\":[\"file.read\"]}}}}}}",
        .{policy_key},
    );
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer ai.model_registry.resetForTesting();

    var package_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_root) };
    defer package_config.deinit(allocator);
    var set = try startLockedNativePackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
    });
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 1), set.entries.len);
    try std.testing.expectEqual(@as(usize, 0), set.diagnostics.len);
    var tool = (try set.agentTool(allocator, "native.executable")).?;
    defer deinitAgentTool(allocator, &tool);
    try std.testing.expectEqualStrings("native.executable", tool.name);
    try std.testing.expectEqualStrings("Native executable fixture.", tool.description);
    try std.testing.expectEqualStrings("object", tool.parameters.object.get("type").?.string);

    var params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"hello\"}", .{});
    defer params.deinit();
    const result = try tool.execute.?(allocator, "native-executable-ok", params.value, tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, result.content);
    defer if (result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), result.is_error);
    try std.testing.expectEqualStrings("{\"message\":\"native-ok\"}", result.content[0].text.text);
    try std.testing.expectEqualStrings("native", result.details.?.object.get("extensionRuntime").?.object.get("runtimeKind").?.string);
    try std.testing.expectEqualStrings(policy_key, result.details.?.object.get("extensionRuntime").?.object.get("policyLookupKey").?.string);

    var fail_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"fail\"}", .{});
    defer fail_params.deinit();
    const failed = try tool.execute.?(allocator, "native-executable-fail", fail_params.value, tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, failed.content);
    defer if (failed.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), failed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, failed.content[0].text.text, "execute_failed") != null);

    try std.testing.expect(try set.unloadPackage(package_root));
    try std.testing.expectEqual(@as(usize, 0), set.entries.len);
    try std.testing.expectEqual(@as(usize, 1), set.retired_entries.len);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("native_shutdown_failed", set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "cleanup completed") != null);
    try std.testing.expectError(error.NativeToolNotRegistered, tool.execute.?(allocator, "native-stale", params.value, tool.execute_context, null, null, null));
}

test "locked native runtime enforces execute output byte limits deterministically" {
    if (native_loader.unsupportedPlatformReasonForTesting()) |_| return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/limited");

    const package_root = try writeExecutableNativeDynamicRuntimePackage(
        allocator,
        tmp,
        "project/limited",
        "com.example.native.limited",
        "Native Limited",
        "native.limited",
        "{\"id\":\"file.read\"}",
        8,
        0,
    );
    defer allocator.free(package_root);
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    const policy_key = try nativePolicyForLockedPackage(allocator, package_root, .user, lock_path);
    defer allocator.free(policy_key);
    const settings_json = try std.fmt.allocPrint(
        allocator,
        "{{\"extensionPolicies\":{{\"{s}\":{{\"approvedGrants\":[\"file.read\"]}}}}}}",
        .{policy_key},
    );
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.pi/agent/settings.json", .data = settings_json });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime_config.deinit();
    defer ai.model_registry.resetForTesting();

    var package_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, package_root) };
    defer package_config.deinit(allocator);
    var set = try startLockedNativePackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
    });
    defer set.deinit();

    var tool = (try set.agentTool(allocator, "native.limited")).?;
    defer deinitAgentTool(allocator, &tool);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"hello\"}", .{});
    defer params.deinit();
    const result = try tool.execute.?(allocator, "native-limited", params.value, tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, result.content);
    defer if (result.details) |details| tools_common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "native_execute_output_too_large") != null);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("native_execute_output_too_large", set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, set.diagnostics[0].message, "artifactSha256=") != null);
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
    const native_key = try policy_key_mod.nativePolicyLookupKey(allocator, native_persisted_policy_limit_descriptor);
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

test "native descriptor rejects unsupported runtime and product policy fields" {
    const allocator = std.testing.allocator;
    const forbidden_descriptors = [_]NativeDescriptor{
        .{ .id = "com.pi.native-library", .name = "Library", .version = "0.1.0", .description = "forbidden", .tools = &.{native_static_tool}, .library_path = "/tmp/libnative.dylib" },
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

test "wasm manifest handoff rejects invalid runtime option fields before startup" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0");
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    const base_handoff = WasmManifestHandoff.fromManifest(&manifest_result.valid);

    var invalid_schema_version = base_handoff;
    invalid_schema_version.schema_version = "pi-extension.invalid";
    try std.testing.expectError(error.InvalidRuntimeOptions, invalid_schema_version.validate());

    var empty_id = base_handoff;
    empty_id.id = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_id.validate());

    var empty_name = base_handoff;
    empty_name.name = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_name.validate());

    var empty_version = base_handoff;
    empty_version.version = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_version.validate());

    var empty_description = base_handoff;
    empty_description.description = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_description.validate());

    var empty_artifact_path = base_handoff;
    empty_artifact_path.artifact_path = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_artifact_path.validate());

    var empty_artifact_absolute_path = base_handoff;
    empty_artifact_absolute_path.artifact_absolute_path = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_artifact_absolute_path.validate());

    var relative_artifact_absolute_path = base_handoff;
    relative_artifact_absolute_path.artifact_absolute_path = "wasm/plugin.wasm";
    try std.testing.expectError(error.InvalidRuntimeOptions, relative_artifact_absolute_path.validate());

    var empty_tool_id = base_handoff;
    empty_tool_id.tool_id = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_tool_id.validate());

    var empty_tool_description = base_handoff;
    empty_tool_description.tool_description = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_tool_description.validate());

    var empty_input_schema = base_handoff;
    empty_input_schema.input_schema_json = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_input_schema.validate());

    var empty_output_schema = base_handoff;
    empty_output_schema.output_schema_json = "";
    try std.testing.expectError(error.InvalidRuntimeOptions, empty_output_schema.validate());
}

test "wasm runtime rejects schema mismatch before registry mutation" {
    const allocator = std.testing.allocator;
    var manifest_result = try wasm_manifest.validateManifestText(allocator, "test/fixtures/wasm/pure-truncate-head-v0",
        \\{"schemaVersion":"pi-extension.v0","id":"com.pi.pure-truncate-head","name":"Pure Truncate Head Fixture","version":"0.1.0","description":"Capability-free Wasm migration fixture for the existing truncateHead pure tool implementation.","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"builtin.truncateHead","description":"Keeps the beginning of content within line and byte limits.","inputSchema":{"type":"object"},"outputSchema":{"type":"object"}},"capabilities":[]}
    );
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    try std.testing.expectError(error.WasmManifestSchemaMismatch, startRuntimeAdapter(allocator, std.testing.io, .{ .wasm = .{
        .manifest = WasmManifestHandoff.fromManifest(&manifest_result.valid),
    } }));
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
    const wasm_key = try policy_key_mod.wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&manifest_result.valid));
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

    const policy_lookup_key = try policy_key_mod.wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(policy_lookup_key);
    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{"packages":["{s}"],"extensionPolicies":{{"{s}":{{"resourceLimits":{{"toolScopes":["builtin.truncateHead"]}}}}}}}}
    , .{ package_root, policy_lookup_key });
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

    const capability_policy_key = try policy_key_mod.wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&capability_denied_result.valid));
    defer allocator.free(capability_policy_key);
    const invalid_policy_key = try policy_key_mod.wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&invalid_abi_result.valid));
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

test "locked wasm duplicate tool packages fail closed for duplicate entry only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/pkg-a/wasm");
    try tmp.dir.createDirPath(std.testing.io, "project/pkg-b/wasm");

    const fixture_manifest = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json", allocator, .limited(1024 * 1024));
    defer allocator.free(fixture_manifest);
    const fixture_wasm = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, "test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm", allocator, .limited(1024 * 1024));
    defer allocator.free(fixture_wasm);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/pkg-a/pi-extension.json", .data = fixture_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/pkg-a/wasm/plugin.wasm", .data = fixture_wasm });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/pkg-b/pi-extension.json", .data = fixture_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/pkg-b/wasm/plugin.wasm", .data = fixture_wasm });

    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const package_a_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/pkg-a");
    defer allocator.free(package_a_root);
    const package_b_root = try absoluteTmpPath(allocator, &tmp.sub_path, "project/pkg-b");
    defer allocator.free(package_b_root);

    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);

    var manifest_a_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_a_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_a_result.deinit(allocator);
    try std.testing.expect(manifest_a_result == .valid);
    var lock_a = try provenance_lockfile.createWasmLockEntry(allocator, .user, manifest_a_result.valid.package_root, &manifest_a_result.valid);
    defer lock_a.deinit(allocator);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, lock_a);

    var manifest_b_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_b_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_b_result.deinit(allocator);
    try std.testing.expect(manifest_b_result == .valid);
    var lock_b = try provenance_lockfile.createWasmLockEntry(allocator, .user, manifest_b_result.valid.package_root, &manifest_b_result.valid);
    defer lock_b.deinit(allocator);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, lock_b);

    const policy_a_key = try policy_key_mod.wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&manifest_a_result.valid));
    defer allocator.free(policy_a_key);
    const policy_b_key = try policy_key_mod.wasmPolicyLookupKey(allocator, WasmManifestHandoff.fromManifest(&manifest_b_result.valid));
    defer allocator.free(policy_b_key);
    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{"packages":["{s}","{s}"],"extensionPolicies":{{"{s}":{{"resourceLimits":{{"toolScopes":["builtin.truncateHead"]}}}},"{s}":{{"resourceLimits":{{"toolScopes":["builtin.truncateHead"]}}}}}}}}
    , .{ package_a_root, package_b_root, policy_a_key, policy_b_key });
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
    try std.testing.expectEqualStrings("builtin.truncateHead", runtime_set.entries[0].tool_id);
    try std.testing.expectEqual(@as(usize, 1), runtime_set.diagnostics.len);
    try std.testing.expectEqualStrings("duplicate_wasm_tool", runtime_set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "phase=registration") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "tool=builtin.truncateHead") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "duplicate locked wasm tool id") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, package_b_root) != null);

    var agent_tool = (try runtime_set.agentTool(allocator, "builtin.truncateHead")).?;
    defer deinitAgentTool(allocator, &agent_tool);
    try std.testing.expect(try runtime_set.unloadPackage(package_a_root));
    try std.testing.expectEqual(@as(usize, 0), runtime_set.entries.len);
    try std.testing.expectEqual(@as(?agent.AgentTool, null), try runtime_set.agentTool(allocator, "builtin.truncateHead"));
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
