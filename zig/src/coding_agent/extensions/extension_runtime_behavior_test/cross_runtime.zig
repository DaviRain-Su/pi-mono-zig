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
