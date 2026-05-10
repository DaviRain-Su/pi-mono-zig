const std = @import("std");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const resources_mod = @import("../resources/resources.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");
const policy_key_mod = @import("policy_key.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const policy_resource_helpers = @import("policy_resource_helpers.zig");
const diagnostic_helpers = @import("diagnostic_helpers.zig");
const wasm_runtime_adapter = @import("wasm_runtime_adapter.zig");

const RuntimeAdapter = runtime_adapter.RuntimeAdapter;
const WasmManifestHandoff = runtime_adapter.WasmManifestHandoff;

const approvedCapabilitiesFromExtensionPolicy = policy_resource_helpers.approvedCapabilitiesFromExtensionPolicy;
const enforcementResourceLimitsFromExtensionPolicy = policy_resource_helpers.enforcementResourceLimitsFromExtensionPolicy;
const cloneResourceDiagnostic = diagnostic_helpers.cloneResourceDiagnostic;
const makeResourceDiagnostic = diagnostic_helpers.makeResourceDiagnostic;
const appendFmtDiagnostic = diagnostic_helpers.appendFmtDiagnostic;
const runtimeContractCategory = diagnostic_helpers.runtimeContractCategory;
const deinitResourceDiagnosticsList = diagnostic_helpers.deinitResourceDiagnosticsList;

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
        const policy_lookup_key = try policy_key_mod.wasmPolicyLookupKey(allocator, handoff);
        defer allocator.free(policy_lookup_key);
        handoff.policy_lookup_key = policy_lookup_key;

        const policy = runtime_config.getExtensionPolicy(policy_lookup_key) orelse {
            if (try findStaleLockedWasmPolicyKey(allocator, runtime_config, handoff)) |attempted_policy| {
                defer allocator.free(attempted_policy);
                try appendFmtDiagnostic(
                    allocator,
                    &diagnostics,
                    "policy_digest_mismatch",
                    package.manifest.manifest_path,
                    "phase=registration; tool={s}; source={s}; scope={s}; packageRoot={s}; packageRootSha256={s}; artifactSha256={s}; attemptedPolicy={s}; requiredPolicy={s}; stale digest-bound wasm extension policy",
                    .{
                        package.manifest.tool_id,
                        package.source_info.source,
                        package.lock_entry.scope.jsonName(),
                        package.manifest.package_root,
                        package.manifest.package_root_sha256,
                        package.manifest.artifact_sha256,
                        attempted_policy,
                        policy_lookup_key,
                    },
                );
            } else {
                try appendFmtDiagnostic(
                    allocator,
                    &diagnostics,
                    "missing_policy",
                    package.manifest.manifest_path,
                    "phase=registration; tool={s}; source={s}; scope={s}; packageRoot={s}; packageRootSha256={s}; artifactSha256={s}; requiredPolicy={s}; missing exact digest-bound wasm extension policy",
                    .{
                        package.manifest.tool_id,
                        package.source_info.source,
                        package.lock_entry.scope.jsonName(),
                        package.manifest.package_root,
                        package.manifest.package_root_sha256,
                        package.manifest.artifact_sha256,
                        policy_lookup_key,
                    },
                );
            }
            continue;
        };
        const approved_capabilities = try approvedCapabilitiesFromExtensionPolicy(allocator, policy);
        defer allocator.free(approved_capabilities);
        handoff.approved_capabilities = approved_capabilities;
        handoff.resource_limits = enforcementResourceLimitsFromExtensionPolicy(policy.resource_limits);

        if (handoff.deniedRuntimeCapability(.initialize, "runtime/handoff")) |denial| {
            try appendFmtDiagnostic(
                allocator,
                &diagnostics,
                denial.category,
                package.manifest.manifest_path,
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
                    policy_lookup_key,
                    policy_lookup_key,
                },
            );
            continue;
        }

        const seen = try seen_tools.getOrPut(package.manifest.tool_id);
        if (seen.found_existing) {
            try appendFmtDiagnostic(
                allocator,
                &diagnostics,
                "duplicate_wasm_tool",
                package.manifest.manifest_path,
                "phase=registration; tool={s}; packageRoot={s}; duplicate locked wasm tool id",
                .{ package.manifest.tool_id, package.manifest.package_root },
            );
            continue;
        }

        const adapter = wasm_runtime_adapter.startWasm(allocator, io, .{ .manifest = handoff }) catch |err| {
            _ = seen_tools.remove(package.manifest.tool_id);
            const category = runtimeContractCategory(err);
            try appendFmtDiagnostic(
                allocator,
                &diagnostics,
                category,
                package.manifest.manifest_path,
                "phase=load; category={s}; extension={s}; tool={s}; source={s}; scope={s}; packageRoot={s}; manifestPath={s}; artifactPath={s}; packageRootSha256={s}; artifactSha256={s}; abi=wasm-component; contract={s}; reason={s}; wasm runtime contract failed closed before tool registration",
                .{
                    category,
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
            continue;
        };
        {
            var entry = LockedWasmRuntimeEntry{
                .package_root = try allocator.dupe(u8, package.manifest.package_root),
                .manifest_path = try allocator.dupe(u8, package.manifest.manifest_path),
                .tool_id = try allocator.dupe(u8, package.manifest.tool_id),
                .policy_lookup_key = try allocator.dupe(u8, policy_lookup_key),
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
