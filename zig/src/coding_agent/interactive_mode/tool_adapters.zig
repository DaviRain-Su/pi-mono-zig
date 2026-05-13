const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tools = @import("../tools/root.zig");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const capability = @import("../extensions/capability.zig");
const enforcement = @import("../extensions/enforcement.zig");
const extension_manifest = @import("../extensions/extension_manifest.zig");
const extension_registry = @import("../extensions/extension_registry.zig");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const system_prompt_mod = @import("../resources/system_prompt.zig");
const session_mod = @import("../sessions/session.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const shared = @import("shared.zig");
const subagent = @import("../extensions/subagent.zig");
const native_extension_loader = @import("../extensions/native_extension_loader.zig");
const tool_selection_mod = @import("../tool_selection.zig");

const AppContext = shared.AppContext;

pub const BuiltTools = struct {
    allocator: std.mem.Allocator,
    items: []agent.AgentTool,
    locked_wasm_runtimes: ?extension_runtime.LockedWasmRuntimeSet = null,
    locked_native_runtimes: ?extension_runtime.LockedNativeRuntimeSet = null,
    extension_hosts: []extension_runtime.RuntimeAdapter = &.{},
    startup_diagnostics: []ExtensionStartupDiagnostic = &.{},
    startup_manifest_registry_snapshot: ?[]u8 = null,
    required_startup_failed: bool = false,

    pub fn deinit(self: *BuiltTools) void {
        for (self.items) |item| {
            common.deinitJsonValue(self.allocator, item.parameters);
            if (item.deinit_execute_context) |deinit_context| {
                deinit_context(self.allocator, item.execute_context);
            }
        }
        self.allocator.free(self.items);
        if (self.locked_wasm_runtimes) |*runtime_set| runtime_set.deinit();
        if (self.locked_native_runtimes) |*runtime_set| runtime_set.deinit();
        for (self.extension_hosts) |host| host.deinit();
        if (self.extension_hosts.len > 0) self.allocator.free(self.extension_hosts);
        for (self.startup_diagnostics) |*diagnostic| diagnostic.deinit(self.allocator);
        if (self.startup_diagnostics.len > 0) self.allocator.free(self.startup_diagnostics);
        if (self.startup_manifest_registry_snapshot) |snapshot| self.allocator.free(snapshot);
        self.* = undefined;
    }
};

pub const ToolBuildOptions = struct {
    selected_tools: tool_selection_mod.ToolSelection = .{},
    include_builtin_tools: bool = true,
    include_installed_wasm_tools: bool = true,
    include_installed_native_tools: bool = true,
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    resource_options: ?resources_mod.ResolveResourcesOptions = null,
    extension_options: ExtensionToolHostOptions = .{},
};

pub const ExtensionStartupSeverity = enum {
    info,
    warning,
    @"error",

    pub fn jsonName(self: ExtensionStartupSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const ExtensionStartupDiagnostic = struct {
    severity: ExtensionStartupSeverity,
    phase: []u8,
    extension_id: []u8,
    extension_path: []u8,
    source_path: []u8,
    policy_key: ?[]u8 = null,
    required: bool = false,
    message: []u8,

    pub fn deinit(self: *ExtensionStartupDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.phase);
        allocator.free(self.extension_id);
        allocator.free(self.extension_path);
        allocator.free(self.source_path);
        if (self.policy_key) |policy_key| allocator.free(policy_key);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ExtensionToolHostOptions = struct {
    extensions: []const resources_mod.LoadedExtension = &.{},
    env_map: ?*const std.process.Environ.Map = null,
    cwd: []const u8 = "",
    io: ?std.Io = null,
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    start_without_tools: bool = false,
    include_builtin_tools: bool = true,
    include_installed_wasm_tools: bool = true,
    include_installed_native_tools: bool = true,
    resource_options: ?resources_mod.ResolveResourcesOptions = null,
};

pub fn buildAgentTools(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selected_tools: ?[]const []const u8,
) !BuiltTools {
    return buildAgentToolsWithOptions(allocator, app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(selected_tools),
    });
}

pub fn buildAgentToolsWithOptions(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    options: ToolBuildOptions,
) !BuiltTools {
    var extension_options = options.extension_options;
    extension_options.runtime_config = options.runtime_config;
    extension_options.include_builtin_tools = options.include_builtin_tools;
    extension_options.include_installed_wasm_tools = options.include_installed_wasm_tools;
    extension_options.include_installed_native_tools = options.include_installed_native_tools;
    extension_options.resource_options = options.resource_options;
    return buildAgentToolsWithExtensionsSelection(allocator, app_context, options.selected_tools, extension_options);
}

pub fn buildAgentToolsWithSelection(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selection: tool_selection_mod.ToolSelection,
) !BuiltTools {
    return buildAgentToolsWithExtensionsSelection(allocator, app_context, selection, .{});
}

pub fn buildAgentToolsWithExtensions(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selected_tools: ?[]const []const u8,
    extension_options: ExtensionToolHostOptions,
) !BuiltTools {
    return buildAgentToolsWithExtensionsSelection(
        allocator,
        app_context,
        tool_selection_mod.ToolSelection.fromAllowlist(selected_tools),
        extension_options,
    );
}

pub fn buildAgentToolsWithExtensionsSelection(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selection: tool_selection_mod.ToolSelection,
    extension_options: ExtensionToolHostOptions,
) !BuiltTools {
    var items = std.ArrayList(agent.AgentTool).empty;
    errdefer {
        for (items.items) |item| {
            common.deinitJsonValue(allocator, item.parameters);
            if (item.deinit_execute_context) |deinit_context| {
                deinit_context(allocator, item.execute_context);
            }
        }
        items.deinit(allocator);
    }
    var extension_hosts = std.ArrayList(extension_runtime.RuntimeAdapter).empty;
    errdefer {
        for (extension_hosts.items) |host| host.deinit();
        extension_hosts.deinit(allocator);
    }
    var startup_diagnostics = std.ArrayList(ExtensionStartupDiagnostic).empty;
    errdefer deinitExtensionStartupDiagnostics(allocator, &startup_diagnostics);
    var required_startup_failed = false;
    var startup_manifest_registry_snapshot: ?[]u8 = null;
    errdefer if (startup_manifest_registry_snapshot) |snapshot| allocator.free(snapshot);
    var locked_wasm_runtimes: ?extension_runtime.LockedWasmRuntimeSet = null;
    errdefer if (locked_wasm_runtimes) |*runtime_set| runtime_set.deinit();
    var locked_native_runtimes: ?extension_runtime.LockedNativeRuntimeSet = null;
    errdefer if (locked_native_runtimes) |*runtime_set| runtime_set.deinit();

    if (extension_options.include_builtin_tools) {
        inline for (tools.ALL, 0..) |ToolT, i| {
            try appendToolIfEnabled(allocator, &items, app_context, selection, ToolT.name, ToolT.description, try ToolT.schema(allocator), BUILTIN_TOOL_EXECUTORS[i]);
        }

        // Load built-in native extensions (subagent)
        if (selection.hasAllowlist() and selection.allowsExtension(subagent.subagent_descriptor.tools[0].name)) {
            const subagent_host = extension_runtime.startNative(allocator, app_context.tool_runtime.io, .{
                .descriptor = &subagent.subagent_descriptor,
                .approved_capabilities = &.{ .shell_run, .file_read, .env_read },
            }) catch |err| blk: {
                const message = try std.fmt.allocPrint(allocator, "built-in subagent extension startup failed: {s}", .{@errorName(err)});
                defer allocator.free(message);
                try startup_diagnostics.append(allocator, .{
                    .severity = .warning,
                    .phase = try allocator.dupe(u8, "startup"),
                    .extension_id = try allocator.dupe(u8, subagent.subagent_descriptor.id),
                    .extension_path = try allocator.dupe(u8, "native://subagent"),
                    .source_path = try allocator.dupe(u8, "native://subagent"),
                    .message = message,
                });
                break :blk null;
            };
            if (subagent_host) |host| {
                var host_owned = true;
                errdefer if (host_owned) host.deinit();

                host.waitForReady(5000) catch |err| {
                    const message = try std.fmt.allocPrint(allocator, "built-in subagent extension ready timeout: {s}", .{@errorName(err)});
                    defer allocator.free(message);
                    try startup_diagnostics.append(allocator, .{
                        .severity = .warning,
                        .phase = try allocator.dupe(u8, "startup"),
                        .extension_id = try allocator.dupe(u8, subagent.subagent_descriptor.id),
                        .extension_path = try allocator.dupe(u8, "native://subagent"),
                        .source_path = try allocator.dupe(u8, "native://subagent"),
                        .message = message,
                    });
                    host.deinit();
                    host_owned = false;
                };
                if (host_owned) {
                    if (try host.agentTool(allocator, subagent.subagent_descriptor.tools[0].name)) |tool| {
                        try items.append(allocator, tool);
                    }
                    try extension_hosts.append(allocator, host);
                    host_owned = false;
                }
            }
        }
    }

    if (extension_options.include_installed_wasm_tools) {
        if (extension_options.runtime_config) |runtime_config| {
            if (extension_options.resource_options) |resource_options| {
                locked_wasm_runtimes = try extension_runtime.startLockedWasmPackageRuntimes(
                    allocator,
                    app_context.tool_runtime.io,
                    runtime_config,
                    resource_options,
                );
                try appendLockedWasmTools(allocator, &items, &locked_wasm_runtimes.?, selection);
            }
        }
    }

    if (extension_options.include_installed_native_tools) {
        if (extension_options.runtime_config) |runtime_config| {
            if (extension_options.resource_options) |resource_options| {
                locked_native_runtimes = try extension_runtime.startLockedNativePackageRuntimes(
                    allocator,
                    app_context.tool_runtime.io,
                    runtime_config,
                    resource_options,
                );
                try appendLockedNativeTools(allocator, &items, &locked_native_runtimes.?, selection);
            }
        }
    }

    var resolved_extension_options = extension_options;
    if (resolved_extension_options.cwd.len == 0) resolved_extension_options.cwd = app_context.tool_runtime.cwd;
    if (resolved_extension_options.io == null) resolved_extension_options.io = app_context.tool_runtime.io;
    try appendExtensionTools(allocator, &items, &extension_hosts, &startup_diagnostics, &startup_manifest_registry_snapshot, &required_startup_failed, selection, resolved_extension_options);
    try extension_runtime.attachWorkflowDispatchAdapters(allocator, items.items, extension_hosts.items);

    const owned_items = try items.toOwnedSlice(allocator);
    errdefer {
        for (owned_items) |item| {
            common.deinitJsonValue(allocator, item.parameters);
            if (item.deinit_execute_context) |deinit_context| {
                deinit_context(allocator, item.execute_context);
            }
        }
        allocator.free(owned_items);
    }
    const owned_extension_hosts = try extension_hosts.toOwnedSlice(allocator);
    errdefer {
        for (owned_extension_hosts) |host| host.deinit();
        allocator.free(owned_extension_hosts);
    }
    const owned_startup_diagnostics = try startup_diagnostics.toOwnedSlice(allocator);
    errdefer {
        for (owned_startup_diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(owned_startup_diagnostics);
    }

    return .{
        .allocator = allocator,
        .items = owned_items,
        .locked_wasm_runtimes = locked_wasm_runtimes,
        .locked_native_runtimes = locked_native_runtimes,
        .extension_hosts = owned_extension_hosts,
        .startup_diagnostics = owned_startup_diagnostics,
        .startup_manifest_registry_snapshot = startup_manifest_registry_snapshot,
        .required_startup_failed = required_startup_failed,
    };
}

pub fn appendLockedWasmTools(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    runtime_set: *extension_runtime.LockedWasmRuntimeSet,
    selection: tool_selection_mod.ToolSelection,
) !void {
    for (runtime_set.entries) |*entry| {
        if (!selection.allowsExtension(entry.tool_id)) continue;
        if (hasToolName(items.items, entry.tool_id)) {
            const message = try std.fmt.allocPrint(
                allocator,
                "phase=tool_construction; tool={s}; packageRoot={s}; installed wasm tool conflicts with existing provider tool",
                .{ entry.tool_id, entry.package_root },
            );
            defer allocator.free(message);
            try runtime_set.addDiagnostic("builtin_wasm_tool_conflict", message, entry.manifest_path);
            continue;
        }
        var tool = (try runtime_set.agentTool(allocator, entry.tool_id)) orelse continue;
        errdefer extension_runtime.deinitAgentTool(allocator, &tool);
        try items.append(allocator, tool);
    }
}

fn appendLockedNativeTools(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    runtime_set: *extension_runtime.LockedNativeRuntimeSet,
    selection: tool_selection_mod.ToolSelection,
) !void {
    for (runtime_set.entries) |*entry| {
        if (!selection.allowsExtension(entry.tool_name)) continue;
        if (hasToolName(items.items, entry.tool_name)) {
            const message = try std.fmt.allocPrint(
                allocator,
                "phase=tool_construction; tool={s}; packageRoot={s}; installed native tool conflicts with existing provider tool",
                .{ entry.tool_name, entry.package_root },
            );
            defer allocator.free(message);
            try runtime_set.addDiagnostic("builtin_native_tool_conflict", message, entry.manifest_path);
            continue;
        }
        var tool = try runtime_set.detachedAgentToolForEntry(allocator, entry);
        errdefer extension_runtime.deinitAgentTool(allocator, &tool);
        try items.append(allocator, tool);
    }
}

fn hasToolName(items: []const agent.AgentTool, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

pub fn writeStartupDiagnostics(stderr: *std.Io.Writer, diagnostics: []const ExtensionStartupDiagnostic) !void {
    const unapproved_count = countUnapprovedPolicyDiagnostics(diagnostics);
    if (unapproved_count > 0) {
        try stderr.print("Warning: {d} extensions skipped: unapproved", .{unapproved_count});
        try writeUnapprovedPolicyNames(stderr, diagnostics);
        try stderr.writeAll("\n");
    }

    for (diagnostics) |diagnostic| {
        if (isUnapprovedPolicyDiagnostic(diagnostic)) continue;
        const prefix = switch (diagnostic.severity) {
            .info => "Info",
            .warning => "Warning",
            .@"error" => "Error",
        };
        try stderr.print("{s}: {s}: {s} ({s})\n", .{
            prefix,
            startupDiagnosticAction(diagnostic),
            startupDiagnosticName(diagnostic),
            startupDiagnosticReason(diagnostic),
        });
    }
}

fn countUnapprovedPolicyDiagnostics(diagnostics: []const ExtensionStartupDiagnostic) usize {
    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (isUnapprovedPolicyDiagnostic(diagnostic)) count += 1;
    }
    return count;
}

fn writeUnapprovedPolicyNames(stderr: *std.Io.Writer, diagnostics: []const ExtensionStartupDiagnostic) !void {
    const max_names = 6;
    var unique_count: usize = 0;
    for (diagnostics, 0..) |diagnostic, index| {
        if (!isUnapprovedPolicyDiagnostic(diagnostic)) continue;
        const name = startupDiagnosticName(diagnostic);
        if (hasPriorUnapprovedName(diagnostics[0..index], name)) continue;
        unique_count += 1;
    }

    if (unique_count == 0) return;
    try stderr.writeAll(" (");
    var printed: usize = 0;
    for (diagnostics, 0..) |diagnostic, index| {
        if (!isUnapprovedPolicyDiagnostic(diagnostic)) continue;
        const name = startupDiagnosticName(diagnostic);
        if (hasPriorUnapprovedName(diagnostics[0..index], name)) continue;
        if (printed == max_names) break;
        if (printed > 0) try stderr.writeAll(", ");
        try stderr.writeAll(name);
        printed += 1;
    }
    if (unique_count > printed) {
        try stderr.print(", +{d} more", .{unique_count - printed});
    }
    try stderr.writeAll(")");
}

fn hasPriorUnapprovedName(previous: []const ExtensionStartupDiagnostic, name: []const u8) bool {
    for (previous) |diagnostic| {
        if (!isUnapprovedPolicyDiagnostic(diagnostic)) continue;
        if (std.mem.eql(u8, startupDiagnosticName(diagnostic), name)) return true;
    }
    return false;
}

fn isUnapprovedPolicyDiagnostic(diagnostic: ExtensionStartupDiagnostic) bool {
    return std.mem.eql(u8, diagnostic.phase, "policy") and
        std.mem.indexOf(u8, diagnostic.message, "extension is unapproved; no matching extensionPolicies entry") != null;
}

fn startupDiagnosticAction(diagnostic: ExtensionStartupDiagnostic) []const u8 {
    if (diagnostic.severity == .@"error") return "extension failed";
    if (std.mem.eql(u8, diagnostic.phase, "policy")) return "extension skipped";
    return "extension warning";
}

fn startupDiagnosticName(diagnostic: ExtensionStartupDiagnostic) []const u8 {
    if (diagnostic.policy_key) |policy_key| {
        if (packageNameFromPolicyKey(policy_key)) |name| return name;
    }
    if (diagnostic.source_path.len > 0) return compactExtensionPath(diagnostic.source_path);
    if (diagnostic.extension_path.len > 0) return compactExtensionPath(diagnostic.extension_path);
    return diagnostic.extension_id;
}

fn packageNameFromPolicyKey(policy_key: []const u8) ?[]const u8 {
    const prefix = "typescript:package:";
    if (!std.mem.startsWith(u8, policy_key, prefix)) return null;
    var rest = policy_key[prefix.len..];
    const scope_end = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    rest = rest[scope_end + 1 ..];
    if (std.mem.startsWith(u8, rest, "npm:")) {
        rest = rest["npm:".len..];
    }
    const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn compactExtensionPath(path: []const u8) []const u8 {
    const marker = "/node_modules/";
    if (std.mem.indexOf(u8, path, marker)) |index| {
        return path[index + marker.len ..];
    }
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| {
        return path[index + 1 ..];
    }
    return path;
}

fn startupDiagnosticReason(diagnostic: ExtensionStartupDiagnostic) []const u8 {
    if (std.mem.indexOf(u8, diagnostic.message, "approvedGrants does not include tool.use") != null) {
        return "missing tool.use grant";
    }
    if (std.mem.indexOf(u8, diagnostic.message, "startup timed out") != null) {
        return "startup timed out";
    }
    if (std.mem.indexOf(u8, diagnostic.message, "duplicate extension tool name skipped: ")) |index| {
        return diagnostic.message[index + "duplicate extension tool name skipped: ".len ..];
    }
    if (std.mem.lastIndexOf(u8, diagnostic.message, ": ")) |index| {
        return diagnostic.message[index + 2 ..];
    }
    return diagnostic.message;
}

pub const ExtensionBootstrapContributions = struct {
    allocator: std.mem.Allocator,
    provider_names: [][]u8 = &.{},
    provider_diagnostics: []ProviderCollisionDiagnostic = &.{},
    resource_discoveries: []resources_mod.ExtensionDiscoveredResources = &.{},

    pub fn deinit(self: *ExtensionBootstrapContributions) void {
        for (self.provider_names) |name| {
            ai.model_registry.unregisterProvider(name);
            self.allocator.free(name);
        }
        if (self.provider_names.len > 0) self.allocator.free(self.provider_names);
        for (self.provider_diagnostics) |*diagnostic| diagnostic.deinit(self.allocator);
        if (self.provider_diagnostics.len > 0) self.allocator.free(self.provider_diagnostics);
        for (self.resource_discoveries) |*discovery| {
            self.allocator.free(@constCast(discovery.extension_path));
            discovery.source_info.deinit(self.allocator);
            freeStringConstList(self.allocator, discovery.skill_paths);
            freeStringConstList(self.allocator, discovery.prompt_paths);
            freeStringConstList(self.allocator, discovery.theme_paths);
        }
        if (self.resource_discoveries.len > 0) self.allocator.free(self.resource_discoveries);
        self.* = undefined;
    }
};

pub const ProviderCollisionDiagnostic = struct {
    code: []u8,
    severity: []u8,
    provider_id: []u8,
    extension_path: []u8,
    source_path: []u8,
    conflict_kind: []u8,
    conflict_with: []u8,
    message: []u8,

    pub fn deinit(self: *ProviderCollisionDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.severity);
        allocator.free(self.provider_id);
        allocator.free(self.extension_path);
        allocator.free(self.source_path);
        allocator.free(self.conflict_kind);
        allocator.free(self.conflict_with);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn registerExtensionProvidersAndCollectResources(
    allocator: std.mem.Allocator,
    built_tools: *const BuiltTools,
    extensions: []const resources_mod.LoadedExtension,
) !ExtensionBootstrapContributions {
    var context = ExtensionContributionContext{
        .allocator = allocator,
        .extensions = extensions,
    };
    errdefer context.deinitScratch();

    for (built_tools.extension_hosts) |host| {
        try host.withRegistry(&context, collectRegistryContributions);
    }
    try activateExtensionProviderCandidates(&context);

    const provider_names = try context.provider_names.toOwnedSlice(allocator);
    errdefer {
        for (provider_names) |name| allocator.free(name);
        allocator.free(provider_names);
    }
    const provider_diagnostics = try context.provider_diagnostics.toOwnedSlice(allocator);
    errdefer {
        for (provider_diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(provider_diagnostics);
    }
    const resource_discoveries = try context.resource_discoveries.toOwnedSlice(allocator);
    context.deinitProviderCandidates();

    return .{
        .allocator = allocator,
        .provider_names = provider_names,
        .provider_diagnostics = provider_diagnostics,
        .resource_discoveries = resource_discoveries,
    };
}

pub fn replaceAgentToolsForReload(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    session: *session_mod.AgentSession,
    built_tools: *BuiltTools,
    selection: tool_selection_mod.ToolSelection,
    extension_options: ExtensionToolHostOptions,
) !void {
    var next_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        app_context,
        selection,
        extension_options,
    );
    errdefer next_tools.deinit();

    try session.agent.setTools(next_tools.items);

    var previous_tools = built_tools.*;
    built_tools.* = next_tools;
    previous_tools.deinit();
}

fn appendToolIfEnabled(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    app_context: *AppContext,
    selection: tool_selection_mod.ToolSelection,
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
    execute: agent.types.ExecuteToolFn,
) !void {
    if (!selection.allowsBuiltin(name)) {
        common.deinitJsonValue(allocator, schema);
        return;
    }

    try items.append(allocator, .{
        .name = name,
        .description = description,
        .label = name,
        .parameters = schema,
        .source = .builtin,
        .execute = execute,
        .execute_context = app_context,
    });
}

fn appendExtensionTools(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    extension_hosts: *std.ArrayList(extension_runtime.RuntimeAdapter),
    startup_diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    startup_manifest_registry_snapshot: *?[]u8,
    required_startup_failed: *bool,
    selection: tool_selection_mod.ToolSelection,
    options: ExtensionToolHostOptions,
) !void {
    if (selection.disable_all and !options.start_without_tools) return;
    if (options.extensions.len == 0) return;

    var startup_graph = try resolveStartupManifestGraph(allocator, options, startup_diagnostics, required_startup_failed);
    defer startup_graph.deinit(allocator);
    if (startup_graph.manifest_set) |*manifest_set| {
        if (startup_manifest_registry_snapshot.*) |old| allocator.free(old);
        startup_manifest_registry_snapshot.* = try manifest_set.registrySnapshotJson(allocator);
    }
    const extensions = if (startup_graph.has_manifests) startup_graph.ordered_extensions else options.extensions;

    for (extensions) |extension| {
        try appendSingleExtensionTools(
            allocator,
            items,
            extension_hosts,
            startup_diagnostics,
            required_startup_failed,
            selection,
            options,
            extension,
        );
    }
}

fn tryLoadNativeExtension(
    allocator: std.mem.Allocator,
    options: ExtensionToolHostOptions,
    extension: resources_mod.LoadedExtension,
    approved_capabilities: []const capability.Capability,
    policy_lookup_key: ?[]const u8,
) !?extension_runtime.RuntimeAdapter {
    const manifest_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(extension.path) orelse ".", "pi-extension.json" });
    defer allocator.free(manifest_path);

    const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), options.io.?, manifest_path, allocator, .limited(256 * 1024)) catch return null;
    defer allocator.free(manifest_text);

    const manifest_result = try extension_manifest.parseManifestText(allocator, std.fs.path.dirname(manifest_path) orelse ".", manifest_path, manifest_text);
    if (manifest_result != .valid) {
        var result = manifest_result;
        result.deinit(allocator);
        return null;
    }
    defer {
        var result = manifest_result;
        result.deinit(allocator);
    }

    if (manifest_result.valid.runtime_kind != .native) return null;

    const host = try native_extension_loader.loadNativeFromManifest(
        allocator,
        options.io.?,
        manifest_result.valid,
        approved_capabilities,
        policy_lookup_key,
    );
    return host;
}

fn awaitHostReadyOrDiagnose(
    allocator: std.mem.Allocator,
    host: extension_runtime.RuntimeAdapter,
    startup_diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    required_startup_failed: *bool,
    extension: resources_mod.LoadedExtension,
    policy: ExtensionStartupPolicy,
    message_prefix: []const u8,
) !bool {
    host.waitForReady(policy.startup_timeout_ms) catch |err| {
        const message = try std.fmt.allocPrint(
            allocator,
            "{s}startup timed out or failed before ready after {d}ms: {s}",
            .{ message_prefix, policy.startup_timeout_ms, @errorName(err) },
        );
        defer allocator.free(message);
        try appendExtensionStartupDiagnostic(
            allocator,
            startup_diagnostics,
            .@"error",
            "startup",
            extension,
            policy.policy_key,
            policy.required,
            message,
        );
        if (policy.required) required_startup_failed.* = true;
        return false;
    };
    return true;
}

fn collectExtensionToolsIntoItems(
    allocator: std.mem.Allocator,
    host: extension_runtime.RuntimeAdapter,
    items: *std.ArrayList(agent.AgentTool),
    startup_diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    selection: tool_selection_mod.ToolSelection,
    options: ExtensionToolHostOptions,
    extension: resources_mod.LoadedExtension,
    policy: ExtensionStartupPolicy,
) !void {
    drainExtensionRegistryFrames(host, options.env_map, options.io.?);
    try appendHostDiagnostics(
        allocator,
        startup_diagnostics,
        host,
        extension,
        policy.policy_key,
        policy.required,
    );

    var names = ToolNameCollector{ .allocator = allocator };
    defer names.deinit();
    try host.withRegistry(&names, collectToolNames);

    for (names.items.items) |name| {
        if (!selection.allowsExtension(name)) continue;
        if (hasActiveExtensionToolName(items.items, name)) {
            const message = try std.fmt.allocPrint(allocator, "duplicate extension tool name skipped: {s}", .{name});
            defer allocator.free(message);
            try appendExtensionStartupDiagnostic(
                allocator,
                startup_diagnostics,
                .warning,
                "registry",
                extension,
                policy.policy_key,
                policy.required,
                message,
            );
            continue;
        }
        if (try host.agentTool(allocator, name)) |tool| {
            try items.append(allocator, tool);
        }
    }
}

fn appendSingleExtensionTools(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    extension_hosts: *std.ArrayList(extension_runtime.RuntimeAdapter),
    startup_diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    required_startup_failed: *bool,
    selection: tool_selection_mod.ToolSelection,
    options: ExtensionToolHostOptions,
    extension: resources_mod.LoadedExtension,
) !void {
    var policy = try resolveExtensionStartupPolicy(allocator, options, extension);
    defer policy.deinit(allocator);
    if (!policy.approved) {
        try appendExtensionStartupDiagnostic(
            allocator,
            startup_diagnostics,
            .warning,
            "policy",
            extension,
            policy.policy_key,
            policy.required,
            policy.reason,
        );
        if (policy.required) required_startup_failed.* = true;
        return;
    }

    // Try manifest-based native loading first
    const maybe_native_host = tryLoadNativeExtension(allocator, options, extension, policy.approved_capabilities, policy.policy_key) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        // Native load failed for non-OOM reasons; fall through to process_jsonl.
        break :blk null;
    };
    if (maybe_native_host) |host| {
        var host_owned = true;
        errdefer if (host_owned) host.deinit();

        const ready = try awaitHostReadyOrDiagnose(
            allocator,
            host,
            startup_diagnostics,
            required_startup_failed,
            extension,
            policy,
            "native extension ",
        );
        if (!ready) {
            host.deinit();
            host_owned = false;
            return;
        }

        try collectExtensionToolsIntoItems(
            allocator,
            host,
            items,
            startup_diagnostics,
            selection,
            options,
            extension,
            policy,
        );

        try extension_hosts.append(allocator, host);
        host_owned = false;
        return;
    }

    var host = startProcessJsonlToolHost(allocator, options, extension, policy) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "extension startup failed: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try appendExtensionStartupDiagnostic(
            allocator,
            startup_diagnostics,
            .@"error",
            "startup",
            extension,
            policy.policy_key,
            policy.required,
            message,
        );
        if (policy.required) required_startup_failed.* = true;
        return;
    };
    var host_owned = true;
    errdefer if (host_owned) host.deinit();

    const ready = try awaitHostReadyOrDiagnose(
        allocator,
        host,
        startup_diagnostics,
        required_startup_failed,
        extension,
        policy,
        "extension ",
    );
    if (!ready) {
        host.deinit();
        host_owned = false;
        return;
    }

    try collectExtensionToolsIntoItems(
        allocator,
        host,
        items,
        startup_diagnostics,
        selection,
        options,
        extension,
        policy,
    );

    try extension_hosts.append(allocator, host);
    host_owned = false;
}

const ExtensionContributionContext = struct {
    allocator: std.mem.Allocator,
    extensions: []const resources_mod.LoadedExtension,
    provider_names: std.ArrayList([]u8) = .empty,
    provider_candidates: std.ArrayList(ProviderCandidate) = .empty,
    provider_diagnostics: std.ArrayList(ProviderCollisionDiagnostic) = .empty,
    resource_discoveries: std.ArrayList(resources_mod.ExtensionDiscoveredResources) = .empty,

    fn deinitScratch(self: *ExtensionContributionContext) void {
        for (self.provider_names.items) |name| self.allocator.free(name);
        self.provider_names.deinit(self.allocator);
        self.deinitProviderCandidates();
        for (self.provider_diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.provider_diagnostics.deinit(self.allocator);
        for (self.resource_discoveries.items) |*discovery| {
            self.allocator.free(@constCast(discovery.extension_path));
            discovery.source_info.deinit(self.allocator);
            freeStringConstList(self.allocator, discovery.skill_paths);
            freeStringConstList(self.allocator, discovery.prompt_paths);
            freeStringConstList(self.allocator, discovery.theme_paths);
        }
        self.resource_discoveries.deinit(self.allocator);
    }

    fn deinitProviderCandidates(self: *ExtensionContributionContext) void {
        for (self.provider_candidates.items) |*candidate| candidate.deinit(self.allocator);
        self.provider_candidates.deinit(self.allocator);
        self.provider_candidates = .empty;
    }
};

const ProviderCandidate = struct {
    name: []u8,
    display_name: ?[]u8,
    base_url: ?[]u8,
    api: ?[]u8,
    models: []extension_registry.ProviderModel,
    extension_path: []u8,
    source_path: []u8,

    fn deinit(self: *ProviderCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.display_name) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
        if (self.api) |value| allocator.free(value);
        for (self.models) |*model| model.deinit(allocator);
        allocator.free(self.models);
        allocator.free(self.extension_path);
        allocator.free(self.source_path);
        self.* = undefined;
    }
};

fn collectRegistryContributions(context_ptr: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const context: *ExtensionContributionContext = @ptrCast(@alignCast(context_ptr.?));
    for (registry.providers.items) |provider| {
        try appendExtensionProviderCandidate(context, provider);
    }
    for (registry.resource_discoveries.items) |discovery| {
        try appendExtensionResourceDiscovery(context, discovery);
    }
}

fn appendExtensionProviderCandidate(context: *ExtensionContributionContext, provider: extension_registry.ExtensionProvider) !void {
    if (provider.name.len == 0) return;
    const source_path = if (findLoadedExtensionForPath(context.extensions, provider.extension_path)) |extension|
        extension.source_info.path
    else
        provider.extension_path;

    var models = try context.allocator.alloc(extension_registry.ProviderModel, provider.models.len);
    var initialized: usize = 0;
    errdefer {
        for (models[0..initialized]) |*model| model.deinit(context.allocator);
        context.allocator.free(models);
    }
    for (provider.models, 0..) |model, index| {
        models[index] = .{
            .id = try context.allocator.dupe(u8, model.id),
            .name = try context.allocator.dupe(u8, model.name),
        };
        initialized = index + 1;
    }

    const candidate = ProviderCandidate{
        .name = try context.allocator.dupe(u8, provider.name),
        .display_name = if (provider.display_name) |value| try context.allocator.dupe(u8, value) else null,
        .base_url = if (provider.base_url) |value| try context.allocator.dupe(u8, value) else null,
        .api = if (provider.api) |value| try context.allocator.dupe(u8, value) else null,
        .models = models,
        .extension_path = try context.allocator.dupe(u8, provider.extension_path),
        .source_path = try context.allocator.dupe(u8, source_path),
    };
    try context.provider_candidates.append(context.allocator, candidate);
}

fn activateExtensionProviderCandidates(context: *ExtensionContributionContext) !void {
    for (context.provider_candidates.items) |candidate| {
        if (isBuiltInProvider(candidate.name)) {
            try appendProviderCollisionDiagnostic(
                context,
                "extension_provider.builtin_collision",
                candidate,
                "builtin_provider",
                candidate.name,
            );
            continue;
        }

        if (providerCandidateNameCount(context.provider_candidates.items, candidate.name) > 1) {
            const conflict_with = try duplicateProviderConflictList(context.allocator, context.provider_candidates.items, candidate.name);
            defer context.allocator.free(conflict_with);
            try appendProviderCollisionDiagnostic(
                context,
                "extension_provider.duplicate_id",
                candidate,
                "duplicate_extension_provider",
                conflict_with,
            );
            continue;
        }

        try registerExtensionProvider(context, candidate);
    }
}

fn registerExtensionProvider(context: *ExtensionContributionContext, provider: ProviderCandidate) !void {
    const api = provider.api orelse "openai-completions";
    const base_url = provider.base_url orelse "http://localhost:0";
    const default_model_id = if (provider.models.len > 0) provider.models[0].id else provider.name;
    try ai.model_registry.registerProvider(.{
        .provider = provider.name,
        .api = api,
        .base_url = base_url,
        .default_model_id = default_model_id,
    });

    if (provider.models.len == 0) {
        try ai.model_registry.registerModel(.{
            .id = provider.name,
            .name = provider.display_name orelse provider.name,
            .api = api,
            .provider = provider.name,
            .base_url = base_url,
            .input_types = &[_][]const u8{"text"},
            .context_window = 8192,
            .max_tokens = 4096,
        });
    } else {
        for (provider.models) |model| {
            try ai.model_registry.registerModel(.{
                .id = model.id,
                .name = model.name,
                .api = api,
                .provider = provider.name,
                .base_url = base_url,
                .input_types = &[_][]const u8{"text"},
                .context_window = 8192,
                .max_tokens = 4096,
            });
        }
    }

    if (!containsOwnedString(context.provider_names.items, provider.name)) {
        try context.provider_names.append(context.allocator, try context.allocator.dupe(u8, provider.name));
    }
}

fn appendProviderCollisionDiagnostic(
    context: *ExtensionContributionContext,
    code: []const u8,
    provider: ProviderCandidate,
    conflict_kind: []const u8,
    conflict_with: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "extension provider collision providerId={s} extensionPath={s} source={s} conflictKind={s} conflictWith={s}; skipped provider activation",
        .{ provider.name, provider.extension_path, provider.source_path, conflict_kind, conflict_with },
    );
    errdefer context.allocator.free(message);
    try context.provider_diagnostics.append(context.allocator, .{
        .code = try context.allocator.dupe(u8, code),
        .severity = try context.allocator.dupe(u8, "warning"),
        .provider_id = try context.allocator.dupe(u8, provider.name),
        .extension_path = try context.allocator.dupe(u8, provider.extension_path),
        .source_path = try context.allocator.dupe(u8, provider.source_path),
        .conflict_kind = try context.allocator.dupe(u8, conflict_kind),
        .conflict_with = try context.allocator.dupe(u8, conflict_with),
        .message = message,
    });
}

fn providerCandidateNameCount(candidates: []const ProviderCandidate, name: []const u8) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) count += 1;
    }
    return count;
}

fn duplicateProviderConflictList(
    allocator: std.mem.Allocator,
    candidates: []const ProviderCandidate,
    name: []const u8,
) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var first = true;
    for (candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.name, name)) continue;
        if (!first) try list.writer.writeAll(",");
        first = false;
        try list.writer.writeAll(candidate.extension_path);
    }
    return try allocator.dupe(u8, list.written());
}

fn appendExtensionResourceDiscovery(context: *ExtensionContributionContext, discovery: extension_registry.ResourceDiscovery) !void {
    const extension = findLoadedExtensionForPath(context.extensions, discovery.extension_path) orelse blk: {
        if (context.extensions.len == 0) return;
        break :blk context.extensions[0];
    };
    const extension_path = try context.allocator.dupe(u8, discovery.extension_path);
    errdefer context.allocator.free(extension_path);
    const source_info = try extension.source_info.clone(context.allocator);
    errdefer {
        var mutable_source_info = source_info;
        mutable_source_info.deinit(context.allocator);
    }
    const skill_paths = try cloneStringConstListFromArray(context.allocator, discovery.skill_paths.items);
    errdefer freeStringConstList(context.allocator, skill_paths);
    const prompt_paths = try cloneStringConstListFromArray(context.allocator, discovery.prompt_paths.items);
    errdefer freeStringConstList(context.allocator, prompt_paths);
    const theme_paths = try cloneStringConstListFromArray(context.allocator, discovery.theme_paths.items);
    errdefer freeStringConstList(context.allocator, theme_paths);
    try context.resource_discoveries.append(context.allocator, .{
        .extension_path = extension_path,
        .source_info = source_info,
        .skill_paths = skill_paths,
        .prompt_paths = prompt_paths,
        .theme_paths = theme_paths,
    });
}

fn isBuiltInProvider(provider: []const u8) bool {
    for (ai.model_registry.builtInProviderConfigs()) |config| {
        if (std.mem.eql(u8, config.provider, provider)) return true;
    }
    return false;
}

fn containsOwnedString(values: []const []u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn findLoadedExtensionForPath(extensions: []const resources_mod.LoadedExtension, path: []const u8) ?resources_mod.LoadedExtension {
    for (extensions) |extension| {
        if (std.mem.eql(u8, extension.path, path) or std.mem.eql(u8, extension.source_info.path, path)) return extension;
    }
    return null;
}

fn cloneStringConstListFromArray(allocator: std.mem.Allocator, values: []const []u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const owned = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| allocator.free(value);
        allocator.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try allocator.dupe(u8, value);
        initialized = index + 1;
    }
    return owned;
}

fn freeStringConstList(allocator: std.mem.Allocator, values: []const []const u8) void {
    if (values.len == 0) return;
    for (values) |value| allocator.free(@constCast(value));
    allocator.free(values);
}

const StartupManifestGraph = struct {
    has_manifests: bool = false,
    ordered_extensions: []resources_mod.LoadedExtension = &.{},
    manifest_set: ?extension_manifest.ManifestSet = null,
    manifest_extension_indices: []usize = &.{},

    fn deinit(self: *StartupManifestGraph, allocator: std.mem.Allocator) void {
        if (self.manifest_set) |*set| set.deinit(allocator);
        if (self.manifest_extension_indices.len > 0) allocator.free(self.manifest_extension_indices);
        if (self.ordered_extensions.len > 0) allocator.free(self.ordered_extensions);
        self.* = undefined;
    }
};

const StartupManifestSource = struct {
    source: extension_manifest.ManifestSource,
    extension_index: usize,
    package_root_owned: []u8,
    manifest_path_owned: []u8,
    manifest_text_owned: []u8,

    fn deinit(self: *StartupManifestSource, allocator: std.mem.Allocator) void {
        allocator.free(self.package_root_owned);
        allocator.free(self.manifest_path_owned);
        allocator.free(self.manifest_text_owned);
        self.* = undefined;
    }
};

fn resolveStartupManifestGraph(
    allocator: std.mem.Allocator,
    options: ExtensionToolHostOptions,
    startup_diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    required_startup_failed: *bool,
) !StartupManifestGraph {
    var sources = std.ArrayList(StartupManifestSource).empty;
    defer {
        for (sources.items) |*source| source.deinit(allocator);
        sources.deinit(allocator);
    }

    for (options.extensions, 0..) |extension, index| {
        if (try startupManifestSourceForExtension(allocator, options.io.?, extension, index)) |source| {
            try sources.append(allocator, source);
        }
    }
    if (sources.items.len == 0) return .{};

    var manifest_sources = try allocator.alloc(extension_manifest.ManifestSource, sources.items.len);
    defer allocator.free(manifest_sources);
    var manifest_extension_indices = try allocator.alloc(usize, sources.items.len);
    errdefer allocator.free(manifest_extension_indices);
    for (sources.items, 0..) |source, index| {
        manifest_sources[index] = source.source;
        manifest_extension_indices[index] = source.extension_index;
    }

    var manifest_set = try extension_manifest.resolveManifestSources(allocator, manifest_sources);
    errdefer manifest_set.deinit(allocator);
    try appendManifestSetStartupDiagnostics(
        allocator,
        options.extensions,
        sources.items,
        manifest_extension_indices,
        manifest_set,
        startup_diagnostics,
        required_startup_failed,
    );

    const activation_indices = try extension_manifest.activationOrderIndices(allocator, manifest_set.records);
    defer allocator.free(activation_indices);
    var ordered = std.ArrayList(resources_mod.LoadedExtension).empty;
    errdefer ordered.deinit(allocator);
    var included = try allocator.alloc(bool, options.extensions.len);
    defer allocator.free(included);
    @memset(included, false);

    for (activation_indices) |record_index| {
        if (record_index >= manifest_extension_indices.len) continue;
        const extension_index = manifest_extension_indices[record_index];
        if (extension_index >= options.extensions.len or included[extension_index]) continue;
        included[extension_index] = true;
        try ordered.append(allocator, options.extensions[extension_index]);
    }
    for (options.extensions, 0..) |extension, index| {
        if (startupManifestIndexForExtension(manifest_extension_indices, index) != null) continue;
        if (included[index]) continue;
        included[index] = true;
        try ordered.append(allocator, extension);
    }

    return .{
        .has_manifests = true,
        .ordered_extensions = try ordered.toOwnedSlice(allocator),
        .manifest_set = manifest_set,
        .manifest_extension_indices = manifest_extension_indices,
    };
}

fn startupManifestSourceForExtension(
    allocator: std.mem.Allocator,
    io: std.Io,
    extension: resources_mod.LoadedExtension,
    extension_index: usize,
) !?StartupManifestSource {
    const package_root = startupManifestPackageRoot(extension) orelse return null;
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, "pi-extension.json" });
    errdefer allocator.free(manifest_path);
    if (!pathExists(io, manifest_path)) {
        allocator.free(manifest_path);
        return null;
    }
    const manifest_text = try std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .unlimited);
    errdefer allocator.free(manifest_text);
    const package_root_owned = try allocator.dupe(u8, package_root);
    errdefer allocator.free(package_root_owned);
    return .{
        .source = .{
            .package_root = package_root_owned,
            .manifest_path = manifest_path,
            .manifest_text = manifest_text,
            .source_scope = sourceScopeName(extension.source_info),
            .precedence_rank = extensionPrecedenceRank(extension),
        },
        .extension_index = extension_index,
        .package_root_owned = package_root_owned,
        .manifest_path_owned = manifest_path,
        .manifest_text_owned = manifest_text,
    };
}

fn startupManifestPackageRoot(extension: resources_mod.LoadedExtension) ?[]const u8 {
    if (extension.source_info.origin == .package) {
        if (extension.source_info.base_dir) |base_dir| {
            if (base_dir.len > 0) return base_dir;
        }
    }
    return std.fs.path.dirname(extension.path);
}

fn appendManifestSetStartupDiagnostics(
    allocator: std.mem.Allocator,
    extensions: []const resources_mod.LoadedExtension,
    sources: []const StartupManifestSource,
    manifest_extension_indices: []const usize,
    manifest_set: extension_manifest.ManifestSet,
    startup_diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    required_startup_failed: *bool,
) !void {
    for (manifest_set.diagnostics) |diagnostic| {
        const extension = extensionForManifestDiagnostic(extensions, manifest_extension_indices, manifest_set.records, diagnostic) orelse
            extensionForManifestSourceDiagnostic(extensions, sources, diagnostic) orelse continue;
        const severity: ExtensionStartupSeverity = if (std.mem.eql(u8, diagnostic.code, "graph.policy_denied_capability_candidate")) .warning else .@"error";
        try appendManifestStartupDiagnostic(allocator, startup_diagnostics, severity, "graph", extension, diagnostic, false);
    }

    for (manifest_set.records, 0..) |record, record_index| {
        const extension_index = if (record_index < manifest_extension_indices.len) manifest_extension_indices[record_index] else continue;
        if (extension_index >= extensions.len) continue;
        const extension = extensions[extension_index];
        for (record.manifest.diagnostics) |diagnostic| {
            try appendManifestStartupDiagnostic(allocator, startup_diagnostics, .warning, "manifest", extension, diagnostic, manifestRequired(record));
        }
        if (!record.active) {
            const reason = record.inactive_reason orelse "inactive";
            const message = try std.fmt.allocPrint(
                allocator,
                "extension graph rejected packageId={s} reason={s}",
                .{ record.manifest.id, reason },
            );
            defer allocator.free(message);
            const synthetic = extension_manifest.Diagnostic{
                .code = try allocator.dupe(u8, "graph.inactive_package"),
                .path = try allocator.dupe(u8, "$"),
                .message = try allocator.dupe(u8, message),
                .manifest_path = try allocator.dupe(u8, record.manifest.manifest_path),
                .severity = try allocator.dupe(u8, "error"),
                .phase = try allocator.dupe(u8, "graph"),
                .correlation_id = try std.fmt.allocPrint(allocator, "manifest:{s}", .{record.manifest.manifest_path}),
                .span_id = try allocator.dupe(u8, "graph.inactive_package:$"),
                .package_id = try allocator.dupe(u8, record.manifest.id),
                .runtime = try allocator.dupe(u8, record.manifest.runtime_kind.jsonName()),
            };
            var owned_synthetic = synthetic;
            defer owned_synthetic.deinit(allocator);
            const required = manifestRequired(record);
            try appendManifestStartupDiagnostic(allocator, startup_diagnostics, .@"error", "graph", extension, owned_synthetic, required);
            if (required) required_startup_failed.* = true;
        }
    }
}

fn appendManifestStartupDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    severity: ExtensionStartupSeverity,
    phase: []const u8,
    extension: resources_mod.LoadedExtension,
    diagnostic: extension_manifest.Diagnostic,
    required: bool,
) !void {
    try diagnostics.append(allocator, .{
        .severity = severity,
        .phase = try allocator.dupe(u8, phase),
        .extension_id = try allocator.dupe(u8, extension.source_info.path),
        .extension_path = try allocator.dupe(u8, extension.path),
        .source_path = try allocator.dupe(u8, extension.source_info.path),
        .required = required,
        .message = try std.fmt.allocPrint(
            allocator,
            "extension lifecycle extensionId={s} phase={s} severity={s} required={any} path={s} source={s}: manifest diagnostic code={s} manifest={s} jsonPath={s}: {s}",
            .{ extension.source_info.path, phase, severity.jsonName(), required, extension.path, extension.source_info.path, diagnostic.code, diagnostic.manifest_path, diagnostic.path, diagnostic.message },
        ),
    });
}

fn extensionForManifestDiagnostic(
    extensions: []const resources_mod.LoadedExtension,
    manifest_extension_indices: []const usize,
    records: []const extension_manifest.ManifestRecord,
    diagnostic: extension_manifest.Diagnostic,
) ?resources_mod.LoadedExtension {
    for (records, 0..) |record, index| {
        if (!std.mem.eql(u8, record.manifest.manifest_path, diagnostic.manifest_path)) continue;
        if (index >= manifest_extension_indices.len) return null;
        const extension_index = manifest_extension_indices[index];
        if (extension_index >= extensions.len) return null;
        return extensions[extension_index];
    }
    return null;
}

fn extensionForManifestSourceDiagnostic(
    extensions: []const resources_mod.LoadedExtension,
    sources: []const StartupManifestSource,
    diagnostic: extension_manifest.Diagnostic,
) ?resources_mod.LoadedExtension {
    for (sources) |source| {
        if (!std.mem.eql(u8, source.source.manifest_path, diagnostic.manifest_path)) continue;
        if (source.extension_index >= extensions.len) return null;
        return extensions[source.extension_index];
    }
    return null;
}

fn startupManifestIndexForExtension(manifest_extension_indices: []const usize, extension_index: usize) ?usize {
    for (manifest_extension_indices, 0..) |candidate, index| {
        if (candidate == extension_index) return index;
    }
    return null;
}

fn manifestRequired(record: extension_manifest.ManifestRecord) bool {
    if (record.manifest.lifecycle != .object) return false;
    const value = record.manifest.lifecycle.object.get("required") orelse return false;
    return value == .bool and value.bool;
}

fn sourceScopeName(source_info: resources_mod.SourceInfo) []const u8 {
    return switch (source_info.scope) {
        .temporary => "cli",
        .project => "project",
        .user => "user",
    };
}

fn extensionPrecedenceRank(extension: resources_mod.LoadedExtension) u16 {
    if (extension.source_info.scope == .temporary) return 0;
    if (extension.source_info.origin == .package) return 5;
    if (extension.source_info.scope == .project) {
        if (std.mem.eql(u8, extension.source_info.source, "local")) return 1;
        return 2;
    }
    if (std.mem.eql(u8, extension.source_info.source, "local")) return 3;
    return 4;
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn appendHostDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    host: extension_runtime.RuntimeAdapter,
    extension: resources_mod.LoadedExtension,
    policy_key: ?[]const u8,
    required: bool,
) !void {
    const parse_categories = [_]extension_runtime.DiagnosticCategory{
        .blank_frame,
        .malformed_json,
        .non_object_frame,
        .unsupported_message_type,
        .incomplete_frame,
    };
    for (parse_categories) |category| {
        const count = host.diagnosticCategoryCount(category);
        if (count == 0) continue;
        const message = try std.fmt.allocPrint(
            allocator,
            "extension host parse diagnostic category={s} count={d}",
            .{ category.jsonName(), count },
        );
        defer allocator.free(message);
        try appendExtensionStartupDiagnostic(
            allocator,
            diagnostics,
            .warning,
            "parse",
            extension,
            policy_key,
            required,
            message,
        );
    }

    const runtime_categories = [_]extension_runtime.DiagnosticCategory{
        .startup_failure,
        .host_error,
        .host_exit,
    };
    for (runtime_categories) |category| {
        const count = host.diagnosticCategoryCount(category);
        if (count == 0) continue;
        const message = try std.fmt.allocPrint(
            allocator,
            "extension host runtime diagnostic category={s} count={d}",
            .{ category.jsonName(), count },
        );
        defer allocator.free(message);
        try appendExtensionStartupDiagnostic(
            allocator,
            diagnostics,
            .@"error",
            "runtime",
            extension,
            policy_key,
            required,
            message,
        );
    }
}

fn hasActiveExtensionToolName(items: []const agent.AgentTool, name: []const u8) bool {
    for (items) |item| {
        if (item.source == .extension and std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

const ExtensionStartupPolicy = struct {
    approved: bool,
    required: bool,
    startup_timeout_ms: u64,
    approved_capabilities: []enforcement.Grant = &.{},
    resource_limits: enforcement.ResourceLimits = .{},
    policy_key: ?[]u8 = null,
    reason: []u8,

    fn deinit(self: *ExtensionStartupPolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.approved_capabilities);
        if (self.policy_key) |policy_key| allocator.free(policy_key);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

fn resolveExtensionStartupPolicy(
    allocator: std.mem.Allocator,
    options: ExtensionToolHostOptions,
    extension: resources_mod.LoadedExtension,
) !ExtensionStartupPolicy {
    const default_timeout_ms = parseEnvU64(options.env_map, "PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", 1500);
    const runtime_config = options.runtime_config orelse return .{
        .approved = true,
        .required = false,
        .startup_timeout_ms = default_timeout_ms,
        .approved_capabilities = try allocator.dupe(enforcement.Grant, enforcement.CANONICAL_GRANTS[0..]),
        .reason = try allocator.dupe(u8, "extension startup policy not configured; preserving legacy test/runtime behavior"),
    };

    const policy_key = try extension_runtime.typeScriptPolicyLookupKey(allocator, .{
        .configured_path = extension.source_info.path,
        .resolved_path = extension.path,
        .source_info = extension.source_info,
    });
    errdefer allocator.free(policy_key);

    const policy = runtime_config.getExtensionPolicy(policy_key) orelse {
        return .{
            .approved = false,
            .required = false,
            .startup_timeout_ms = default_timeout_ms,
            .policy_key = policy_key,
            .reason = try allocator.dupe(u8, "extension is unapproved; no matching extensionPolicies entry"),
        };
    };

    const required = policy.required orelse false;
    const timeout_ms = if (policy.resource_limits) |limits|
        limits.timeout_ms orelse default_timeout_ms
    else
        default_timeout_ms;
    const resource_limits = extension_runtime.enforcementResourceLimitsFromExtensionPolicy(policy.resource_limits);

    if (policy.enabled) |enabled| {
        if (!enabled) {
            return .{
                .approved = false,
                .required = required,
                .startup_timeout_ms = timeout_ms,
                .policy_key = policy_key,
                .reason = try allocator.dupe(u8, "extension is denied by policy"),
            };
        }
    }

    if (policy.approved) |approved| {
        if (!approved) {
            return .{
                .approved = false,
                .required = required,
                .startup_timeout_ms = timeout_ms,
                .policy_key = policy_key,
                .reason = try allocator.dupe(u8, "extension is denied by policy"),
            };
        }
        const approved_capabilities = if (policy.approved_grants) |_|
            try extension_runtime.approvedCapabilitiesFromExtensionPolicy(allocator, policy)
        else
            try allocator.dupe(enforcement.Grant, enforcement.CANONICAL_GRANTS[0..]);
        return .{
            .approved = true,
            .required = required,
            .startup_timeout_ms = timeout_ms,
            .approved_capabilities = approved_capabilities,
            .resource_limits = resource_limits,
            .policy_key = policy_key,
            .reason = try allocator.dupe(u8, "extension is approved by policy"),
        };
    }

    if (!hasApprovedGrant(policy.approved_grants, "tool.use")) {
        return .{
            .approved = false,
            .required = required,
            .startup_timeout_ms = timeout_ms,
            .policy_key = policy_key,
            .reason = try allocator.dupe(u8, "extension is denied by policy; approvedGrants does not include tool.use"),
        };
    }

    return .{
        .approved = true,
        .required = required,
        .startup_timeout_ms = timeout_ms,
        .approved_capabilities = try extension_runtime.approvedCapabilitiesFromExtensionPolicy(allocator, policy),
        .resource_limits = resource_limits,
        .policy_key = policy_key,
        .reason = try allocator.dupe(u8, "extension is approved by policy"),
    };
}

fn hasApprovedGrant(grants: ?[]const []const u8, expected: []const u8) bool {
    const values = grants orelse return false;
    for (values) |grant| {
        if (std.mem.eql(u8, grant, expected)) return true;
    }
    return false;
}

fn appendExtensionStartupDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(ExtensionStartupDiagnostic),
    severity: ExtensionStartupSeverity,
    phase: []const u8,
    extension: resources_mod.LoadedExtension,
    policy_key: ?[]const u8,
    required: bool,
    message: []const u8,
) !void {
    const extension_id = if (policy_key) |value| value else extension.source_info.path;
    try diagnostics.append(allocator, .{
        .severity = severity,
        .phase = try allocator.dupe(u8, phase),
        .extension_id = try allocator.dupe(u8, extension_id),
        .extension_path = try allocator.dupe(u8, extension.path),
        .source_path = try allocator.dupe(u8, extension.source_info.path),
        .policy_key = if (policy_key) |value| try allocator.dupe(u8, value) else null,
        .required = required,
        .message = try std.fmt.allocPrint(
            allocator,
            "extension lifecycle extensionId={s} phase={s} severity={s} required={any} path={s} source={s}: {s}",
            .{ extension_id, phase, severity.jsonName(), required, extension.path, extension.source_info.path, message },
        ),
    });
}

fn deinitExtensionStartupDiagnostics(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(ExtensionStartupDiagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
    diagnostics.deinit(allocator);
}

fn startProcessJsonlToolHost(
    allocator: std.mem.Allocator,
    options: ExtensionToolHostOptions,
    extension: resources_mod.LoadedExtension,
    policy: ExtensionStartupPolicy,
) !extension_runtime.RuntimeAdapter {
    const env_map = options.env_map;
    const runtime = envValue(env_map, "PI_M1_EXTENSION_HOST_RUNTIME") orelse
        envValue(env_map, "PI_M11_EXTENSION_HOST_RUNTIME") orelse
        "bun";
    const marker = envValue(env_map, "PI_M1_EXTENSION_HOST_MARKER") orelse "pi-m1-process-jsonl-tool-host";
    const fixture = envValue(env_map, "PI_M1_EXTENSION_HOST_FIXTURE") orelse "m1-process-jsonl-tools";
    const shutdown_timeout_ms = parseEnvU64(env_map, "PI_M1_EXTENSION_SHUTDOWN_TIMEOUT_MS", 1000);

    const argv = [_][]const u8{ runtime, extension.path, marker };
    return try extension_runtime.startRuntimeAdapter(allocator, options.io.?, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = if (options.cwd.len > 0) options.cwd else null,
        .extension_path = extension.path,
        .initialize = .{
            .marker = marker,
            .cwd = options.cwd,
            .fixture = fixture,
        },
        .shutdown_timeout_ms = shutdown_timeout_ms,
        .approved_capabilities = policy.approved_capabilities,
        .resource_limits = policy.resource_limits,
        .policy_lookup_key = policy.policy_key,
    } });
}

fn drainExtensionRegistryFrames(
    host: extension_runtime.RuntimeAdapter,
    env_map: ?*const std.process.Environ.Map,
    io: std.Io,
) void {
    const drain_timeout_ms = parseEnvU64(env_map, "PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", 1500);
    const tick_ms: u64 = 10;
    var elapsed: u64 = 0;
    var quiet: u64 = 0;
    var last_count = host.registryFramesApplied();
    while (elapsed < drain_timeout_ms) : (elapsed += tick_ms) {
        const cur = host.registryFramesApplied();
        if (cur != last_count) {
            last_count = cur;
            quiet = 0;
        } else {
            quiet += tick_ms;
            if (quiet >= 100 and last_count != 0) break;
        }
        std.Io.sleep(io, .fromMilliseconds(@intCast(tick_ms)), .awake) catch {};
    }
}

const ToolNameCollector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ToolNameCollector) void {
        for (self.items.items) |name| self.allocator.free(name);
        self.items.deinit(self.allocator);
    }
};

fn collectToolNames(context: ?*anyopaque, registry: *const extension_runtime.Registry) !void {
    const collector: *ToolNameCollector = @ptrCast(@alignCast(context.?));
    for (registry.tools.items) |tool| {
        try collector.items.append(collector.allocator, try collector.allocator.dupe(u8, tool.name));
    }
}

fn envValue(env_map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const map = env_map orelse return null;
    return map.get(key);
}

fn parseEnvU64(env_map: ?*const std.process.Environ.Map, key: []const u8, default_value: u64) u64 {
    const value = envValue(env_map, key) orelse return default_value;
    return std.fmt.parseInt(u64, value, 10) catch default_value;
}

fn getAppContext(tool_context: ?*anyopaque) !*AppContext {
    return @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
}

/// Derived built-in tool executor table.
///
/// Each entry in `tools.ALL` either uses the default adapter (parse args via
/// reflection, call `T.init(cwd, io).execute(allocator, args)`, surface
/// `result.content`) or opts out by declaring
/// `pub const use_default_adapter = false;` on the tool type. Opt-out tools
/// keep their hand-written wrapper below and must be wired into
/// `customExecutorFor` so the executor table stays in lockstep with
/// `tools.ALL`.
const BUILTIN_TOOL_EXECUTORS = blk: {
    var arr: [tools.ALL.len]agent.types.ExecuteToolFn = undefined;
    var seen_names: [tools.ALL.len][]const u8 = undefined;
    for (tools.ALL, 0..) |T, i| {
        for (seen_names[0..i]) |existing| {
            if (std.mem.eql(u8, existing, T.name)) {
                @compileError("duplicate built-in tool name in tools.ALL: " ++ T.name);
            }
        }
        seen_names[i] = T.name;
        arr[i] = if (@hasDecl(T, "use_default_adapter") and !T.use_default_adapter)
            customExecutorFor(T)
        else
            defaultToolAdapter(T);
    }
    break :blk arr;
};

fn customExecutorFor(comptime T: type) agent.types.ExecuteToolFn {
    if (T == tools.BashTool) return runBashTool;
    if (T == tools.EditTool) return runEditTool;
    @compileError("Tool " ++ T.name ++ " opts out of the default adapter but no custom executor is wired in customExecutorFor.");
}

fn defaultToolAdapter(comptime T: type) agent.types.ExecuteToolFn {
    const ArgsT = @typeInfo(@TypeOf(T.execute)).@"fn".params[2].type.?;
    return struct {
        fn run(
            allocator: std.mem.Allocator,
            _: []const u8,
            params: std.json.Value,
            tool_context: ?*anyopaque,
            _: ?*const std.atomic.Value(bool),
            _: ?*anyopaque,
            _: ?agent.types.AgentToolUpdateCallback,
        ) !agent.AgentToolResult {
            const runtime = (try getAppContext(tool_context)).tool_runtime;
            const args = try tools.parseArgsFromJson(ArgsT, allocator, params);
            const result = try T.init(runtime.cwd, runtime.io).execute(allocator, args);
            return .{ .content = result.content };
        }
    }.run;
}

fn runBashTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = try tools.parseArgsFromJson(tools.BashArgs, allocator, params);
    var update_forward = BashToolUpdateForwardContext{
        .allocator = allocator,
        .downstream_context = on_update_context,
        .downstream = on_update,
    };
    var result = try tools.BashTool.init(runtime.cwd, runtime.io).executeWithUpdates(
        allocator,
        args,
        signal,
        &update_forward,
        forwardBashToolUpdate,
    );
    defer if (result.details) |*details| details.deinit(allocator);
    return .{
        .content = result.content,
        .details = if (result.details) |details| try tools.bash.detailsToJsonValue(allocator, details) else null,
    };
}

pub const BashToolUpdateForwardContext = struct {
    allocator: std.mem.Allocator,
    downstream_context: ?*anyopaque,
    downstream: ?agent.types.AgentToolUpdateCallback,
};

pub fn forwardBashToolUpdate(
    context: ?*anyopaque,
    result: tools.BashExecutionResult,
) !void {
    const forward_context: *BashToolUpdateForwardContext = @ptrCast(@alignCast(context.?));
    const callback = forward_context.downstream orelse return;
    const details = if (result.details) |details_value|
        try tools.bash.detailsToJsonValue(forward_context.allocator, details_value)
    else
        null;
    defer if (details) |details_value| common.deinitJsonValue(forward_context.allocator, details_value);

    const partial = agent.AgentToolResult{
        .content = result.content,
        .details = details,
    };

    try callback(forward_context.downstream_context, partial);
}

fn runEditTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    var parsed_args_storage = try tools.edit.parseArguments(allocator, params);
    defer parsed_args_storage.deinit(allocator);
    const edit_args = parsed_args_storage.toArgs();
    const result = try tools.EditTool.init(runtime.cwd, runtime.io).execute(allocator, edit_args);
    return .{ .content = result.content };
}

test {
    _ = @import("tool_adapters/tests.zig");
}
