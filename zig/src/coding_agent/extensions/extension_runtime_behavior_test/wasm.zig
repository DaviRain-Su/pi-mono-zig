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
    var lock_entry = try provenance_lockfile.createWasmLockEntry(allocator, .user, manifest_result.valid.package_root, &manifest_result.valid);
    defer lock_entry.deinit(allocator);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, project_dir, agent_dir);
    defer allocator.free(lock_path);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, lock_entry);

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
