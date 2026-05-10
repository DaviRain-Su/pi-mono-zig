const std = @import("std");
const agent = @import("agent");
const extension_host = @import("extension_host.zig");
const native_runtime = @import("native_runtime.zig");
const tools_common = @import("../tools/common.zig");
const lifecycle_support = @import("lifecycle_support.zig");
const policy_key_mod = @import("policy_key.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const policy_resource_helpers = @import("policy_resource_helpers.zig");
const native_adapter_bridge = @import("native_adapter_bridge.zig");
const wasm_runtime_adapter = @import("wasm_runtime_adapter.zig");
const process_runtime_adapter = @import("process_runtime_adapter.zig");
const workflow_event_bridge = @import("workflow_event_bridge.zig");
const locked_wasm_runtime = @import("locked_wasm_runtime.zig");
const locked_native_runtime = @import("locked_native_runtime.zig");

pub const typeScriptPolicyLookupKey = policy_key_mod.typeScriptPolicyLookupKey;
pub const wasmManifestPolicyLookupKey = policy_key_mod.wasmManifestPolicyLookupKey;
pub const wasmPolicyLookupKey = policy_key_mod.wasmPolicyLookupKey;
pub const nativePolicyLookupKey = policy_key_mod.nativePolicyLookupKey;
pub const processJsonlPolicyLookupKey = policy_key_mod.processJsonlPolicyLookupKey;
pub const TypeScriptPolicyLookupOptions = policy_key_mod.TypeScriptPolicyLookupOptions;
pub const WasmManifestPolicyLookupOptions = policy_key_mod.WasmManifestPolicyLookupOptions;

pub const DiagnosticCategory = runtime_adapter.DiagnosticCategory;
pub const ExtensionUiRequest = runtime_adapter.ExtensionUiRequest;
pub const HOST_MARKER_ENV = extension_host.HOST_MARKER_ENV;
pub const InitializeFrame = extension_host.InitializeFrame;
pub const ProcessJsonlOptions = runtime_adapter.ProcessJsonlOptions;
pub const Registry = runtime_adapter.Registry;
pub const RegistryCallback = runtime_adapter.RegistryCallback;
pub const NativeDescriptor = native_runtime.NativeDescriptor;
pub const NativeHostApi = native_runtime.NativeHostApi;
pub const NativeOptions = runtime_adapter.NativeOptions;
pub const NativeResourceLimits = native_runtime.NativeResourceLimits;
pub const NativeHookDefinition = native_runtime.NativeHookDefinition;
pub const NativeToolDefinition = native_runtime.NativeToolDefinition;

pub const RuntimeKind = runtime_adapter.RuntimeKind;

pub const default_extension_handler_timeout_ms = lifecycle_support.default_extension_handler_timeout_ms;
pub const LifecycleSupportRuntime = lifecycle_support.LifecycleSupportRuntime;
pub const LifecycleSupportEntry = lifecycle_support.LifecycleSupportEntry;
pub const lifecycleSupportMatrix = lifecycle_support.lifecycleSupportMatrix;

pub const UnsupportedRuntimeOptions = runtime_adapter.UnsupportedRuntimeOptions;
pub const WasmManifestHandoff = runtime_adapter.WasmManifestHandoff;
pub const RuntimeHookDefinition = runtime_adapter.RuntimeHookDefinition;
pub const WasmOptions = runtime_adapter.WasmOptions;
pub const RuntimeOptions = runtime_adapter.RuntimeOptions;
pub const RuntimeSetupErrorEvent = runtime_adapter.RuntimeSetupErrorEvent;
pub const RuntimeSetupEvent = runtime_adapter.RuntimeSetupEvent;
pub const RuntimeSetupEventStream = runtime_adapter.RuntimeSetupEventStream;
pub const RuntimeAdapter = runtime_adapter.RuntimeAdapter;
pub const LockedWasmRuntimeEntry = locked_wasm_runtime.LockedWasmRuntimeEntry;
pub const LockedWasmRuntimeSet = locked_wasm_runtime.LockedWasmRuntimeSet;
pub const startLockedWasmPackageRuntimes = locked_wasm_runtime.startLockedWasmPackageRuntimes;
pub const startNative = native_adapter_bridge.startNative;
pub const native_vtable = native_adapter_bridge.native_vtable;

pub const approvedCapabilitiesFromExtensionPolicy = policy_resource_helpers.approvedCapabilitiesFromExtensionPolicy;
pub const enforcementResourceLimitsFromExtensionPolicy = policy_resource_helpers.enforcementResourceLimitsFromExtensionPolicy;
pub const nativeResourceLimitsFromExtensionPolicy = policy_resource_helpers.nativeResourceLimitsFromExtensionPolicy;

const runtime_adapter_dispatch = runtime_adapter.RuntimeAdapterDispatch{
    .process_jsonl = startProcessJsonl,
    .wasm = startWasm,
    .native = startNative,
};

pub fn startRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
) !RuntimeSetupEventStream {
    return runtime_adapter.startRuntimeWithDispatch(allocator, io, options, runtime_adapter_dispatch);
}

pub fn streamRuntimeSetup(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
) !RuntimeSetupEventStream {
    return runtime_adapter.streamRuntimeSetupWithDispatch(allocator, io, options, runtime_adapter_dispatch);
}

pub fn deinitAgentTool(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    tools_common.deinitJsonValue(allocator, tool.parameters);
    if (tool.deinit_execute_context) |deinit_context| deinit_context(allocator, tool.execute_context);
    tool.* = undefined;
}

pub fn startRuntimeAdapter(allocator: std.mem.Allocator, io: std.Io, options: RuntimeOptions) !RuntimeAdapter {
    return runtime_adapter.startRuntimeAdapterWithDispatch(allocator, io, options, runtime_adapter_dispatch);
}

pub const NativePackageLoader = locked_native_runtime.NativePackageLoader;
pub const LockedNativeRuntimeEntry = locked_native_runtime.LockedNativeRuntimeEntry;
pub const LockedNativeRuntimeSet = locked_native_runtime.LockedNativeRuntimeSet;
pub const startLockedNativePackageRuntimes = locked_native_runtime.startLockedNativePackageRuntimes;
pub const startLockedNativePackageRuntimesWithLoader = locked_native_runtime.startLockedNativePackageRuntimesWithLoader;

pub const startProcessJsonl = process_runtime_adapter.startProcessJsonl;
pub const attachWorkflowDispatchAdapters = process_runtime_adapter.attachWorkflowDispatchAdapters;
pub const WorkflowSurfaceKind = workflow_event_bridge.WorkflowSurfaceKind;
pub const WorkflowSurfaceExecutionOptions = workflow_event_bridge.WorkflowSurfaceExecutionOptions;
pub const WorkflowCapabilityDispatchContext = workflow_event_bridge.WorkflowCapabilityDispatchContext;
pub const SingleRuntimeWorkflowCapabilityDispatchContext = workflow_event_bridge.SingleRuntimeWorkflowCapabilityDispatchContext;
pub const dispatchWorkflowCapabilityFromAdapters = workflow_event_bridge.dispatchWorkflowCapabilityFromAdapters;
pub const dispatchWorkflowCapabilityFromAdapter = workflow_event_bridge.dispatchWorkflowCapabilityFromAdapter;
pub const executeRegisteredWorkflowSurface = workflow_event_bridge.executeRegisteredWorkflowSurface;
pub const workflowExecutionResultDataJson = workflow_event_bridge.workflowExecutionResultDataJson;

pub const startWasm = wasm_runtime_adapter.startWasm;
