pub const std = @import("std");
pub const ai = @import("ai");
pub const agent = @import("agent");
pub const tools = @import("../../../tools/root.zig");
pub const common = @import("../../../tools/common.zig");
pub const config_mod = @import("../../../config/config.zig");
pub const extension_registry = @import("../../../extensions/extension_registry.zig");
pub const extension_runtime = @import("../../../extensions/extension_runtime.zig");
pub const keybindings_mod = @import("../../../shared/keybindings.zig");
pub const provider_config = @import("../../../providers/provider_config.zig");
pub const resources_mod = @import("../../../resources/resources.zig");
pub const system_prompt_mod = @import("../../../resources/system_prompt.zig");
pub const session_mod = @import("../../../sessions/session.zig");
pub const session_manager_mod = @import("../../../sessions/session_manager.zig");
pub const shared = @import("../../shared.zig");
pub const tool_selection_mod = @import("../../../tool_selection.zig");
pub const tool_adapters = @import("../../tool_adapters.zig");

pub const AppContext = shared.AppContext;
pub const BuiltTools = tool_adapters.BuiltTools;
pub const ExtensionStartupDiagnostic = tool_adapters.ExtensionStartupDiagnostic;
pub const ProviderCollisionDiagnostic = tool_adapters.ProviderCollisionDiagnostic;
pub const buildAgentTools = tool_adapters.buildAgentTools;
pub const buildAgentToolsWithExtensions = tool_adapters.buildAgentToolsWithExtensions;
pub const buildAgentToolsWithExtensionsSelection = tool_adapters.buildAgentToolsWithExtensionsSelection;
pub const writeStartupDiagnostics = tool_adapters.writeStartupDiagnostics;
pub const registerExtensionProvidersAndCollectResources = tool_adapters.registerExtensionProvidersAndCollectResources;
pub const replaceAgentToolsForReload = tool_adapters.replaceAgentToolsForReload;
pub const appendLockedWasmTools = tool_adapters.appendLockedWasmTools;
pub const BashToolUpdateForwardContext = tool_adapters.BashToolUpdateForwardContext;
pub const forwardBashToolUpdate = tool_adapters.forwardBashToolUpdate;
pub const pathExists = tool_adapters.pathExists;

pub fn findBuiltTool(items: []const agent.AgentTool, name: []const u8) ?agent.AgentTool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

pub fn findBuiltToolIndex(items: []const agent.AgentTool, name: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.name, name)) return index;
    }
    return null;
}

pub fn countBuiltToolName(items: []const agent.AgentTool, name: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) count += 1;
    }
    return count;
}

pub fn startupDiagnosticContains(diagnostics: []const ExtensionStartupDiagnostic, needle: []const u8) bool {
    for (diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

pub fn writeRegisteringExtensionScript(tmp: anytype, sub_path: []const u8, tool_name: []const u8, label: []const u8) !void {
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

pub fn writeRecordingExtensionScript(
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

pub fn writeHangingExtensionScript(tmp: anytype, sub_path: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = "IFS= read -r init\nwhile true; do sleep 1; done\n",
    });
}

pub fn writeProviderExtensionScript(
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

pub fn findProviderDiagnostic(
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

pub fn makeLoadedExtensionForTest(
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

pub fn makePackageLoadedExtensionForTest(
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

pub const ToolAdapterPolicyOptions = struct {
    grants: []const []const u8 = &.{},
    approved: ?bool = null,
    enabled: ?bool = null,
    required: ?bool = null,
    startup_timeout_ms: ?u64 = null,
};

pub fn putLoadedExtensionPolicy(
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

pub fn putToolAdapterPolicy(
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

pub fn makeToolAdapterRuntimeConfig(
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

pub fn deinitToolAdapterPolicyMap(allocator: std.mem.Allocator, map: *config_mod.ExtensionPolicyMap) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

pub fn makeToolAdapterTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
