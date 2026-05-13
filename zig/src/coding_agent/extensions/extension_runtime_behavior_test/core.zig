const common = @import("common.zig");

const std = common.std;
const agent = common.agent;
const ai = common.ai;
const config_mod = common.config_mod;
const enforcement = common.enforcement;
const extension_events = common.extension_events;
const extension_manifest = common.extension_manifest;
const extension_registry = common.extension_registry;
const extension_runtime = common.extension_runtime;
const workflow_execution = common.workflow_execution;
const native_loader = common.native_loader;
const native_manifest = common.native_manifest;
const native_runtime = common.native_runtime;
const native_sdk = common.native_sdk;
const provenance_lockfile = common.provenance_lockfile;
const sdk = common.sdk;
const resources_mod = common.resources_mod;
const tools_common = common.tools_common;
const wasm_manifest = common.wasm_manifest;
const policy_key_mod = common.policy_key_mod;
const native_adapter_bridge = common.native_adapter_bridge;
const wasm_runtime_adapter = common.wasm_runtime_adapter;
const process_runtime_adapter = common.process_runtime_adapter;
const DiagnosticCategory = common.DiagnosticCategory;
const ExtensionUiRequest = common.ExtensionUiRequest;
const Registry = common.Registry;
const NativeDescriptor = common.NativeDescriptor;
const NativeHostApi = common.NativeHostApi;
const NativeResourceLimits = common.NativeResourceLimits;
const NativeHookDefinition = common.NativeHookDefinition;
const NativeToolDefinition = common.NativeToolDefinition;
const RuntimeKind = common.RuntimeKind;
const WasmManifestHandoff = common.WasmManifestHandoff;
const RuntimeHookDefinition = common.RuntimeHookDefinition;
const WasmOptions = common.WasmOptions;
const RuntimeOptions = common.RuntimeOptions;
const RuntimeAdapter = common.RuntimeAdapter;
const startRuntime = common.startRuntime;
const startRuntimeAdapter = common.startRuntimeAdapter;
const startLockedWasmPackageRuntimes = common.startLockedWasmPackageRuntimes;
const startLockedNativePackageRuntimes = common.startLockedNativePackageRuntimes;
const startLockedNativePackageRuntimesWithLoader = common.startLockedNativePackageRuntimesWithLoader;
const startProcessJsonl = common.startProcessJsonl;
const SingleRuntimeWorkflowCapabilityDispatchContext = common.SingleRuntimeWorkflowCapabilityDispatchContext;
const dispatchWorkflowCapabilityFromAdapter = common.dispatchWorkflowCapabilityFromAdapter;
const executeRegisteredWorkflowSurface = common.executeRegisteredWorkflowSurface;
const lifecycleSupportMatrix = common.lifecycleSupportMatrix;
const default_extension_handler_timeout_ms = common.default_extension_handler_timeout_ms;
const approvedCapabilitiesFromExtensionPolicy = common.approvedCapabilitiesFromExtensionPolicy;
const enforcementResourceLimitsFromExtensionPolicy = common.enforcementResourceLimitsFromExtensionPolicy;
const nativeResourceLimitsFromExtensionPolicy = common.nativeResourceLimitsFromExtensionPolicy;
const deinitAgentTool = common.deinitAgentTool;
const nativeRuntime = common.nativeRuntime;
const wasmRuntime = common.wasmRuntime;
const processHost = common.processHost;
const absoluteTmpPath = common.absoluteTmpPath;
const nativeDynamicArtifactName = common.nativeDynamicArtifactName;
const nativeDynamicHostOs = common.nativeDynamicHostOs;
const nativeDynamicHostArch = common.nativeDynamicHostArch;
const exitCodeFromTerm = common.exitCodeFromTerm;
const CountingNativeLoader = common.CountingNativeLoader;
const countingNativeLoader = common.countingNativeLoader;
const writeNativeDynamicRuntimePackage = common.writeNativeDynamicRuntimePackage;
const writeExecutableNativeDynamicRuntimePackage = common.writeExecutableNativeDynamicRuntimePackage;
const nativePolicyForLockedPackage = common.nativePolicyForLockedPackage;
const freeUiRequests = common.freeUiRequests;
const RegistryExpectContext = common.RegistryExpectContext;
const expectRegistryEntriesCallback = common.expectRegistryEntriesCallback;
const expectAdapterRegistryUiEventShutdownConformance = common.expectAdapterRegistryUiEventShutdownConformance;
const native_static_tool = common.native_static_tool;
const native_static_descriptor = common.native_static_descriptor;
const nativePersistedPolicyLimitStart = common.nativePersistedPolicyLimitStart;
const native_persisted_policy_limit_descriptor = common.native_persisted_policy_limit_descriptor;
const native_preready_tool = common.native_preready_tool;
const native_partial_failure_tool = common.native_partial_failure_tool;
const nativeFixtureEchoExecute = common.nativeFixtureEchoExecute;
const nativeFailAfterReadyRegistryAndUi = common.nativeFailAfterReadyRegistryAndUi;
const nativeReadyBoundaryStart = common.nativeReadyBoundaryStart;
const native_ready_boundary_descriptor = common.native_ready_boundary_descriptor;
const native_partial_failure_descriptor = common.native_partial_failure_descriptor;
const nativeHostApiBoundaryStart = common.nativeHostApiBoundaryStart;
const native_host_api_boundary_descriptor = common.native_host_api_boundary_descriptor;
const nativeInstanceIsolationStart = common.nativeInstanceIsolationStart;
const native_instance_isolation_descriptor = common.native_instance_isolation_descriptor;
const nativeUiLifecycleStart = common.nativeUiLifecycleStart;
const native_ui_lifecycle_descriptor = common.native_ui_lifecycle_descriptor;
const expectNativeStaticRegistry = common.expectNativeStaticRegistry;
const WasmToolRegistryExpectContext = common.WasmToolRegistryExpectContext;
const expectWasmToolOnlyRegistry = common.expectWasmToolOnlyRegistry;
const expectWasmToolSubsetConformance = common.expectWasmToolSubsetConformance;
const stringSliceContains = common.stringSliceContains;

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
