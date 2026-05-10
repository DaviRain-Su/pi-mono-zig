const std = @import("std");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const enforcement = @import("enforcement.zig");
const native_abi_contract = @import("native/native_abi_contract.zig");
const native_loader = @import("native/native_loader.zig");
const native_manifest = @import("native/native_manifest.zig");
const native_sdk = @import("native/pi_native_extension_sdk.zig");
const provenance_lockfile = @import("../packages/provenance_lockfile.zig");
const resources_mod = @import("../resources/resources.zig");
const tools_common = @import("../tools/common.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");
const policy_resource_helpers = @import("policy_resource_helpers.zig");
const diagnostic_helpers = @import("diagnostic_helpers.zig");

const approvedCapabilitiesFromExtensionPolicy = policy_resource_helpers.approvedCapabilitiesFromExtensionPolicy;
const enforcementResourceLimitsFromExtensionPolicy = policy_resource_helpers.enforcementResourceLimitsFromExtensionPolicy;
const nativeManifestResourceLimitsToEnforcement = policy_resource_helpers.nativeManifestResourceLimitsToEnforcement;
const narrowEnforcementResourceLimits = policy_resource_helpers.narrowEnforcementResourceLimits;
const deinitEnforcementResourceLimits = policy_resource_helpers.deinitEnforcementResourceLimits;

const cloneResourceDiagnostic = diagnostic_helpers.cloneResourceDiagnostic;
const makeResourceDiagnostic = diagnostic_helpers.makeResourceDiagnostic;
const appendFmtDiagnostic = diagnostic_helpers.appendFmtDiagnostic;
const deinitResourceDiagnosticsList = diagnostic_helpers.deinitResourceDiagnosticsList;

pub const NativePackageLoader = struct {
    context: ?*anyopaque = null,
    load: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        manifest: *const native_manifest.Manifest,
        host_api: *const native_sdk.HostApiV0,
    ) anyerror!native_loader.LoadResult = productionNativePackageLoad,
};

fn productionNativePackageLoad(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    manifest: *const native_manifest.Manifest,
    host_api: *const native_sdk.HostApiV0,
) !native_loader.LoadResult {
    _ = context;
    return native_loader.loadVerifiedPackage(allocator, manifest, host_api);
}

pub const LockedNativeRuntimeEntry = struct {
    package_root: []u8,
    manifest_path: []u8,
    extension_id: []u8,
    extension_name: []u8,
    extension_version: []u8,
    tool_name: []u8,
    tool_description: []u8,
    input_schema_json: []u8,
    output_schema_json: []u8,
    policy_lookup_key: []u8,
    artifact_path: []u8,
    artifact_sha256: []u8,
    package_root_sha256: []u8,
    resource_limits: enforcement.ResourceLimits,
    accounting: enforcement.Accounting = .{},
    loaded: native_loader.LoadedLibrary,

    fn deinit(self: *LockedNativeRuntimeEntry, allocator: std.mem.Allocator) void {
        self.loaded.deinit(allocator);
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.extension_id);
        allocator.free(self.extension_name);
        allocator.free(self.extension_version);
        allocator.free(self.tool_name);
        allocator.free(self.tool_description);
        allocator.free(self.input_schema_json);
        allocator.free(self.output_schema_json);
        allocator.free(self.policy_lookup_key);
        allocator.free(self.artifact_path);
        allocator.free(self.artifact_sha256);
        allocator.free(self.package_root_sha256);
        deinitEnforcementResourceLimits(allocator, &self.resource_limits);
        self.* = undefined;
    }
};

pub const LockedNativeRuntimeSet = struct {
    allocator: std.mem.Allocator,
    entries: []LockedNativeRuntimeEntry,
    retired_entries: []LockedNativeRuntimeEntry = &.{},
    diagnostics: []resources_mod.Diagnostic,

    pub fn deinit(self: *LockedNativeRuntimeSet) void {
        for (self.entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.entries);
        for (self.retired_entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.retired_entries);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(self.allocator);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn agentTool(self: *LockedNativeRuntimeSet, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
        for (self.entries) |*entry| {
            if (!std.mem.eql(u8, entry.tool_name, name)) continue;
            return try lockedNativeAgentToolForEntry(allocator, entry, self);
        }
        return null;
    }

    pub fn detachedAgentToolForEntry(
        self: *LockedNativeRuntimeSet,
        allocator: std.mem.Allocator,
        entry: *LockedNativeRuntimeEntry,
    ) !agent.AgentTool {
        _ = self;
        return lockedNativeAgentToolForEntry(allocator, entry, null);
    }

    fn lockedNativeAgentToolForEntry(
        allocator: std.mem.Allocator,
        entry: *LockedNativeRuntimeEntry,
        runtime_set: ?*LockedNativeRuntimeSet,
    ) !agent.AgentTool {
        var parsed_parameters = try std.json.parseFromSlice(std.json.Value, allocator, entry.input_schema_json, .{});
        defer parsed_parameters.deinit();
        const context = try allocator.create(LockedNativeToolContext);
        errdefer allocator.destroy(context);
        context.* = .{
            .runtime_set = runtime_set,
            .entry = entry,
            .tool_name = try allocator.dupe(u8, entry.tool_name),
        };
        errdefer allocator.free(context.tool_name);
        return .{
            .name = entry.tool_name,
            .description = entry.tool_description,
            .label = entry.tool_name,
            .parameters = try tools_common.cloneJsonValue(allocator, parsed_parameters.value),
            .source = .extension,
            .execute = lockedNativeAgentToolExecute,
            .execute_context = context,
            .deinit_execute_context = deinitLockedNativeToolContext,
        };
    }

    pub fn unloadPackage(self: *LockedNativeRuntimeSet, package_root: []const u8) !bool {
        var list = std.ArrayList(LockedNativeRuntimeEntry).fromOwnedSlice(self.entries);
        self.entries = &.{};
        var retired = std.ArrayList(LockedNativeRuntimeEntry).fromOwnedSlice(self.retired_entries);
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
            if (entry.loaded.shutdownAndClose()) |shutdown_status| {
                if (shutdown_status != 0) {
                    const message = try std.fmt.allocPrint(
                        self.allocator,
                        "phase=shutdown; category=native_shutdown_failed; extension={s}; tool={s}; packageRoot={s}; artifactPath={s}; status={d}; native shutdown failed but unload cleanup completed",
                        .{ entry.extension_id, entry.tool_name, entry.package_root, entry.artifact_path, shutdown_status },
                    );
                    defer self.allocator.free(message);
                    try self.addDiagnostic("native_shutdown_failed", message, entry.manifest_path);
                }
            }
            retired.appendAssumeCapacity(entry);
            removed = true;
        }
        self.entries = try list.toOwnedSlice(self.allocator);
        self.retired_entries = try retired.toOwnedSlice(self.allocator);
        return removed;
    }

    pub fn addDiagnostic(
        self: *LockedNativeRuntimeSet,
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

    fn findActiveEntry(self: *LockedNativeRuntimeSet, name: []const u8) ?*LockedNativeRuntimeEntry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.tool_name, name)) return entry;
        }
        return null;
    }
};

const LockedNativeToolContext = struct {
    runtime_set: ?*LockedNativeRuntimeSet,
    entry: *LockedNativeRuntimeEntry,
    tool_name: []u8,

    fn deinit(self: *LockedNativeToolContext, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.destroy(self);
    }
};

fn deinitLockedNativeToolContext(allocator: std.mem.Allocator, tool_context: ?*anyopaque) void {
    const context: *LockedNativeToolContext = @ptrCast(@alignCast(tool_context orelse return));
    context.deinit(allocator);
}

fn lockedNativeAgentToolExecute(
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
    const context: *LockedNativeToolContext = @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
    const entry = if (context.runtime_set) |runtime_set|
        runtime_set.findActiveEntry(context.tool_name) orelse return error.NativeToolNotRegistered
    else
        context.entry;
    if (entry.loaded.unloaded) return error.NativeToolNotRegistered;

    const input_json = try std.json.Stringify.valueAlloc(allocator, params, .{});
    defer allocator.free(input_json);
    try enforceLockedNativeToolExecution(entry, .{ .turns = 1 });
    if (input_json.len > native_sdk.MAX_EXECUTE_INPUT_BYTES) {
        if (context.runtime_set) |runtime_set| {
            try appendLockedNativeExecuteDiagnostic(runtime_set, entry, "execute", "native_execute_input_too_large", "native execute input exceeded ABI maximum bytes");
        }
        return lockedNativeErrorResult(allocator, entry, "native_execute_input_too_large", "native execute input exceeded ABI maximum bytes");
    }

    const result_ptr = entry.loaded.functions.execute.?(input_json.ptr, input_json.len);
    const result_len = entry.loaded.functions.execute_len.?();
    const max_output_bytes = @min(
        entry.resource_limits.output_bytes orelse native_sdk.MAX_EXECUTE_OUTPUT_BYTES,
        native_sdk.MAX_EXECUTE_OUTPUT_BYTES,
    );
    const output_json = native_abi_contract.copyNativeBufferAndRelease(
        allocator,
        result_ptr,
        result_len,
        max_output_bytes,
        entry.loaded.functions.free.?,
    ) catch |err| {
        const code = switch (err) {
            error.NativeAbiOutputTooLarge => "native_execute_output_too_large",
            error.NativeAbiNullBuffer => "native_execute_null_buffer",
            else => return err,
        };
        if (context.runtime_set) |runtime_set| {
            try appendLockedNativeExecuteDiagnostic(runtime_set, entry, "execute", code, @errorName(err));
        }
        return lockedNativeErrorResult(allocator, entry, code, @errorName(err));
    };
    defer allocator.free(output_json);
    try enforceLockedNativeToolExecution(entry, .{
        .output_bytes = output_json.len,
        .output_lines = countLogicalLines(output_json),
    });

    return lockedNativeAgentToolResultFromEnvelope(allocator, entry, output_json) catch |err| switch (err) {
        error.NativeExecuteEnvelopeInvalid => {
            if (context.runtime_set) |runtime_set| {
                try appendLockedNativeExecuteDiagnostic(runtime_set, entry, "execute", "native_execute_invalid_envelope", "native execute returned an invalid result envelope");
            }
            return lockedNativeErrorResult(allocator, entry, "native_execute_invalid_envelope", "native execute returned an invalid result envelope");
        },
        else => return err,
    };
}

fn enforceLockedNativeToolExecution(entry: *LockedNativeRuntimeEntry, delta: enforcement.UsageDelta) !void {
    const approved_tool_use = [_]wasm_manifest.Capability{.tool_use};
    const decision = enforcement.decide(
        .{
            .runtime_kind = "native",
            .extension_id = entry.extension_id,
            .policy_lookup_key = entry.policy_lookup_key,
            .package_root = entry.package_root,
        },
        .{
            .approved_grants = approved_tool_use[0..],
            .resource_limits = entry.resource_limits,
        },
        .tool_use,
        .{ .id = entry.tool_name },
        .call,
        "native/dynamic-tool-execute",
        delta,
        &entry.accounting,
    );
    switch (decision) {
        .allow => return,
        .deny => return error.UnsupportedRuntimeCapability,
    }
}

fn lockedNativeAgentToolResultFromEnvelope(
    allocator: std.mem.Allocator,
    entry: *const LockedNativeRuntimeEntry,
    output_json: []const u8,
) !agent.AgentToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, output_json, .{}) catch return error.NativeExecuteEnvelopeInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.NativeExecuteEnvelopeInvalid;
    const ok_value = parsed.value.object.get("ok") orelse return error.NativeExecuteEnvelopeInvalid;
    if (ok_value != .bool) return error.NativeExecuteEnvelopeInvalid;
    const details = try lockedNativeRuntimeDetailsJson(allocator, entry);
    errdefer if (details) |value| tools_common.deinitJsonValue(allocator, value);
    if (ok_value.bool) {
        const output_value = parsed.value.object.get("output") orelse return error.NativeExecuteEnvelopeInvalid;
        const output_text = try std.json.Stringify.valueAlloc(allocator, output_value, .{});
        defer allocator.free(output_text);
        return .{
            .content = try tools_common.makeTextContent(allocator, output_text),
            .details = details,
        };
    }
    return .{
        .content = try tools_common.makeTextContent(allocator, output_json),
        .details = details,
        .is_error = true,
    };
}

fn lockedNativeErrorResult(
    allocator: std.mem.Allocator,
    entry: *const LockedNativeRuntimeEntry,
    code: []const u8,
    message: []const u8,
) !agent.AgentToolResult {
    const details = try lockedNativeRuntimeDetailsJson(allocator, entry);
    errdefer if (details) |value| tools_common.deinitJsonValue(allocator, value);
    const text = try std.fmt.allocPrint(
        allocator,
        "{{\"ok\":false,\"error\":{{\"category\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ code, message },
    );
    defer allocator.free(text);
    return .{
        .content = try tools_common.makeTextContent(allocator, text),
        .details = details,
        .is_error = true,
    };
}

fn appendLockedNativeExecuteDiagnostic(
    runtime_set: *LockedNativeRuntimeSet,
    entry: *const LockedNativeRuntimeEntry,
    phase: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const diagnostic = try std.fmt.allocPrint(
        runtime_set.allocator,
        "phase={s}; category={s}; extension={s}; tool={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; requiredPolicy={s}; message={s}",
        .{
            phase,
            code,
            entry.extension_id,
            entry.tool_name,
            entry.package_root,
            entry.manifest_path,
            entry.artifact_path,
            entry.package_root_sha256,
            entry.artifact_sha256,
            entry.policy_lookup_key,
            message,
        },
    );
    defer runtime_set.allocator.free(diagnostic);
    try runtime_set.addDiagnostic(code, diagnostic, entry.manifest_path);
}

fn lockedNativeRuntimeDetailsJson(allocator: std.mem.Allocator, entry: *const LockedNativeRuntimeEntry) !?std.json.Value {
    var runtime_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = runtime_object });
    try putJsonString(allocator, &runtime_object, "runtimeKind", "native");
    try putJsonString(allocator, &runtime_object, "extensionId", entry.extension_id);
    try putJsonString(allocator, &runtime_object, "extensionName", entry.extension_name);
    try putJsonString(allocator, &runtime_object, "extensionVersion", entry.extension_version);
    try putJsonString(allocator, &runtime_object, "toolId", entry.tool_name);
    try putJsonString(allocator, &runtime_object, "packageRoot", entry.package_root);
    try putJsonString(allocator, &runtime_object, "manifestPath", entry.manifest_path);
    try putJsonString(allocator, &runtime_object, "artifactPath", entry.artifact_path);
    try putJsonString(allocator, &runtime_object, "artifactSha256", entry.artifact_sha256);
    try putJsonString(allocator, &runtime_object, "packageRootSha256", entry.package_root_sha256);
    try putJsonString(allocator, &runtime_object, "policyLookupKey", entry.policy_lookup_key);

    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = root });
    try tools_common.putValue(allocator, &root, "extensionRuntime", .{ .object = runtime_object });
    return .{ .object = root };
}

pub fn startLockedNativePackageRuntimes(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    options: resources_mod.ResolveResourcesOptions,
) !LockedNativeRuntimeSet {
    return startLockedNativePackageRuntimesWithLoader(allocator, io, runtime_config, options, .{});
}

pub fn startLockedNativePackageRuntimesWithLoader(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    options: resources_mod.ResolveResourcesOptions,
    loader: NativePackageLoader,
) !LockedNativeRuntimeSet {
    var resolved = try resources_mod.resolveConfiguredLockedNativePackages(allocator, io, options);
    defer resolved.deinit(allocator);

    var diagnostics = std.ArrayList(resources_mod.Diagnostic).empty;
    errdefer deinitResourceDiagnosticsList(allocator, &diagnostics);
    for (resolved.diagnostics) |diagnostic| {
        try diagnostics.append(allocator, try cloneResourceDiagnostic(allocator, diagnostic));
    }

    var entries = std.ArrayList(LockedNativeRuntimeEntry).empty;
    errdefer deinitLockedNativeRuntimeEntryList(allocator, &entries);
    var seen_tools = std.StringHashMap(void).init(allocator);
    defer seen_tools.deinit();

    for (resolved.packages) |package| {
        try appendLockedNativePackageRuntime(allocator, runtime_config, package, loader, &diagnostics, &entries, &seen_tools);
    }

    return .{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(allocator),
        .retired_entries = &.{},
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn appendLockedNativePackageRuntime(
    allocator: std.mem.Allocator,
    runtime_config: *const config_mod.RuntimeConfig,
    package: resources_mod.LockedNativePackage,
    loader: NativePackageLoader,
    diagnostics: *std.ArrayList(resources_mod.Diagnostic),
    entries: *std.ArrayList(LockedNativeRuntimeEntry),
    seen_tools: *std.StringHashMap(void),
) !void {
    const policy_key = try provenance_lockfile.nativePolicyLookupKeyFromLockEntry(allocator, package.lock_entry);
    defer allocator.free(policy_key);

    const policy = runtime_config.getExtensionPolicy(policy_key) orelse {
        if (try findStaleLockedNativePolicyKey(allocator, runtime_config, package.lock_entry)) |attempted_policy| {
            defer allocator.free(attempted_policy);
            try appendFmtDiagnostic(
                allocator,
                diagnostics,
                "policy_digest_mismatch",
                package.manifest.manifest_path,
                "phase=registration; tool={s}; source={s}; scope={s}; packageRoot={s}; packageRootSha256={s}; artifactPath={s}; artifactSha256={s}; attemptedPolicy={s}; requiredPolicy={s}; stale digest-bound native extension policy",
                .{
                    package.manifest.tool_name,
                    package.source_info.source,
                    package.lock_entry.scope.jsonName(),
                    package.manifest.package_root,
                    package.manifest.package_root_sha256,
                    package.manifest.selected_artifact_absolute_path,
                    package.manifest.selected_artifact_sha256,
                    attempted_policy,
                    policy_key,
                },
            );
        } else {
            try appendFmtDiagnostic(
                allocator,
                diagnostics,
                "missing_policy",
                package.manifest.manifest_path,
                "phase=registration; tool={s}; source={s}; scope={s}; packageRoot={s}; packageRootSha256={s}; artifactPath={s}; artifactSha256={s}; requiredPolicy={s}; missing exact digest-bound native extension policy",
                .{
                    package.manifest.tool_name,
                    package.source_info.source,
                    package.lock_entry.scope.jsonName(),
                    package.manifest.package_root,
                    package.manifest.package_root_sha256,
                    package.manifest.selected_artifact_absolute_path,
                    package.manifest.selected_artifact_sha256,
                    policy_key,
                },
            );
        }
        return;
    };
    const approved_capabilities = try approvedCapabilitiesFromExtensionPolicy(allocator, policy);
    defer allocator.free(approved_capabilities);
    const allowed_capabilities_json = try nativeCapabilityListJson(allocator, approved_capabilities);
    defer allocator.free(allowed_capabilities_json);
    if (wasm_manifest.denyFirstUnapprovedCapability(package.manifest.requested_capabilities, approved_capabilities, .initialize, "runtime/native-loader")) |denial| {
        try appendFmtDiagnostic(
            allocator,
            diagnostics,
            denial.category,
            package.manifest.manifest_path,
            "phase={s}; category={s}; capability={s}; branch={s}; mode={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; policyDigest={s}; requiredPolicy={s}; native extension capability denied before library load",
            .{
                denial.phase.jsonName(),
                denial.category,
                denial.capability.jsonName(),
                denial.branch.jsonName(),
                denial.mode,
                package.manifest.tool_name,
                package.source_info.source,
                package.lock_entry.scope.jsonName(),
                package.manifest.package_root,
                package.manifest.selected_artifact_absolute_path,
                package.manifest.package_root_sha256,
                package.manifest.selected_artifact_sha256,
                policy_key,
                policy_key,
            },
        );
        return;
    }

    const seen = try seen_tools.getOrPut(package.manifest.tool_name);
    if (seen.found_existing) {
        try appendFmtDiagnostic(
            allocator,
            diagnostics,
            "duplicate_native_tool",
            package.manifest.manifest_path,
            "phase=registration; tool={s}; packageRoot={s}; duplicate locked native tool id",
            .{ package.manifest.tool_name, package.manifest.package_root },
        );
        return;
    }

    var host_api = native_sdk.HostApiV0.init(allowed_capabilities_json, null);
    const load_result = loader.load(loader.context, allocator, &package.manifest, &host_api) catch |err| {
        _ = seen_tools.remove(package.manifest.tool_name);
        try appendFmtDiagnostic(
            allocator,
            diagnostics,
            "native_loader_exception",
            package.manifest.manifest_path,
            "phase=load; category=native_loader_exception; extension={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; reason={s}; native loader failed closed before tool registration",
            .{
                package.manifest.id,
                package.manifest.tool_name,
                package.source_info.source,
                package.lock_entry.scope.jsonName(),
                package.manifest.package_root,
                package.manifest.manifest_path,
                package.manifest.selected_artifact_absolute_path,
                package.manifest.package_root_sha256,
                package.manifest.selected_artifact_sha256,
                @errorName(err),
            },
        );
        return;
    };
    switch (load_result) {
        .invalid => |diagnostic| {
            _ = seen_tools.remove(package.manifest.tool_name);
            const message = try nativeLoaderDiagnosticMessage(allocator, package, policy_key, diagnostic);
            defer allocator.free(message);
            try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, diagnostic.code, message, package.manifest.manifest_path));
            return;
        },
        .loaded => |loaded| try appendLoadedNativeRuntimeEntry(
            allocator,
            package,
            policy,
            policy_key,
            loaded,
            diagnostics,
            entries,
            seen_tools,
        ),
    }
}

fn appendLoadedNativeRuntimeEntry(
    allocator: std.mem.Allocator,
    package: resources_mod.LockedNativePackage,
    policy: config_mod.ExtensionPolicy,
    policy_key: []const u8,
    loaded: native_loader.LoadedLibrary,
    diagnostics: *std.ArrayList(resources_mod.Diagnostic),
    entries: *std.ArrayList(LockedNativeRuntimeEntry),
    seen_tools: *std.StringHashMap(void),
) !void {
    var metadata = parseNativeLoadedToolMetadata(allocator, loaded.functions) catch |err| {
        _ = seen_tools.remove(package.manifest.tool_name);
        var loaded_for_cleanup = loaded;
        loaded_for_cleanup.deinit(allocator);
        try appendFmtDiagnostic(
            allocator,
            diagnostics,
            "native_metadata_invalid",
            package.manifest.manifest_path,
            "phase=metadata; category=native_metadata_invalid; extension={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; reason={s}; native metadata failed closed before tool registration",
            .{
                package.manifest.id,
                package.manifest.tool_name,
                package.source_info.source,
                package.lock_entry.scope.jsonName(),
                package.manifest.package_root,
                package.manifest.manifest_path,
                package.manifest.selected_artifact_absolute_path,
                package.manifest.package_root_sha256,
                package.manifest.selected_artifact_sha256,
                @errorName(err),
            },
        );
        return;
    };
    defer metadata.deinit(allocator);
    if (!std.mem.eql(u8, metadata.tool_name, package.manifest.tool_name)) {
        _ = seen_tools.remove(package.manifest.tool_name);
        var loaded_for_cleanup = loaded;
        loaded_for_cleanup.deinit(allocator);
        try appendFmtDiagnostic(
            allocator,
            diagnostics,
            "native_metadata_tool_mismatch",
            package.manifest.manifest_path,
            "phase=metadata; category=native_metadata_tool_mismatch; extension={s}; tool={s}; metadataTool={s}; packageRoot={s}; manifestPath={s}; native metadata tool identity changed after ABI validation",
            .{ package.manifest.id, package.manifest.tool_name, metadata.tool_name, package.manifest.package_root, package.manifest.manifest_path },
        );
        return;
    }
    var resource_limits = try nativeManifestResourceLimitsToEnforcement(allocator, package.manifest.resource_limits);
    errdefer deinitEnforcementResourceLimits(allocator, &resource_limits);
    narrowEnforcementResourceLimits(&resource_limits, enforcementResourceLimitsFromExtensionPolicy(policy.resource_limits));
    var entry = LockedNativeRuntimeEntry{
        .package_root = try allocator.dupe(u8, package.manifest.package_root),
        .manifest_path = try allocator.dupe(u8, package.manifest.manifest_path),
        .extension_id = try allocator.dupe(u8, package.manifest.id),
        .extension_name = try allocator.dupe(u8, package.manifest.name),
        .extension_version = try allocator.dupe(u8, package.manifest.version),
        .tool_name = try allocator.dupe(u8, package.manifest.tool_name),
        .tool_description = try allocator.dupe(u8, metadata.tool_description),
        .input_schema_json = try allocator.dupe(u8, metadata.input_schema_json),
        .output_schema_json = try allocator.dupe(u8, metadata.output_schema_json),
        .policy_lookup_key = try allocator.dupe(u8, policy_key),
        .artifact_path = try allocator.dupe(u8, package.manifest.selected_artifact_absolute_path),
        .artifact_sha256 = try allocator.dupe(u8, package.manifest.selected_artifact_sha256),
        .package_root_sha256 = try allocator.dupe(u8, package.manifest.package_root_sha256),
        .resource_limits = resource_limits,
        .loaded = loaded,
    };
    errdefer entry.deinit(allocator);
    try entries.append(allocator, entry);
}

fn nativeLoaderDiagnosticMessage(
    allocator: std.mem.Allocator,
    package: resources_mod.LockedNativePackage,
    policy_key: []const u8,
    diagnostic: native_loader.Diagnostic,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "phase={s}; category={s}; extension={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; selectedArtifactPath={s}; packageRootSha256={s}; artifactSha256={s}; requiredPolicy={s}; native loader failed closed before tool registration",
        .{
            diagnostic.phase,
            diagnostic.code,
            package.manifest.id,
            package.manifest.tool_name,
            package.source_info.source,
            package.lock_entry.scope.jsonName(),
            package.manifest.package_root,
            package.manifest.manifest_path,
            diagnostic.artifact_path,
            package.manifest.selected_artifact_absolute_path,
            package.manifest.package_root_sha256,
            package.manifest.selected_artifact_sha256,
            policy_key,
        },
    );
    if (diagnostic.cause) |cause| try out.writer.print("; cause={s}", .{cause});
    if (diagnostic.symbol) |symbol| try out.writer.print("; symbol={s}", .{symbol});
    if (diagnostic.expected) |expected| try out.writer.print("; expected={s}", .{expected});
    if (diagnostic.actual) |actual| try out.writer.print("; actual={s}", .{actual});
    try out.writer.print("; message={s}", .{diagnostic.message});
    return out.toOwnedSlice();
}

const NativeLoadedToolMetadata = struct {
    tool_name: []u8,
    tool_description: []u8,
    input_schema_json: []u8,
    output_schema_json: []u8,

    fn deinit(self: *NativeLoadedToolMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.tool_description);
        allocator.free(self.input_schema_json);
        allocator.free(self.output_schema_json);
        self.* = undefined;
    }
};

fn parseNativeLoadedToolMetadata(
    allocator: std.mem.Allocator,
    functions: native_abi_contract.FunctionTable,
) !NativeLoadedToolMetadata {
    const metadata_ptr = functions.metadata_ptr orelse return error.NativeMetadataMissing;
    const metadata_len = functions.metadata_len orelse return error.NativeMetadataMissing;
    const metadata_json = metadata_ptr()[0..metadata_len()];
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NativeMetadataInvalid;
    const tool = parsed.value.object.get("tool") orelse return error.NativeMetadataInvalid;
    if (tool != .object) return error.NativeMetadataInvalid;
    const name = jsonString(tool.object, "name") orelse return error.NativeMetadataInvalid;
    const description = jsonString(tool.object, "description") orelse return error.NativeMetadataInvalid;
    const input_schema = tool.object.get("inputSchema") orelse return error.NativeMetadataInvalid;
    if (input_schema != .object) return error.NativeMetadataInvalid;
    const output_schema = tool.object.get("outputSchema") orelse return error.NativeMetadataInvalid;
    if (output_schema != .object) return error.NativeMetadataInvalid;
    const input_schema_json = try std.json.Stringify.valueAlloc(allocator, input_schema, .{});
    errdefer allocator.free(input_schema_json);
    const output_schema_json = try std.json.Stringify.valueAlloc(allocator, output_schema, .{});
    errdefer allocator.free(output_schema_json);
    return .{
        .tool_name = try allocator.dupe(u8, name),
        .tool_description = try allocator.dupe(u8, description),
        .input_schema_json = input_schema_json,
        .output_schema_json = output_schema_json,
    };
}

fn nativeCapabilityListJson(allocator: std.mem.Allocator, capabilities: []const wasm_manifest.Capability) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("[");
    for (capabilities, 0..) |capability, index| {
        if (index > 0) try out.writer.writeAll(",");
        try std.json.Stringify.value(capability.jsonName(), .{}, &out.writer);
    }
    try out.writer.writeAll("]");
    return allocator.dupe(u8, out.written());
}

fn jsonString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn findStaleLockedNativePolicyKey(
    allocator: std.mem.Allocator,
    runtime_config: *const config_mod.RuntimeConfig,
    entry: provenance_lockfile.LockEntry,
) !?[]u8 {
    var policies = runtime_config.settings.extension_policies orelse return null;
    const schema_version = entry.manifest_schema_version orelse native_manifest.SCHEMA_VERSION;
    const extension_id = entry.manifest_id orelse "";
    const extension_version = entry.manifest_version orelse "";
    const prefix = try std.fmt.allocPrint(
        allocator,
        "native:locked:{s}:{s}:{s}:{s}:{s}:",
        .{ entry.scope.jsonName(), entry.source_identity, schema_version, extension_id, extension_version },
    );
    defer allocator.free(prefix);
    var iterator = policies.iterator();
    while (iterator.next()) |policy_entry| {
        if (std.mem.startsWith(u8, policy_entry.key_ptr.*, prefix)) {
            return try allocator.dupe(u8, policy_entry.key_ptr.*);
        }
    }
    return null;
}

fn deinitLockedNativeRuntimeEntryList(allocator: std.mem.Allocator, entries: *std.ArrayList(LockedNativeRuntimeEntry)) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
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

fn countLogicalLines(value: []const u8) u64 {
    if (value.len == 0) return 0;
    var lines: u64 = 1;
    for (value) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}
