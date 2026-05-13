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
