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
