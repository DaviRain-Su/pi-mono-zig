const std = @import("std");
const common = @import("../tools/common.zig");

/// Render a deterministic JSON snapshot of the registry to `writer` for
/// CLI/TS-RPC observability. The snapshot includes tools/labels/
/// descriptions, commands/descriptions, shortcuts, flag definitions
/// with parsed CLI values resolved through `getFlag()`, providers +
/// models, and the captured UI request ids. Order is registration
/// order to match the underlying ArrayList storage and the
/// TypeScript listing order.
pub fn writeRegistrySnapshotJson(
    allocator: std.mem.Allocator,
    registry: anytype,
    writer: *std.Io.Writer,
) !void {
    const value = try buildRegistryJsonValue(allocator, registry);
    defer deinitJsonValueLocal(allocator, value);
    try std.json.Stringify.value(value, .{}, writer);
}

pub fn buildRegistryJsonValue(allocator: std.mem.Allocator, registry: anytype) !std.json.Value {
    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});

    try putTools(allocator, &root, registry);
    try putCommands(allocator, &root, registry);
    try putShortcuts(allocator, &root, registry);
    try putCapabilities(allocator, &root, registry);
    try putFlags(allocator, &root, registry);
    try putProviders(allocator, &root, registry);
    try putResourceDiscoveries(allocator, &root, registry);
    try putUiRequestIds(allocator, &root, registry);
    try putInjectionHooks(allocator, &root, registry);
    try putTerminalInputSubscriptions(allocator, &root, registry);
    try putEditorComponentHook(allocator, &root, registry);
    try putWidgets(allocator, &root, registry);
    try putMessageRenderers(allocator, &root, registry);

    return .{ .object = root };
}

fn putTools(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var tools_array = std.json.Array.init(allocator);
    for (registry.tools.items) |tool| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try entry.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, tool.label) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try entry.put(allocator, try allocator.dupe(u8, "parameters"), try common.cloneJsonValue(allocator, tool.parameters));
        try entry.put(allocator, try allocator.dupe(u8, "executionMode"), try optionalStringJson(allocator, tool.execution_mode));
        try entry.put(allocator, try allocator.dupe(u8, "renderShell"), try optionalStringJson(allocator, tool.render_shell));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, tool.extension_path) });
        try tools_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = tools_array });
}

fn putCommands(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var commands_array = std.json.Array.init(allocator);
    const resolved_commands = try registry.resolveCommands(allocator);
    defer deinitResolvedCommandsLocal(allocator, resolved_commands);
    for (resolved_commands) |cmd| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, cmd.name) });
        try entry.put(allocator, try allocator.dupe(u8, "invocationName"), .{ .string = try allocator.dupe(u8, cmd.invocation_name) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), try optionalStringJson(allocator, cmd.description));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, cmd.extension_path) });
        try commands_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "commands"), .{ .array = commands_array });
}

fn putShortcuts(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var shortcuts_array = std.json.Array.init(allocator);
    for (registry.shortcuts.items) |sc| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "shortcut"), .{ .string = try allocator.dupe(u8, sc.shortcut) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), try optionalStringJson(allocator, sc.description));
        try entry.put(allocator, try allocator.dupe(u8, "command"), try optionalStringJson(allocator, sc.command));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, sc.extension_path) });
        try shortcuts_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "shortcuts"), .{ .array = shortcuts_array });
}

fn putCapabilities(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var capabilities_array = std.json.Array.init(allocator);
    for (registry.capabilities.items) |capability| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, capability.id) });
        try entry.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, capability.kind) });
        try entry.put(allocator, try allocator.dupe(u8, "title"), .{ .string = try allocator.dupe(u8, capability.title) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, capability.description) });
        try entry.put(allocator, try allocator.dupe(u8, "command"), try optionalStringJson(allocator, capability.command));
        try entry.put(allocator, try allocator.dupe(u8, "resourcePath"), try optionalStringJson(allocator, capability.resource_path));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, capability.extension_path) });
        try capabilities_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "capabilities"), .{ .array = capabilities_array });
}

fn putFlags(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var flags_array = std.json.Array.init(allocator);
    for (registry.flags.items) |flag| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, flag.name) });
        try entry.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, switch (flag.type_kind) {
            .boolean => "boolean",
            .string => "string",
        }) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), try optionalStringJson(allocator, flag.description));
        try entry.put(allocator, try allocator.dupe(u8, "default"), try flagDefaultToJson(allocator, flag.default_value));
        const resolved = registry.getFlag(flag.name);
        try entry.put(allocator, try allocator.dupe(u8, "value"), try flagValueToJson(allocator, resolved));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, flag.extension_path) });
        try flags_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "flags"), .{ .array = flags_array });
}

fn putProviders(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var providers_array = std.json.Array.init(allocator);
    for (registry.providers.items) |p| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, p.name) });
        try entry.put(allocator, try allocator.dupe(u8, "displayName"), try optionalStringJson(allocator, p.display_name));
        try entry.put(allocator, try allocator.dupe(u8, "baseUrl"), try optionalStringJson(allocator, p.base_url));
        try entry.put(allocator, try allocator.dupe(u8, "api"), try optionalStringJson(allocator, p.api));
        try entry.put(allocator, try allocator.dupe(u8, "defaultModelId"), try optionalStringJson(allocator, if (p.models.len > 0) p.models[0].id else null));
        try entry.put(allocator, try allocator.dupe(u8, "authHeader"), .{ .bool = p.auth_header });
        try entry.put(allocator, try allocator.dupe(u8, "apiKeyConfigured"), .{ .bool = p.api_key_configured });
        const credential_required = p.auth_header or p.oauth != null;
        try entry.put(allocator, try allocator.dupe(u8, "credentialRequired"), .{ .bool = credential_required });
        try entry.put(allocator, try allocator.dupe(u8, "authType"), .{ .string = try allocator.dupe(u8, if (p.oauth != null) "oauth" else if (p.auth_header) "api_key" else "none") });
        try entry.put(allocator, try allocator.dupe(u8, "available"), .{ .bool = !credential_required or p.api_key_configured });
        if (p.oauth) |oauth| {
            var oauth_entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try oauth_entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, oauth.name) });
            try entry.put(allocator, try allocator.dupe(u8, "oauth"), .{ .object = oauth_entry });
        } else {
            try entry.put(allocator, try allocator.dupe(u8, "oauth"), .null);
        }
        var models_array = std.json.Array.init(allocator);
        for (p.models) |m| {
            var m_entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try m_entry.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, m.id) });
            try m_entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, m.name) });
            try models_array.append(.{ .object = m_entry });
        }
        try entry.put(allocator, try allocator.dupe(u8, "models"), .{ .array = models_array });
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, p.extension_path) });
        try providers_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "providers"), .{ .array = providers_array });
}

fn putResourceDiscoveries(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var discoveries_array = std.json.Array.init(allocator);
    for (registry.resource_discoveries.items) |discovery| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, discovery.extension_path) });

        var skill_paths = std.json.Array.init(allocator);
        for (discovery.skill_paths.items) |path| {
            try skill_paths.append(.{ .string = try allocator.dupe(u8, path) });
        }
        try entry.put(allocator, try allocator.dupe(u8, "skillPaths"), .{ .array = skill_paths });

        var prompt_paths = std.json.Array.init(allocator);
        for (discovery.prompt_paths.items) |path| {
            try prompt_paths.append(.{ .string = try allocator.dupe(u8, path) });
        }
        try entry.put(allocator, try allocator.dupe(u8, "promptPaths"), .{ .array = prompt_paths });

        var theme_paths = std.json.Array.init(allocator);
        for (discovery.theme_paths.items) |path| {
            try theme_paths.append(.{ .string = try allocator.dupe(u8, path) });
        }
        try entry.put(allocator, try allocator.dupe(u8, "themePaths"), .{ .array = theme_paths });
        try discoveries_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "resourceDiscoveries"), .{ .array = discoveries_array });
}

fn putUiRequestIds(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var ids_array = std.json.Array.init(allocator);
    for (registry.ui_request_ids.items) |id| {
        try ids_array.append(.{ .string = try allocator.dupe(u8, id) });
    }
    try root.put(allocator, try allocator.dupe(u8, "uiRequestIds"), .{ .array = ids_array });
}

fn putInjectionHooks(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    try root.put(allocator, try allocator.dupe(u8, "headerHook"), try injectionHookJson(allocator, registry.header_hook));
    try root.put(allocator, try allocator.dupe(u8, "footerHook"), try injectionHookJson(allocator, registry.footer_hook));
}

fn putTerminalInputSubscriptions(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var subs_array = std.json.Array.init(allocator);
    for (registry.terminal_input_subs.items) |sub| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, sub.id) });
        try entry.put(allocator, try allocator.dupe(u8, "consume"), .{ .bool = sub.consume });
        try entry.put(allocator, try allocator.dupe(u8, "transformTo"), try optionalStringJson(allocator, sub.transform_to));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, sub.extension_path) });
        try subs_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "terminalInputSubscriptions"), .{ .array = subs_array });
}

fn putEditorComponentHook(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    if (registry.editor_component_hook) |hook| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, hook.label) });
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, hook.extension_path) });
        try root.put(allocator, try allocator.dupe(u8, "editorComponentHook"), .{ .object = entry });
    } else {
        try root.put(allocator, try allocator.dupe(u8, "editorComponentHook"), .null);
    }
}

fn putWidgets(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var widgets_array = std.json.Array.init(allocator);
    for (registry.widgets.items) |widget| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "key"), .{ .string = try allocator.dupe(u8, widget.key) });
        var lines_array = std.json.Array.init(allocator);
        for (widget.lines) |line| {
            try lines_array.append(.{ .string = try allocator.dupe(u8, line) });
        }
        try entry.put(allocator, try allocator.dupe(u8, "lines"), .{ .array = lines_array });
        try entry.put(allocator, try allocator.dupe(u8, "placement"), .{ .string = try allocator.dupe(u8, switch (widget.placement) {
            .above_editor => "aboveEditor",
            .below_editor => "belowEditor",
        }) });
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, widget.extension_path) });
        try widgets_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "widgets"), .{ .array = widgets_array });
}

fn putMessageRenderers(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var mr_array = std.json.Array.init(allocator);
    for (registry.message_renderers.items) |mr| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "customType"), .{ .string = try allocator.dupe(u8, mr.custom_type) });
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, mr.extension_path) });
        try mr_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "messageRenderers"), .{ .array = mr_array });
}

fn injectionHookJson(allocator: std.mem.Allocator, hook: anytype) !std.json.Value {
    const value = hook orelse return .null;
    var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    var lines_array = std.json.Array.init(allocator);
    for (value.lines) |line| {
        try lines_array.append(.{ .string = try allocator.dupe(u8, line) });
    }
    try entry.put(allocator, try allocator.dupe(u8, "lines"), .{ .array = lines_array });
    try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, value.extension_path) });
    return .{ .object = entry };
}

fn optionalStringJson(allocator: std.mem.Allocator, value: ?[]const u8) !std.json.Value {
    if (value) |s| return .{ .string = try allocator.dupe(u8, s) };
    return .null;
}

fn flagDefaultToJson(allocator: std.mem.Allocator, default: anytype) !std.json.Value {
    return switch (default) {
        .none => .null,
        .boolean => |b| .{ .bool = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

fn flagValueToJson(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    return switch (value) {
        .none => .null,
        .boolean => |b| .{ .bool = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

fn deinitJsonValueLocal(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string => |v| allocator.free(v),
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| deinitJsonValueLocal(allocator, item);
            var mut = arr;
            mut.deinit();
        },
        .object => |obj| {
            var mut = obj;
            var iter = mut.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValueLocal(allocator, entry.value_ptr.*);
            }
            mut.deinit(allocator);
        },
    }
}

fn deinitResolvedCommandsLocal(allocator: std.mem.Allocator, commands: anytype) void {
    for (commands) |command| allocator.free(command.invocation_name);
    allocator.free(commands);
}
