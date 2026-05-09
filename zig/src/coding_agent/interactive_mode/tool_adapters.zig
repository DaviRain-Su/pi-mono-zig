const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tools = @import("../tools/root.zig");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
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
const tool_selection_mod = @import("../tool_selection.zig");

const AppContext = shared.AppContext;

pub const BuiltTools = struct {
    allocator: std.mem.Allocator,
    items: []agent.AgentTool,
    locked_wasm_runtimes: ?extension_runtime.LockedWasmRuntimeSet = null,
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

    if (extension_options.include_builtin_tools) {
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.ReadTool.name, tools.ReadTool.description, try tools.ReadTool.schema(allocator), runReadTool);
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.BashTool.name, tools.BashTool.description, try tools.BashTool.schema(allocator), runBashTool);
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.WriteTool.name, tools.WriteTool.description, try tools.WriteTool.schema(allocator), runWriteTool);
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.EditTool.name, tools.EditTool.description, try tools.EditTool.schema(allocator), runEditTool);
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.GrepTool.name, tools.GrepTool.description, try tools.GrepTool.schema(allocator), runGrepTool);
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.FindTool.name, tools.FindTool.description, try tools.FindTool.schema(allocator), runFindTool);
        try appendToolIfEnabled(allocator, &items, app_context, selection, tools.LsTool.name, tools.LsTool.description, try tools.LsTool.schema(allocator), runLsTool);

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
        .extension_hosts = owned_extension_hosts,
        .startup_diagnostics = owned_startup_diagnostics,
        .startup_manifest_registry_snapshot = startup_manifest_registry_snapshot,
        .required_startup_failed = required_startup_failed,
    };
}

fn appendLockedWasmTools(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    runtime_set: *extension_runtime.LockedWasmRuntimeSet,
    selection: tool_selection_mod.ToolSelection,
) !void {
    for (runtime_set.entries) |entry| {
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

fn hasToolName(items: []const agent.AgentTool, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

pub fn writeStartupDiagnostics(stderr: *std.Io.Writer, diagnostics: []const ExtensionStartupDiagnostic) !void {
    for (diagnostics) |diagnostic| {
        const prefix = switch (diagnostic.severity) {
            .info => "Info",
            .warning => "Warning",
            .@"error" => "Error",
        };
        try stderr.print("{s}: {s}\n", .{ prefix, diagnostic.message });
    }
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

    host.waitForReady(policy.startup_timeout_ms) catch |err| {
        const message = try std.fmt.allocPrint(
            allocator,
            "extension startup timed out or failed before ready after {d}ms: {s}",
            .{ policy.startup_timeout_ms, @errorName(err) },
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
        host.deinit();
        host_owned = false;
        if (policy.required) required_startup_failed.* = true;
        return;
    };

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

fn pathExists(io: std.Io, path: []const u8) bool {
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

fn runReadTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.ReadArgs{
        .path = try getRequiredString(params, "path"),
        .offset = getOptionalUsize(params, "offset"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.ReadTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
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
    const args = try tools.bash.parseArguments(params);
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

const BashToolUpdateForwardContext = struct {
    allocator: std.mem.Allocator,
    downstream_context: ?*anyopaque,
    downstream: ?agent.types.AgentToolUpdateCallback,
};

fn forwardBashToolUpdate(
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

fn runWriteTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.WriteArgs{
        .path = try getRequiredString(params, "path"),
        .content = try getRequiredString(params, "content"),
    };
    const result = try tools.WriteTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
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

fn runGrepTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.GrepArgs{
        .pattern = try getRequiredString(params, "pattern"),
        .path = getOptionalString(params, "path"),
        .glob = getOptionalStringEither(params, "glob", "glob_pattern"),
        .ignore_case = getOptionalBoolEither(params, "ignoreCase", "ignore_case") orelse false,
        .literal = getOptionalBool(params, "literal") orelse false,
        .context = getOptionalUsize(params, "context") orelse 0,
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.GrepTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runFindTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.FindArgs{
        .pattern = try getRequiredString(params, "pattern"),
        .path = getOptionalString(params, "path"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.FindTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runLsTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = tools.LsArgs{
        .path = getOptionalString(params, "path"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.LsTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn getRequiredString(value: std.json.Value, key: []const u8) ![]const u8 {
    return getStringObjectValue(value, key) orelse error.InvalidToolArguments;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return getStringObjectValue(value, key);
}

fn getOptionalStringEither(value: std.json.Value, first: []const u8, second: []const u8) ?[]const u8 {
    return getStringObjectValue(value, first) orelse getStringObjectValue(value, second);
}

fn getOptionalBool(value: std.json.Value, key: []const u8) ?bool {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .bool => |bool_value| bool_value,
        else => null,
    };
}

fn getOptionalBoolEither(value: std.json.Value, first: []const u8, second: []const u8) ?bool {
    return getOptionalBool(value, first) orelse getOptionalBool(value, second);
}

fn getOptionalUsize(value: std.json.Value, key: []const u8) ?usize {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .integer => |integer| std.math.cast(usize, integer) orelse null,
        else => null,
    };
}

fn getStringObjectValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .string => |string| string,
        else => null,
    };
}

test "buildAgentTools threads app context into execute callbacks" {
    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentTools(std.testing.allocator, &app_context, &[_][]const u8{ "read", "bash" });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.items.len);
    for (built_tools.items) |tool| {
        try std.testing.expect(tool.execute != null);
        try std.testing.expect(tool.execute_context == @as(?*anyopaque, @ptrCast(&app_context)));
    }
}

test "installed wasm tool conflicts with built-ins emit diagnostic and skip duplicate" {
    const allocator = std.testing.allocator;

    var items = std.ArrayList(agent.AgentTool).empty;
    defer {
        for (items.items) |*item| common.deinitJsonValue(allocator, item.parameters);
        items.deinit(allocator);
    }
    try items.append(allocator, .{
        .name = "read",
        .description = "built-in read",
        .label = "read",
        .parameters = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        .execute = null,
        .execute_context = null,
    });

    var runtime_set = extension_runtime.LockedWasmRuntimeSet{
        .allocator = allocator,
        .entries = try allocator.alloc(extension_runtime.LockedWasmRuntimeEntry, 1),
        .diagnostics = &.{},
    };
    defer runtime_set.deinit();
    runtime_set.entries[0] = .{
        .package_root = try allocator.dupe(u8, "/tmp/conflicting-package"),
        .manifest_path = try allocator.dupe(u8, "/tmp/conflicting-package/pi-extension.json"),
        .tool_id = try allocator.dupe(u8, "read"),
        .policy_lookup_key = try allocator.dupe(u8, "wasm:conflicting-package"),
        .adapter = .{
            .ptr = @ptrFromInt(1),
            .vtable = &conflict_test_vtable,
            .kind = .wasm,
        },
    };

    try appendLockedWasmTools(allocator, &items, &runtime_set, tool_selection_mod.ToolSelection.fromAllowlist(&.{"read"}));

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("read", items.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), runtime_set.diagnostics.len);
    try std.testing.expectEqualStrings("builtin_wasm_tool_conflict", runtime_set.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_set.diagnostics[0].message, "conflicting-package") != null);
}

const conflict_test_vtable: extension_runtime.RuntimeAdapter.VTable = .{
    .wait_for_ready = conflictTestWaitForReady,
    .pending_count = conflictTestPendingCount,
    .diagnostic_count = conflictTestPendingCount,
    .diagnostic_category_count = conflictTestDiagnosticCategoryCount,
    .has_shutdown_complete = conflictTestHasShutdownComplete,
    .registry_frames_applied = conflictTestPendingCount,
    .has_registered_command = conflictTestHasRegisteredCommand,
    .has_registered_hook = conflictTestHasRegisteredHook,
    .snapshot_registry_json = conflictTestSnapshotRegistryJson,
    .with_registry = conflictTestWithRegistry,
    .apply_cli_flag_values = conflictTestApplyCliFlagValues,
    .agent_tool = conflictTestAgentTool,
    .take_ui_requests = conflictTestTakeUiRequests,
    .send_extension_ui_response = conflictTestSendExtensionUiResponse,
    .send_extension_event_frame = conflictTestSendExtensionEventFrame,
    .invoke_extension_event = conflictTestInvokeExtensionEvent,
    .shutdown = conflictTestShutdown,
    .deinit = conflictTestDeinit,
};

fn conflictTestWaitForReady(_: *anyopaque, _: u64) !void {}
fn conflictTestPendingCount(_: *anyopaque) usize {
    return 0;
}
fn conflictTestDiagnosticCategoryCount(_: *anyopaque, _: extension_runtime.DiagnosticCategory) usize {
    return 0;
}
fn conflictTestHasShutdownComplete(_: *anyopaque) bool {
    return true;
}
fn conflictTestHasRegisteredCommand(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn conflictTestHasRegisteredHook(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn conflictTestSnapshotRegistryJson(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{}");
}
fn conflictTestWithRegistry(_: *anyopaque, _: ?*anyopaque, _: extension_runtime.RegistryCallback) !void {}
fn conflictTestApplyCliFlagValues(_: *anyopaque, _: []const extension_registry.ParsedCliFlag) !void {}
fn conflictTestAgentTool(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !?agent.AgentTool {
    return error.UnexpectedBuiltinConflictAgentToolConstruction;
}
fn conflictTestTakeUiRequests(_: *anyopaque, allocator: std.mem.Allocator) ![]extension_runtime.ExtensionUiRequest {
    return allocator.alloc(extension_runtime.ExtensionUiRequest, 0);
}
fn conflictTestSendExtensionUiResponse(_: *anyopaque, _: []const u8, _: []const u8) !void {}
fn conflictTestSendExtensionEventFrame(_: *anyopaque, _: []const u8) void {}
fn conflictTestInvokeExtensionEvent(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: std.json.Value, _: u64) !?std.json.Value {
    return null;
}
fn conflictTestShutdown(_: *anyopaque) !void {}
fn conflictTestDeinit(_: *anyopaque) void {}

test "forwardBashToolUpdate borrows streaming content without freeing it twice" {
    const allocator = std.testing.allocator;

    const Capture = struct {
        allocator: std.mem.Allocator,
        text: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.text) |text| self.allocator.free(text);
        }

        fn collect(context: ?*anyopaque, partial_result: agent.AgentToolResult) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(usize, 1), partial_result.content.len);
            try std.testing.expectEqualStrings("streaming update", partial_result.content[0].text.text);
            self.text = try self.allocator.dupe(u8, partial_result.content[0].text.text);
        }
    };

    var capture = Capture{ .allocator = allocator };
    defer capture.deinit();

    var context = BashToolUpdateForwardContext{
        .allocator = allocator,
        .downstream_context = &capture,
        .downstream = Capture.collect,
    };

    var result = tools.BashExecutionResult{
        .content = try common.makeTextContent(allocator, "streaming update"),
        .details = null,
        .is_error = false,
    };
    defer result.deinit(allocator);

    try forwardBashToolUpdate(&context, result);
    try std.testing.expectEqualStrings("streaming update", capture.text.?);
}

test "buildAgentTools accepts bash timeout alias through the agent adapter" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    try env_map.put("PI_FAUX_TOOL_NAME", "bash");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"command\":\"sleep 5\",\"timeout\":1}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "The command timed out");

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var app_context = AppContext.init(root_dir, std.testing.io);
    var built_tools = try buildAgentTools(allocator, &app_context, &[_][]const u8{"bash"});
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try session.prompt("run bash with alias timeout");

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);

    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, root_dir);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("bash", context.messages[2].tool_result.tool_name);
    try std.testing.expect(context.messages[2].tool_result.details != null);
    const details = context.messages[2].tool_result.details.?.object;
    try std.testing.expectEqual(true, details.get("timed_out").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[2].tool_result.content[0].text.text, "Command timed out after 1 seconds") != null);
}

test "buildAgentToolsWithExtensions exposes process_jsonl tools and preserves call details" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const capture_path = try makeToolAdapterTestPath(allocator, tmp, "extension-tool-capture.jsonl");
    defer allocator.free(capture_path);
    const script_body = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"ext-echo\",\"label\":\"Ext Echo\",\"description\":\"Process echo\",\"parameters\":{{\"type\":\"object\",\"required\":[\"value\"],\"properties\":{{\"value\":{{\"type\":\"string\"}}}},\"additionalProperties\":false}},\"extensionPath\":\"fixture/ext-echo.js\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  printf '%s\\n' \"$line\" >> {s}\n" ++
            "  case \"$line\" in\n" ++
            "    *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;;\n" ++
            "    *'\"toolCallId\":\"tool-ok\"'*) printf '{{\"type\":\"tool_result\",\"toolCallId\":\"tool-ok\",\"content\":[{{\"type\":\"text\",\"text\":\"ok from extension\"}}],\"details\":{{\"source\":\"fixture\"}}}}\\n';;\n" ++
            "    *'\"toolCallId\":\"tool-bad\"'*) printf '{{\"type\":\"tool_error\",\"toolCallId\":\"tool-bad\",\"message\":\"bad from extension\"}}\\n';;\n" ++
            "    *'\"toolCallId\"'*) id=$(printf '%s\\n' \"$line\" | sed -n 's/.*\"toolCallId\":\"\\([^\"]*\\)\".*/\\1/p'); printf '{{\"type\":\"tool_result\",\"toolCallId\":\"%s\",\"content\":[{{\"type\":\"text\",\"text\":\"ok from faux session\"}}],\"details\":{{\"source\":\"fixture-session\"}}}}\\n' \"$id\";;\n" ++
            "  esac\n" ++
            "done\n",
        .{capture_path},
    );
    defer allocator.free(script_body);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ext-echo.js", .data = script_body });
    const extension_path = try makeToolAdapterTestPath(allocator, tmp, "ext-echo.js");
    defer allocator.free(extension_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    const source_path = try allocator.dupe(u8, extension_path);
    defer allocator.free(source_path);
    const source_name = try allocator.dupe(u8, "test");
    defer allocator.free(source_name);
    const base_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(base_dir);

    var app_context = AppContext.init("/tmp", std.testing.io);
    const loaded_extension = resources_mod.LoadedExtension{
        .path = extension_path,
        .source_info = .{
            .path = source_path,
            .source = source_name,
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    };
    var built_tools = try buildAgentToolsWithExtensions(allocator, &app_context, &[_][]const u8{"ext-echo"}, .{
        .extensions = &.{loaded_extension},
        .env_map = &env_map,
        .cwd = "/tmp",
        .io = std.testing.io,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 1), built_tools.items.len);
    const tool = built_tools.items[0];
    try std.testing.expectEqualStrings("ext-echo", tool.name);
    try std.testing.expectEqualStrings("Ext Echo", tool.label);

    var ok_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"ok\"}", .{});
    defer ok_params.deinit();
    const ok = try tool.execute.?(allocator, "tool-ok", ok_params.value, tool.execute_context, null, null, null);
    defer common.deinitContentBlocks(allocator, ok.content);
    defer if (ok.details) |details| common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, false), ok.is_error);
    try std.testing.expectEqualStrings("ok from extension", ok.content[0].text.text);
    try std.testing.expectEqualStrings("fixture", ok.details.?.object.get("source").?.string);
    try std.testing.expectEqualStrings("tool-ok", ok.details.?.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("process_jsonl", ok.details.?.object.get("extension").?.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("ok", ok.details.?.object.get("input").?.object.get("value").?.string);

    var bad_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"bad\"}", .{});
    defer bad_params.deinit();
    const bad = try tool.execute.?(allocator, "tool-bad", bad_params.value, tool.execute_context, null, null, null);
    defer common.deinitContentBlocks(allocator, bad.content);
    defer if (bad.details) |details| common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), bad.is_error);
    try std.testing.expectEqualStrings("bad from extension", bad.content[0].text.text);
    try std.testing.expectEqualStrings("process_jsonl_tool_error", bad.details.?.object.get("code").?.string);

    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":42}", .{});
    defer invalid_params.deinit();
    const invalid = try tool.execute.?(allocator, "tool-invalid", invalid_params.value, tool.execute_context, null, null, null);
    defer common.deinitContentBlocks(allocator, invalid.content);
    defer if (invalid.details) |details| common.deinitJsonValue(allocator, details);
    try std.testing.expectEqual(@as(?bool, true), invalid.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", invalid.content[0].text.text);

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"toolCallId\":\"tool-ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"toolCallId\":\"tool-bad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "tool-invalid") == null);

    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");
    const session_root = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(session_root);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);
    try env_map.put("PI_FAUX_TOOL_NAME", "ext-echo");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"value\":\"from-faux\"}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "final from faux");
    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = session_root,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try session.prompt("call process extension");

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, session_root);
    defer reopened.deinit();
    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("ext-echo", context.messages[2].tool_result.tool_name);
    try std.testing.expectEqual(@as(?bool, false), context.messages[2].tool_result.is_error);
    try std.testing.expectEqualStrings("ok from faux session", context.messages[2].tool_result.content[0].text.text);
    const persisted = context.messages[2].tool_result.details.?.object;
    try std.testing.expectEqualStrings("fixture-session", persisted.get("source").?.string);
    try std.testing.expectEqualStrings("from-faux", persisted.get("input").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("process_jsonl", persisted.get("extension").?.object.get("runtime").?.string);

    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"value\":42}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "final after invalid");
    var invalid_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer invalid_provider.deinit(allocator);

    var invalid_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = session_root,
        .system_prompt = "sys",
        .model = invalid_provider.model,
        .api_key = invalid_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer invalid_session.deinit();

    try invalid_session.prompt("call process extension with invalid input");

    const invalid_session_file = try allocator.dupe(u8, invalid_session.session_manager.getSessionFile().?);
    defer allocator.free(invalid_session_file);
    var invalid_reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, invalid_session_file, session_root);
    defer invalid_reopened.deinit();
    var invalid_context = try invalid_reopened.buildSessionContext(allocator);
    defer invalid_context.deinit(allocator);

    const invalid_result = invalid_context.messages[2].tool_result;
    try std.testing.expectEqualStrings("ext-echo", invalid_result.tool_name);
    try std.testing.expectEqual(@as(?bool, true), invalid_result.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", invalid_result.content[0].text.text);
    const invalid_details = invalid_result.details.?.object;
    try std.testing.expectEqualStrings("InvalidToolArguments", invalid_details.get("code").?.string);
    try std.testing.expectEqualStrings("ext-echo", invalid_details.get("toolName").?.string);
    try std.testing.expectEqualStrings(invalid_result.tool_call_id, invalid_details.get("toolCallId").?.string);
    try std.testing.expectEqual(@as(i64, 42), invalid_details.get("input").?.object.get("value").?.integer);
    try std.testing.expectEqualStrings("process_jsonl", invalid_details.get("extension").?.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("ext-echo", invalid_details.get("extension").?.object.get("toolName").?.string);
    try std.testing.expectEqualStrings("fixture/ext-echo.js", invalid_details.get("extension").?.object.get("extensionPath").?.string);
    try std.testing.expectEqualStrings("$.value", invalid_details.get("fieldPath").?.string);
    try std.testing.expectEqualStrings("$.value", invalid_details.get("validation").?.object.get("fieldPath").?.string);
    try std.testing.expectEqualStrings("expected string", invalid_details.get("validation").?.object.get("message").?.string);

    const capture_after_invalid = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture_after_invalid);
    try std.testing.expect(std.mem.indexOf(u8, capture_after_invalid, invalid_result.tool_call_id) == null);
}

test "buildAgentToolsWithExtensionsSelection filters extension tools with CLI semantics" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"read\",\"label\":\"Ext Read\",\"description\":\"Extension colliding read\",\"parameters\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}},\"extensionPath\":\"fixture/ext-read.js\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"ext-echo\",\"label\":\"Ext Echo\",\"description\":\"Process echo\",\"parameters\":{\"type\":\"object\",\"properties\":{}},\"extensionPath\":\"fixture/ext-echo.js\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"ext-other\",\"label\":\"Ext Other\",\"description\":\"Other process tool\",\"parameters\":{\"type\":\"object\",\"properties\":{}},\"extensionPath\":\"fixture/ext-other.js\"}\\n'\n" ++
        "while IFS= read -r line; do\n" ++
        "  case \"$line\" in\n" ++
        "    *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;;\n" ++
        "  esac\n" ++
        "done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ext-tools.js", .data = script_body });
    const extension_path = try makeToolAdapterTestPath(allocator, tmp, "ext-tools.js");
    defer allocator.free(extension_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    const source_path = try allocator.dupe(u8, extension_path);
    defer allocator.free(source_path);
    const source_name = try allocator.dupe(u8, "test");
    defer allocator.free(source_name);
    const base_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(base_dir);

    const loaded_extension = resources_mod.LoadedExtension{
        .path = extension_path,
        .source_info = .{
            .path = source_path,
            .source = source_name,
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    };

    var app_context = AppContext.init("/tmp", std.testing.io);

    var allowlisted = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(false, false, &.{ "read", "ext-echo" }),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
        },
    );
    defer allowlisted.deinit();
    try std.testing.expectEqual(@as(usize, 3), allowlisted.items.len);
    try std.testing.expectEqual(@as(usize, 2), countBuiltToolName(allowlisted.items, "read"));
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(allowlisted.items, "ext-echo"));
    try std.testing.expectEqual(@as(usize, 0), countBuiltToolName(allowlisted.items, "ext-other"));
    try std.testing.expectEqual(@as(usize, 0), countBuiltToolName(allowlisted.items, "bash"));

    var no_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
        },
    );
    defer no_tools.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), no_tools.extension_hosts.len);

    var no_builtin = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(false, true, null),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
        },
    );
    defer no_builtin.deinit();
    try std.testing.expectEqual(@as(usize, 3), no_builtin.items.len);
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(no_builtin.items, "read"));
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(no_builtin.items, "ext-echo"));
    try std.testing.expectEqual(@as(usize, 1), countBuiltToolName(no_builtin.items, "ext-other"));
    try std.testing.expectEqual(agent.types.AgentToolSource.extension, findBuiltTool(no_builtin.items, "read").?.source);

    const no_builtin_prompt = try system_prompt_mod.buildSystemPrompt(allocator, .{
        .cwd = "/tmp",
        .current_date = "2026-05-08",
        .tool_selection = tool_selection_mod.ToolSelection.fromCli(false, true, null),
        .active_tools = no_builtin.items,
    });
    defer allocator.free(no_builtin_prompt);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- read: Extension colliding read") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "\"value\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- ext-echo: Process echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- ext-other: Other process tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "\"properties\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- read: Read file contents") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "Available tools:\n(none)") == null);
}

test "extension provider and resource registry contributions feed bootstrap registries" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_provider\",\"name\":\"ext-local-provider\",\"displayName\":\"Extension Local\",\"api\":\"openai-completions\",\"baseUrl\":\"http://localhost:4321/v1\",\"models\":[{\"id\":\"ext-local-model\",\"name\":\"Extension Local Model\"}],\"extensionPath\":\"fixture/provider.js\"}\\n'\n" ++
        "printf '{\"type\":\"resources_discover\",\"skillPaths\":[\"ext-skills\"],\"promptPaths\":[\"ext-prompts\"],\"themePaths\":[\"ext-themes\"],\"extensionPath\":\"fixture/provider.js\"}\\n'\n" ++
        "while IFS= read -r line; do\n" ++
        "  case \"$line\" in\n" ++
        "    *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;;\n" ++
        "  esac\n" ++
        "done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "provider.js", .data = script_body });
    const extension_path = try makeToolAdapterTestPath(allocator, tmp, "provider.js");
    defer allocator.free(extension_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    const source_path = try allocator.dupe(u8, extension_path);
    defer allocator.free(source_path);
    const source_name = try allocator.dupe(u8, "test");
    defer allocator.free(source_name);
    const base_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(base_dir);

    const loaded_extension = resources_mod.LoadedExtension{
        .path = extension_path,
        .source_info = .{
            .path = source_path,
            .source = source_name,
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    };

    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .{
            .extensions = &.{loaded_extension},
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
            .start_without_tools = true,
        },
    );
    defer built_tools.deinit();

    var contributions = try registerExtensionProvidersAndCollectResources(allocator, &built_tools, &.{loaded_extension});
    defer contributions.deinit();

    const provider = ai.model_registry.getProviderConfig("ext-local-provider").?;
    try std.testing.expectEqualStrings("openai-completions", provider.api);
    try std.testing.expectEqualStrings("http://localhost:4321/v1", provider.base_url);
    try std.testing.expectEqualStrings("ext-local-model", provider.default_model_id.?);
    const model = ai.model_registry.find("ext-local-provider", "ext-local-model").?;
    try std.testing.expectEqualStrings("Extension Local Model", model.name);
    try std.testing.expectEqual(@as(usize, 1), contributions.provider_names.len);
    try std.testing.expectEqual(@as(usize, 1), contributions.resource_discoveries.len);
    try std.testing.expectEqualStrings("ext-skills", contributions.resource_discoveries[0].skill_paths[0]);
    try std.testing.expectEqualStrings("ext-prompts", contributions.resource_discoveries[0].prompt_paths[0]);
    try std.testing.expectEqualStrings("ext-themes", contributions.resource_discoveries[0].theme_paths[0]);

    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");
    const session_root = try makeToolAdapterTestPath(allocator, tmp, "workspace");
    defer allocator.free(session_root);
    const session_dir = try makeToolAdapterTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);
    try env_map.put("PI_FAUX_FORCE", "ext-local-provider");
    try env_map.put("PI_FAUX_RESPONSE", "extension provider streamed response");

    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        std.testing.io,
        &env_map,
        "ext-local-provider",
        "ext-local-model",
        null,
        null,
    );
    defer current_provider.deinit(allocator);
    try std.testing.expectEqualStrings("ext-local-provider", current_provider.model.provider);
    try std.testing.expectEqualStrings("ext-local-model", current_provider.model.id);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = session_root,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = &.{},
    });
    defer session.deinit();

    try session.prompt("stream through extension provider");
    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, session_root);
    defer reopened.deinit();
    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("extension provider streamed response", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("ext-local-provider", context.messages[1].assistant.provider);
    try std.testing.expectEqualStrings("ext-local-provider", context.model.?.provider);
    try std.testing.expectEqualStrings("ext-local-model", context.model.?.model_id);
}

test "extension provider collisions are diagnosed and excluded from active registry" {
    const allocator = std.testing.allocator;
    defer ai.model_registry.resetForTesting();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const valid_path = try makeToolAdapterTestPath(allocator, tmp, "valid-provider.js");
    defer allocator.free(valid_path);
    const duplicate_a_path = try makeToolAdapterTestPath(allocator, tmp, "duplicate-a-provider.js");
    defer allocator.free(duplicate_a_path);
    const duplicate_b_path = try makeToolAdapterTestPath(allocator, tmp, "duplicate-b-provider.js");
    defer allocator.free(duplicate_b_path);
    const builtin_path = try makeToolAdapterTestPath(allocator, tmp, "builtin-provider.js");
    defer allocator.free(builtin_path);

    try writeProviderExtensionScript(&tmp, allocator, "valid-provider.js", valid_path, "ext-valid-provider", "Valid Extension Provider", "ext-valid-model", "Valid Extension Model", "http://localhost:4321/v1");
    try writeProviderExtensionScript(&tmp, allocator, "duplicate-a-provider.js", duplicate_a_path, "ext-colliding-provider", "Duplicate Provider A", "dup-a-model", "Duplicate A Model", "http://localhost:4322/v1");
    try writeProviderExtensionScript(&tmp, allocator, "duplicate-b-provider.js", duplicate_b_path, "ext-colliding-provider", "Duplicate Provider B", "dup-b-model", "Duplicate B Model", "http://localhost:4323/v1");
    try writeProviderExtensionScript(&tmp, allocator, "builtin-provider.js", builtin_path, "openai", "Builtin Collision", "shadow-gpt", "Shadow GPT", "http://localhost:4324/v1");

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");

    var valid_extension = try makeLoadedExtensionForTest(allocator, valid_path, .temporary);
    defer valid_extension.deinit(allocator);
    var duplicate_a_extension = try makeLoadedExtensionForTest(allocator, duplicate_a_path, .temporary);
    defer duplicate_a_extension.deinit(allocator);
    var duplicate_b_extension = try makeLoadedExtensionForTest(allocator, duplicate_b_path, .temporary);
    defer duplicate_b_extension.deinit(allocator);
    var builtin_extension = try makeLoadedExtensionForTest(allocator, builtin_path, .temporary);
    defer builtin_extension.deinit(allocator);

    var app_context = AppContext.init("/tmp", std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        &app_context,
        tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .{
            .extensions = &.{ valid_extension, duplicate_a_extension, duplicate_b_extension, builtin_extension },
            .env_map = &env_map,
            .cwd = "/tmp",
            .io = std.testing.io,
            .start_without_tools = true,
        },
    );
    defer built_tools.deinit();

    var contributions = try registerExtensionProvidersAndCollectResources(
        allocator,
        &built_tools,
        &.{ valid_extension, duplicate_a_extension, duplicate_b_extension, builtin_extension },
    );
    defer contributions.deinit();

    const valid_provider = ai.model_registry.getProviderConfig("ext-valid-provider").?;
    try std.testing.expectEqualStrings("openai-completions", valid_provider.api);
    try std.testing.expectEqualStrings("http://localhost:4321/v1", valid_provider.base_url);
    try std.testing.expectEqualStrings("ext-valid-model", valid_provider.default_model_id.?);
    try std.testing.expect(ai.model_registry.find("ext-valid-provider", "ext-valid-model") != null);

    try std.testing.expect(ai.model_registry.getProviderConfig("ext-colliding-provider") == null);
    try std.testing.expect(ai.model_registry.find("ext-colliding-provider", "dup-a-model") == null);
    try std.testing.expect(ai.model_registry.find("ext-colliding-provider", "dup-b-model") == null);

    const builtin_provider = ai.model_registry.getProviderConfig("openai").?;
    try std.testing.expectEqualStrings("https://api.openai.com/v1", builtin_provider.base_url);
    try std.testing.expect(ai.model_registry.find("openai", "shadow-gpt") == null);
    try std.testing.expect(ai.model_registry.find("openai", "gpt-5.4") != null);

    try std.testing.expectEqual(@as(usize, 1), contributions.provider_names.len);
    try std.testing.expectEqualStrings("ext-valid-provider", contributions.provider_names[0]);
    try std.testing.expectEqual(@as(usize, 3), contributions.provider_diagnostics.len);

    const duplicate_a = findProviderDiagnostic(contributions.provider_diagnostics, "extension_provider.duplicate_id", "ext-colliding-provider", duplicate_a_path).?;
    try std.testing.expectEqualStrings("duplicate_extension_provider", duplicate_a.conflict_kind);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_a.conflict_with, duplicate_a_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_a.conflict_with, duplicate_b_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_a.message, "skipped provider activation") != null);

    const duplicate_b = findProviderDiagnostic(contributions.provider_diagnostics, "extension_provider.duplicate_id", "ext-colliding-provider", duplicate_b_path).?;
    try std.testing.expectEqualStrings("duplicate_extension_provider", duplicate_b.conflict_kind);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_b.conflict_with, duplicate_a_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_b.conflict_with, duplicate_b_path) != null);

    const builtin = findProviderDiagnostic(contributions.provider_diagnostics, "extension_provider.builtin_collision", "openai", builtin_path).?;
    try std.testing.expectEqualStrings("builtin_provider", builtin.conflict_kind);
    try std.testing.expectEqualStrings("openai", builtin.conflict_with);
    try std.testing.expectEqualStrings(builtin_path, builtin.extension_path);
    try std.testing.expectEqualStrings(builtin_path, builtin.source_path);
}

test "extension startup loads approved explicit project and global extensions in deterministic order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/.pi/extensions/project-ext");
    try tmp.dir.createDirPath(std.testing.io, "agent/extensions/global-ext");

    try writeRegisteringExtensionScript(&tmp, "explicit.js", "explicit-tool", "Explicit Tool");
    try writeRegisteringExtensionScript(&tmp, "project/.pi/extensions/project-ext/index.js", "project-tool", "Project Tool");
    try writeRegisteringExtensionScript(&tmp, "agent/extensions/global-ext/index.js", "global-tool", "Global Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, "project");
    defer allocator.free(cwd);
    const agent_dir = try makeToolAdapterTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const explicit_path = try makeToolAdapterTestPath(allocator, tmp, "explicit.js");
    defer allocator.free(explicit_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var bundle = try resources_mod.loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .cli_extensions = &.{explicit_path},
        .env_map = &env_map,
    });
    defer bundle.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    for (bundle.extensions) |extension| {
        const key = try extension_runtime.typeScriptPolicyLookupKey(allocator, .{
            .configured_path = extension.source_info.path,
            .resolved_path = extension.path,
            .source_info = extension.source_info,
        });
        defer allocator.free(key);
        try putToolAdapterPolicy(allocator, &policy_map, key, .{ .grants = &.{"tool.use"} });
    }

    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, agent_dir, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = bundle.extensions,
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 3), built_tools.extension_hosts.len);
    try std.testing.expectEqual(@as(usize, 0), built_tools.startup_diagnostics.len);
    const explicit_index = findBuiltToolIndex(built_tools.items, "explicit-tool") orelse return error.TestUnexpectedMissingTool;
    const project_index = findBuiltToolIndex(built_tools.items, "project-tool") orelse return error.TestUnexpectedMissingTool;
    const global_index = findBuiltToolIndex(built_tools.items, "global-tool") orelse return error.TestUnexpectedMissingTool;
    try std.testing.expect(explicit_index < project_index);
    try std.testing.expect(project_index < global_index);
}

test "extension startup resolves manifest graph before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "provider");
    try tmp.dir.createDirPath(std.testing.io, "consumer");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "provider/index.js", "provider-tool", "Provider Tool", order_log, "provider");
    try writeRecordingExtensionScript(&tmp, "consumer/index.js", "consumer-tool", "Consumer Tool", order_log, "consumer");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "provider/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"provider.pkg\",\"name\":\"Provider\",\"version\":\"0.2.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"capabilities\":{\"exports\":[{\"id\":\"cap.startup\",\"kind\":\"tool\",\"version\":\"0.2.0\"}]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "consumer/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"consumer.pkg\",\"name\":\"Consumer\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"capabilities\":{\"imports\":[{\"id\":\"cap.startup\",\"kind\":\"tool\",\"version\":\"^0.2.0\"}]}}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const provider_path = try makeToolAdapterTestPath(allocator, tmp, "provider/index.js");
    defer allocator.free(provider_path);
    const consumer_path = try makeToolAdapterTestPath(allocator, tmp, "consumer/index.js");
    defer allocator.free(consumer_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var provider = try makeLoadedExtensionForTest(allocator, provider_path, .temporary);
    defer provider.deinit(allocator);
    var consumer = try makeLoadedExtensionForTest(allocator, consumer_path, .temporary);
    defer consumer.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, provider, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, consumer, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ consumer, provider },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.extension_hosts.len);
    const order = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, order_log, allocator, .unlimited);
    defer allocator.free(order);
    try std.testing.expectEqualStrings("provider\nconsumer\n", order);
    const provider_index = findBuiltToolIndex(built_tools.items, "provider-tool") orelse return error.TestUnexpectedMissingTool;
    const consumer_index = findBuiltToolIndex(built_tools.items, "consumer-tool") orelse return error.TestUnexpectedMissingTool;
    try std.testing.expect(provider_index < consumer_index);
}

test "package-origin extension startup resolves package-root manifest graph before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "pkg-provider/extensions/provider");
    try tmp.dir.createDirPath(std.testing.io, "pkg-consumer/extensions/consumer");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "package-startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "pkg-provider/extensions/provider/index.js", "package-provider-tool", "Package Provider Tool", order_log, "package-provider");
    try writeRecordingExtensionScript(&tmp, "pkg-consumer/extensions/consumer/index.js", "package-consumer-tool", "Package Consumer Tool", order_log, "package-consumer");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-provider/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.provider\",\"name\":\"Package Provider\",\"version\":\"0.2.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/provider/index.js\"},\"capabilities\":{\"exports\":[{\"id\":\"cap.package-startup\",\"kind\":\"tool\",\"version\":\"0.2.0\"}]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-consumer/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.consumer\",\"name\":\"Package Consumer\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/consumer/index.js\"},\"capabilities\":{\"imports\":[{\"id\":\"cap.package-startup\",\"kind\":\"tool\",\"version\":\"^0.2.0\"}]}}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const provider_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-provider");
    defer allocator.free(provider_root);
    const consumer_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-consumer");
    defer allocator.free(consumer_root);
    const provider_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-provider/extensions/provider/index.js");
    defer allocator.free(provider_path);
    const consumer_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-consumer/extensions/consumer/index.js");
    defer allocator.free(consumer_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var provider = try makePackageLoadedExtensionForTest(allocator, provider_path, provider_root, .project);
    defer provider.deinit(allocator);
    var consumer = try makePackageLoadedExtensionForTest(allocator, consumer_path, consumer_root, .project);
    defer consumer.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, provider, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, consumer, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ consumer, provider },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 2), built_tools.extension_hosts.len);
    const order = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, order_log, allocator, .unlimited);
    defer allocator.free(order);
    try std.testing.expectEqualStrings("package-provider\npackage-consumer\n", order);
    const provider_index = findBuiltToolIndex(built_tools.items, "package-provider-tool") orelse return error.TestUnexpectedMissingTool;
    const consumer_index = findBuiltToolIndex(built_tools.items, "package-consumer-tool") orelse return error.TestUnexpectedMissingTool;
    try std.testing.expect(provider_index < consumer_index);
}

test "extension startup rejects invalid manifest graphs before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "cycle-a");
    try tmp.dir.createDirPath(std.testing.io, "cycle-b");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "cycle-startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "cycle-a/index.js", "cycle-a-tool", "Cycle A Tool", order_log, "cycle-a");
    try writeRecordingExtensionScript(&tmp, "cycle-b/index.js", "cycle-b-tool", "Cycle B Tool", order_log, "cycle-b");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cycle-a/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"cycle.a\",\"name\":\"Cycle A\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"dependencies\":[{\"id\":\"cycle.b\",\"version\":\"^1.0.0\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cycle-b/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"cycle.b\",\"name\":\"Cycle B\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.js\"},\"dependencies\":[{\"id\":\"cycle.a\",\"version\":\"^1.0.0\"}]}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const cycle_a_path = try makeToolAdapterTestPath(allocator, tmp, "cycle-a/index.js");
    defer allocator.free(cycle_a_path);
    const cycle_b_path = try makeToolAdapterTestPath(allocator, tmp, "cycle-b/index.js");
    defer allocator.free(cycle_b_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var cycle_a = try makeLoadedExtensionForTest(allocator, cycle_a_path, .temporary);
    defer cycle_a.deinit(allocator);
    var cycle_b = try makeLoadedExtensionForTest(allocator, cycle_b_path, .temporary);
    defer cycle_b.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_a, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_b, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ cycle_a, cycle_b },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 0), built_tools.extension_hosts.len);
    try std.testing.expect(findBuiltTool(built_tools.items, "cycle-a-tool") == null);
    try std.testing.expect(findBuiltTool(built_tools.items, "cycle-b-tool") == null);
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.cyclic_dependency"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.inactive_package"));
    try std.testing.expect(!pathExists(std.testing.io, order_log));
}

test "package-origin extension startup rejects invalid package-root manifest graphs before activation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "pkg-cycle-a/extensions/cycle-a");
    try tmp.dir.createDirPath(std.testing.io, "pkg-cycle-b/extensions/cycle-b");

    const order_log = try makeToolAdapterTestPath(allocator, tmp, "package-cycle-startup-order.log");
    defer allocator.free(order_log);
    try writeRecordingExtensionScript(&tmp, "pkg-cycle-a/extensions/cycle-a/index.js", "package-cycle-a-tool", "Package Cycle A Tool", order_log, "package-cycle-a");
    try writeRecordingExtensionScript(&tmp, "pkg-cycle-b/extensions/cycle-b/index.js", "package-cycle-b-tool", "Package Cycle B Tool", order_log, "package-cycle-b");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-cycle-a/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.cycle.a\",\"name\":\"Package Cycle A\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/cycle-a/index.js\"},\"dependencies\":[{\"id\":\"package.cycle.b\",\"version\":\"^1.0.0\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "pkg-cycle-b/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"package.cycle.b\",\"name\":\"Package Cycle B\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"extensions/cycle-b/index.js\"},\"dependencies\":[{\"id\":\"package.cycle.a\",\"version\":\"^1.0.0\"}]}",
    });

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const cycle_a_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-a");
    defer allocator.free(cycle_a_root);
    const cycle_b_root = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-b");
    defer allocator.free(cycle_b_root);
    const cycle_a_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-a/extensions/cycle-a/index.js");
    defer allocator.free(cycle_a_path);
    const cycle_b_path = try makeToolAdapterTestPath(allocator, tmp, "pkg-cycle-b/extensions/cycle-b/index.js");
    defer allocator.free(cycle_b_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var cycle_a = try makePackageLoadedExtensionForTest(allocator, cycle_a_path, cycle_a_root, .project);
    defer cycle_a.deinit(allocator);
    var cycle_b = try makePackageLoadedExtensionForTest(allocator, cycle_b_path, cycle_b_root, .project);
    defer cycle_b.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_a, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, cycle_b, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ cycle_a, cycle_b },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 0), built_tools.extension_hosts.len);
    try std.testing.expect(findBuiltTool(built_tools.items, "package-cycle-a-tool") == null);
    try std.testing.expect(findBuiltTool(built_tools.items, "package-cycle-b-tool") == null);
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.cyclic_dependency"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "graph.inactive_package"));
    try std.testing.expect(!pathExists(std.testing.io, order_log));
}

test "extension startup diagnoses optional required and denied policy outcomes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeRegisteringExtensionScript(&tmp, "good.js", "good-tool", "Good Tool");
    try writeHangingExtensionScript(&tmp, "hang.js");
    try writeRegisteringExtensionScript(&tmp, "denied.js", "denied-tool", "Denied Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const good_path = try makeToolAdapterTestPath(allocator, tmp, "good.js");
    defer allocator.free(good_path);
    const hang_path = try makeToolAdapterTestPath(allocator, tmp, "hang.js");
    defer allocator.free(hang_path);
    const denied_path = try makeToolAdapterTestPath(allocator, tmp, "denied.js");
    defer allocator.free(denied_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "50");

    var good = try makeLoadedExtensionForTest(allocator, good_path, .temporary);
    defer good.deinit(allocator);
    var hang = try makeLoadedExtensionForTest(allocator, hang_path, .temporary);
    defer hang.deinit(allocator);
    var denied = try makeLoadedExtensionForTest(allocator, denied_path, .temporary);
    defer denied.deinit(allocator);

    var optional_policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &optional_policy_map);
    try putLoadedExtensionPolicy(allocator, &optional_policy_map, good, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &optional_policy_map, hang, .{ .grants = &.{"tool.use"}, .startup_timeout_ms = 50 });
    try putLoadedExtensionPolicy(allocator, &optional_policy_map, denied, .{ .grants = &.{} });
    var optional_runtime = try makeToolAdapterRuntimeConfig(allocator, cwd, optional_policy_map);
    defer optional_runtime.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var optional_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ good, hang, denied },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &optional_runtime,
    });
    defer optional_tools.deinit();

    try std.testing.expect(findBuiltTool(optional_tools.items, "good-tool") != null);
    try std.testing.expect(findBuiltTool(optional_tools.items, "denied-tool") == null);
    try std.testing.expectEqual(@as(usize, 1), optional_tools.extension_hosts.len);
    try std.testing.expect(optional_tools.startup_diagnostics.len >= 2);
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "startup timed out"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "approvedGrants does not include tool.use"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "extensionId="));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "source="));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "severity=error"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "phase=policy"));
    try std.testing.expect(startupDiagnosticContains(optional_tools.startup_diagnostics, "phase=startup"));
    try std.testing.expect(!optional_tools.required_startup_failed);

    var required_policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &required_policy_map);
    try putLoadedExtensionPolicy(allocator, &required_policy_map, hang, .{ .grants = &.{"tool.use"}, .required = true, .startup_timeout_ms = 50 });
    var required_runtime = try makeToolAdapterRuntimeConfig(allocator, cwd, required_policy_map);
    defer required_runtime.deinit();

    var required_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{hang},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &required_runtime,
    });
    defer required_tools.deinit();
    try std.testing.expect(required_tools.required_startup_failed);
    try std.testing.expectEqual(@as(usize, 0), required_tools.extension_hosts.len);
    try std.testing.expect(startupDiagnosticContains(required_tools.startup_diagnostics, "required=true"));
    try std.testing.expect(startupDiagnosticContains(required_tools.startup_diagnostics, "phase=startup"));
    try std.testing.expect(startupDiagnosticContains(required_tools.startup_diagnostics, hang_path));

    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    try writeStartupDiagnostics(&stderr_capture.writer, required_tools.startup_diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Error: extension lifecycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "extensionId=") != null);
}

test "extension reload swaps tool registry and shuts down removed hosts" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const shutdown_capture = try makeToolAdapterTestPath(allocator, tmp, "old-shutdown.jsonl");
    defer allocator.free(shutdown_capture);
    const old_script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"old-tool\",\"label\":\"Old Tool\",\"description\":\"old description\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}},\"extensionPath\":\"old.js\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in *'\"shutdown\"'*) printf '%s\\n' \"$line\" >> {s}; printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac\n" ++
            "done\n",
        .{shutdown_capture},
    );
    defer allocator.free(old_script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old.js", .data = old_script });
    try writeRegisteringExtensionScript(&tmp, "new.js", "new-tool", "New Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const old_path = try makeToolAdapterTestPath(allocator, tmp, "old.js");
    defer allocator.free(old_path);
    const new_path = try makeToolAdapterTestPath(allocator, tmp, "new.js");
    defer allocator.free(new_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var old_extension = try makeLoadedExtensionForTest(allocator, old_path, .temporary);
    defer old_extension.deinit(allocator);
    var new_extension = try makeLoadedExtensionForTest(allocator, new_path, .temporary);
    defer new_extension.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, old_extension, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, new_extension, .{ .grants = &.{"tool.use"} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{old_extension},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();
    try std.testing.expect(findBuiltTool(built_tools.items, "old-tool") != null);
    try std.testing.expect(findBuiltTool(built_tools.items, "new-tool") == null);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = cwd,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .tools = built_tools.items,
    });
    defer session.deinit();

    try replaceAgentToolsForReload(allocator, &app_context, &session, &built_tools, .{}, .{
        .extensions = &.{new_extension},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });

    try std.testing.expect(findBuiltTool(session.agent.getTools(), "old-tool") == null);
    try std.testing.expect(findBuiltTool(session.agent.getTools(), "new-tool") != null);

    const shutdown_log = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, shutdown_capture, allocator, .unlimited);
    defer allocator.free(shutdown_log);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_log, "\"type\":\"shutdown\"") != null);
}

test "extension reload diagnostics distinguish parse policy and runtime failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parse_script =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf 'not-json\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "parse.js", .data = parse_script });
    const runtime_script =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"diagnostic\",\"category\":\"host_error\",\"severity\":\"error\",\"message\":\"runtime failed\"}\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "runtime.js", .data = runtime_script });
    try writeRegisteringExtensionScript(&tmp, "denied.js", "denied-tool", "Denied Tool");

    const cwd = try makeToolAdapterTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const parse_path = try makeToolAdapterTestPath(allocator, tmp, "parse.js");
    defer allocator.free(parse_path);
    const runtime_path = try makeToolAdapterTestPath(allocator, tmp, "runtime.js");
    defer allocator.free(runtime_path);
    const denied_path = try makeToolAdapterTestPath(allocator, tmp, "denied.js");
    defer allocator.free(denied_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var parse_extension = try makeLoadedExtensionForTest(allocator, parse_path, .temporary);
    defer parse_extension.deinit(allocator);
    var runtime_extension = try makeLoadedExtensionForTest(allocator, runtime_path, .temporary);
    defer runtime_extension.deinit(allocator);
    var denied_extension = try makeLoadedExtensionForTest(allocator, denied_path, .temporary);
    defer denied_extension.deinit(allocator);

    var policy_map = config_mod.ExtensionPolicyMap.init(allocator);
    errdefer deinitToolAdapterPolicyMap(allocator, &policy_map);
    try putLoadedExtensionPolicy(allocator, &policy_map, parse_extension, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, runtime_extension, .{ .grants = &.{"tool.use"} });
    try putLoadedExtensionPolicy(allocator, &policy_map, denied_extension, .{ .grants = &.{} });
    var runtime_config = try makeToolAdapterRuntimeConfig(allocator, cwd, policy_map);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var built_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{ parse_extension, denied_extension, runtime_extension },
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    defer built_tools.deinit();

    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "phase=parse"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "category=malformed_json"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "phase=policy"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "phase=runtime"));
    try std.testing.expect(startupDiagnosticContains(built_tools.startup_diagnostics, "category=host_error"));
}

fn findBuiltTool(items: []const agent.AgentTool, name: []const u8) ?agent.AgentTool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn findBuiltToolIndex(items: []const agent.AgentTool, name: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.name, name)) return index;
    }
    return null;
}

fn countBuiltToolName(items: []const agent.AgentTool, name: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) count += 1;
    }
    return count;
}

fn startupDiagnosticContains(diagnostics: []const ExtensionStartupDiagnostic, needle: []const u8) bool {
    for (diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

fn writeRegisteringExtensionScript(tmp: anytype, sub_path: []const u8, tool_name: []const u8, label: []const u8) !void {
    var script: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer script.deinit();
    try script.writer.print(
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"{s}\",\"label\":\"{s}\",\"description\":\"{s} description\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}},\"extensionPath\":\"{s}\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac\n" ++
            "done\n",
        .{ tool_name, label, label, sub_path },
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = script.written() });
}

fn writeRecordingExtensionScript(
    tmp: anytype,
    sub_path: []const u8,
    tool_name: []const u8,
    label: []const u8,
    order_log: []const u8,
    order_name: []const u8,
) !void {
    var script: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer script.deinit();
    try script.writer.print(
        "IFS= read -r init\n" ++
            "printf '{s}\\n' >> {s}\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"{s}\",\"label\":\"{s}\",\"description\":\"{s} description\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}},\"extensionPath\":\"{s}\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac\n" ++
            "done\n",
        .{ order_name, order_log, tool_name, label, label, sub_path },
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = script.written() });
}

fn writeHangingExtensionScript(tmp: anytype, sub_path: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = "IFS= read -r init\nwhile true; do sleep 1; done\n",
    });
}

fn writeProviderExtensionScript(
    tmp: anytype,
    allocator: std.mem.Allocator,
    sub_path: []const u8,
    extension_path: []const u8,
    provider_id: []const u8,
    display_name: []const u8,
    model_id: []const u8,
    model_name: []const u8,
    base_url: []const u8,
) !void {
    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_provider\",\"name\":\"{s}\",\"displayName\":\"{s}\",\"api\":\"openai-completions\",\"baseUrl\":\"{s}\",\"models\":[{{\"id\":\"{s}\",\"name\":\"{s}\"}}],\"extensionPath\":\"{s}\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac\n" ++
            "done\n",
        .{ provider_id, display_name, base_url, model_id, model_name, extension_path },
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = script });
}

fn findProviderDiagnostic(
    diagnostics: []const ProviderCollisionDiagnostic,
    code: []const u8,
    provider_id: []const u8,
    extension_path: []const u8,
) ?ProviderCollisionDiagnostic {
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, code) and
            std.mem.eql(u8, diagnostic.provider_id, provider_id) and
            std.mem.eql(u8, diagnostic.extension_path, extension_path))
        {
            return diagnostic;
        }
    }
    return null;
}

fn makeLoadedExtensionForTest(
    allocator: std.mem.Allocator,
    extension_path: []const u8,
    scope: resources_mod.SourceScope,
) !resources_mod.LoadedExtension {
    return .{
        .path = try allocator.dupe(u8, extension_path),
        .source_info = .{
            .path = try allocator.dupe(u8, extension_path),
            .source = try allocator.dupe(u8, "test"),
            .scope = scope,
            .origin = .top_level,
            .base_dir = try allocator.dupe(u8, std.fs.path.dirname(extension_path) orelse "."),
        },
    };
}

fn makePackageLoadedExtensionForTest(
    allocator: std.mem.Allocator,
    extension_path: []const u8,
    package_root: []const u8,
    scope: resources_mod.SourceScope,
) !resources_mod.LoadedExtension {
    return .{
        .path = try allocator.dupe(u8, extension_path),
        .source_info = .{
            .path = try allocator.dupe(u8, extension_path),
            .source = try allocator.dupe(u8, "test-package"),
            .scope = scope,
            .origin = .package,
            .base_dir = try allocator.dupe(u8, package_root),
        },
    };
}

const ToolAdapterPolicyOptions = struct {
    grants: []const []const u8 = &.{},
    approved: ?bool = null,
    enabled: ?bool = null,
    required: ?bool = null,
    startup_timeout_ms: ?u64 = null,
};

fn putLoadedExtensionPolicy(
    allocator: std.mem.Allocator,
    map: *config_mod.ExtensionPolicyMap,
    extension: resources_mod.LoadedExtension,
    options: ToolAdapterPolicyOptions,
) !void {
    const key = try extension_runtime.typeScriptPolicyLookupKey(allocator, .{
        .configured_path = extension.source_info.path,
        .resolved_path = extension.path,
        .source_info = extension.source_info,
    });
    defer allocator.free(key);
    try putToolAdapterPolicy(allocator, map, key, options);
}

fn putToolAdapterPolicy(
    allocator: std.mem.Allocator,
    map: *config_mod.ExtensionPolicyMap,
    key: []const u8,
    options: ToolAdapterPolicyOptions,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const grants = try allocator.alloc([]const u8, options.grants.len);
    var initialized: usize = 0;
    errdefer {
        for (grants[0..initialized]) |grant| allocator.free(grant);
        allocator.free(grants);
    }
    for (options.grants, 0..) |grant, index| {
        grants[index] = try allocator.dupe(u8, grant);
        initialized = index + 1;
    }
    var policy = config_mod.ExtensionPolicy{
        .approved_grants = grants,
        .approved = options.approved,
        .enabled = options.enabled,
        .required = options.required,
        .resource_limits = if (options.startup_timeout_ms) |timeout_ms| .{ .timeout_ms = timeout_ms } else null,
    };
    errdefer policy.deinit(allocator);
    try map.put(owned_key, policy);
}

fn makeToolAdapterRuntimeConfig(
    allocator: std.mem.Allocator,
    agent_dir: []const u8,
    policy_map: config_mod.ExtensionPolicyMap,
) !config_mod.RuntimeConfig {
    return .{
        .allocator = allocator,
        .agent_dir = try allocator.dupe(u8, agent_dir),
        .settings = .{ .extension_policies = policy_map },
        .global_settings = .{},
        .project_settings = .{},
        .auth_tokens = std.StringHashMap([]const u8).init(allocator),
        .provider_api_keys = std.StringHashMap([]const u8).init(allocator),
        .keybindings = try keybindings_mod.Keybindings.initDefaults(allocator),
    };
}

fn deinitToolAdapterPolicyMap(allocator: std.mem.Allocator, map: *config_mod.ExtensionPolicyMap) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn makeToolAdapterTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
