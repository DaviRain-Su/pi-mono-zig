const std = @import("std");

/// In-memory mirrors of the registration surfaces a Bun-hosted
/// extension contributes through the JSONL host protocol.
///
/// Each registry takes ownership of the strings it stores and exposes
/// stable, deterministic listings so CLI / TS-RPC consumers can render
/// registry output in fixture tests.
///
/// Mirrors the TypeScript `ExtensionAPI` registration surfaces in
/// `packages/coding-agent/src/core/extensions/types.ts`:
///   * `registerTool`
///   * `registerCommand`
///   * `registerShortcut`
///   * `registerFlag` (defaults; CLI parsing/help integration lives in
///     `extension_flags.zig`)
///   * `registerProvider` / `unregisterProvider`
///
/// Live Bun JSONL frames are appended via `applyHostFrame`; the same
/// registries can be inspected before and after an extension reload to
/// validate dynamic registry refresh behavior (VAL-M11-EXT-008,
/// VAL-M11-EXT-012). Existing CLI-flag passthrough lives in
/// `extension_flags.zig`; this module deliberately mirrors the flag
/// types so JSONL `register_flag` frames can populate both registries
/// from a single live source.

/// Supported flag kinds. Matches `extension_flags.FlagKind` byte-for-byte.
pub const FlagKind = enum { boolean, string };

pub const FlagDefault = union(enum) {
    none,
    boolean: bool,
    string: []u8,

    pub fn deinit(self: *FlagDefault, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .none, .boolean => {},
        }
        self.* = .none;
    }

    pub fn clone(allocator: std.mem.Allocator, source: FlagDefault) !FlagDefault {
        return switch (source) {
            .none => .none,
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
        };
    }
};

pub const ExtensionFlag = struct {
    name: []u8,
    description: ?[]u8,
    type_kind: FlagKind,
    default_value: FlagDefault,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionFlag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        self.default_value.deinit(allocator);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ExtensionTool = struct {
    name: []u8,
    label: []u8,
    description: []u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.label);
        allocator.free(self.description);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ExtensionCommand = struct {
    name: []u8,
    description: ?[]u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ExtensionShortcut = struct {
    shortcut: []u8,
    description: ?[]u8,
    command: ?[]u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionShortcut, allocator: std.mem.Allocator) void {
        allocator.free(self.shortcut);
        if (self.description) |desc| allocator.free(desc);
        if (self.command) |cmd| allocator.free(cmd);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ProviderModel = struct {
    id: []u8,
    name: []u8,

    pub fn deinit(self: *ProviderModel, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ExtensionProvider = struct {
    name: []u8,
    display_name: ?[]u8,
    base_url: ?[]u8,
    api: ?[]u8,
    models: []ProviderModel,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.display_name) |n| allocator.free(n);
        if (self.base_url) |u| allocator.free(u);
        if (self.api) |a| allocator.free(a);
        for (self.models) |*model| model.deinit(allocator);
        allocator.free(self.models);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList(ExtensionFlag) = .empty,
    tools: std.ArrayList(ExtensionTool) = .empty,
    commands: std.ArrayList(ExtensionCommand) = .empty,
    shortcuts: std.ArrayList(ExtensionShortcut) = .empty,
    providers: std.ArrayList(ExtensionProvider) = .empty,
    /// Captured `extension_ui_request` ids in arrival order. Mirrors the
    /// host-side bridge log so UI bridge correlation can be asserted by
    /// fixture tests (VAL-M11-EXT-013).
    ui_request_ids: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.flags.items) |*flag| flag.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        for (self.commands.items) |*cmd| cmd.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        for (self.shortcuts.items) |*sc| sc.deinit(self.allocator);
        self.shortcuts.deinit(self.allocator);
        for (self.providers.items) |*p| p.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        for (self.ui_request_ids.items) |id| self.allocator.free(id);
        self.ui_request_ids.deinit(self.allocator);
        self.* = undefined;
    }

    fn findToolIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.tools.items, 0..) |tool, idx| {
            if (std.mem.eql(u8, tool.name, name)) return idx;
        }
        return null;
    }

    fn findCommandIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.commands.items, 0..) |cmd, idx| {
            if (std.mem.eql(u8, cmd.name, name)) return idx;
        }
        return null;
    }

    fn findShortcutIndex(self: *const Registry, shortcut: []const u8) ?usize {
        for (self.shortcuts.items, 0..) |sc, idx| {
            if (std.mem.eql(u8, sc.shortcut, shortcut)) return idx;
        }
        return null;
    }

    fn findFlagIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.flags.items, 0..) |flag, idx| {
            if (std.mem.eql(u8, flag.name, name)) return idx;
        }
        return null;
    }

    fn findProviderIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.providers.items, 0..) |p, idx| {
            if (std.mem.eql(u8, p.name, name)) return idx;
        }
        return null;
    }

    pub fn registerTool(
        self: *Registry,
        name: []const u8,
        label: []const u8,
        description: []const u8,
        extension_path: []const u8,
    ) !void {
        // TS behavior: re-registering the same tool replaces the existing
        // entry. Mirrors the loader+runner overwrite contract.
        if (self.findToolIndex(name)) |idx| {
            self.tools.items[idx].deinit(self.allocator);
            self.tools.items[idx] = try makeTool(self.allocator, name, label, description, extension_path);
            return;
        }
        const tool = try makeTool(self.allocator, name, label, description, extension_path);
        try self.tools.append(self.allocator, tool);
    }

    pub fn unregisterTool(self: *Registry, name: []const u8) bool {
        if (self.findToolIndex(name)) |idx| {
            var removed = self.tools.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn registerCommand(
        self: *Registry,
        name: []const u8,
        description: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        if (self.findCommandIndex(name)) |idx| {
            self.commands.items[idx].deinit(self.allocator);
            self.commands.items[idx] = try makeCommand(self.allocator, name, description, extension_path);
            return;
        }
        const cmd = try makeCommand(self.allocator, name, description, extension_path);
        try self.commands.append(self.allocator, cmd);
    }

    pub fn registerShortcut(
        self: *Registry,
        shortcut: []const u8,
        description: ?[]const u8,
        command: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        if (self.findShortcutIndex(shortcut)) |idx| {
            self.shortcuts.items[idx].deinit(self.allocator);
            self.shortcuts.items[idx] = try makeShortcut(self.allocator, shortcut, description, command, extension_path);
            return;
        }
        const sc = try makeShortcut(self.allocator, shortcut, description, command, extension_path);
        try self.shortcuts.append(self.allocator, sc);
    }

    /// Register a flag with an optional default. Strings are borrowed;
    /// the registry always clones what it needs.
    pub fn registerFlag(
        self: *Registry,
        name: []const u8,
        type_kind: FlagKind,
        description: ?[]const u8,
        default_value: FlagDefaultInput,
        extension_path: []const u8,
    ) !void {
        if (self.findFlagIndex(name)) |idx| {
            self.flags.items[idx].deinit(self.allocator);
            self.flags.items[idx] = try makeFlag(self.allocator, name, type_kind, description, default_value, extension_path);
            return;
        }
        const flag = try makeFlag(self.allocator, name, type_kind, description, default_value, extension_path);
        try self.flags.append(self.allocator, flag);
    }

    pub fn registerProvider(
        self: *Registry,
        name: []const u8,
        display_name: ?[]const u8,
        base_url: ?[]const u8,
        api: ?[]const u8,
        models: []const ProviderModelInput,
        extension_path: []const u8,
    ) !void {
        // Mirror TS: re-registering replaces all existing models.
        if (self.findProviderIndex(name)) |idx| {
            var removed = self.providers.orderedRemove(idx);
            removed.deinit(self.allocator);
        }

        const owned_models = try self.allocator.alloc(ProviderModel, models.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_models[0..initialized]) |*m| m.deinit(self.allocator);
            self.allocator.free(owned_models);
        }
        for (models, 0..) |m, idx| {
            owned_models[idx] = .{
                .id = try self.allocator.dupe(u8, m.id),
                .name = try self.allocator.dupe(u8, m.name),
            };
            initialized = idx + 1;
        }

        const display_dup = if (display_name) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (display_dup) |n| self.allocator.free(n);
        const base_dup = if (base_url) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (base_dup) |n| self.allocator.free(n);
        const api_dup = if (api) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (api_dup) |n| self.allocator.free(n);

        const provider: ExtensionProvider = .{
            .name = try self.allocator.dupe(u8, name),
            .display_name = display_dup,
            .base_url = base_dup,
            .api = api_dup,
            .models = owned_models,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        };
        try self.providers.append(self.allocator, provider);
    }

    pub fn unregisterProvider(self: *Registry, name: []const u8) bool {
        if (self.findProviderIndex(name)) |idx| {
            var removed = self.providers.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn recordUiRequest(self: *Registry, id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.ui_request_ids.append(self.allocator, owned);
    }
};

/// Lightweight provider/model descriptor used as input to
/// `Registry.registerProvider`. Strings are borrowed; the registry
/// owns its own copies.
pub const ProviderModelInput = struct {
    id: []const u8,
    name: []const u8,
};

/// Input variant of `FlagDefault` whose string is borrowed. `Registry`
/// always clones what it stores; the caller retains ownership of any
/// `.string` payload it passed in.
pub const FlagDefaultInput = union(enum) {
    none,
    boolean: bool,
    string: []const u8,
};

fn makeTool(
    allocator: std.mem.Allocator,
    name: []const u8,
    label: []const u8,
    description: []const u8,
    extension_path: []const u8,
) !ExtensionTool {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const label_dup = try allocator.dupe(u8, label);
    errdefer allocator.free(label_dup);
    const desc_dup = try allocator.dupe(u8, description);
    errdefer allocator.free(desc_dup);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .name = name_dup,
        .label = label_dup,
        .description = desc_dup,
        .extension_path = path_dup,
    };
}

fn makeCommand(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: ?[]const u8,
    extension_path: []const u8,
) !ExtensionCommand {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const desc_dup = if (description) |d| try allocator.dupe(u8, d) else null;
    errdefer if (desc_dup) |d| allocator.free(d);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .name = name_dup,
        .description = desc_dup,
        .extension_path = path_dup,
    };
}

fn makeShortcut(
    allocator: std.mem.Allocator,
    shortcut: []const u8,
    description: ?[]const u8,
    command: ?[]const u8,
    extension_path: []const u8,
) !ExtensionShortcut {
    const sc_dup = try allocator.dupe(u8, shortcut);
    errdefer allocator.free(sc_dup);
    const desc_dup = if (description) |d| try allocator.dupe(u8, d) else null;
    errdefer if (desc_dup) |d| allocator.free(d);
    const cmd_dup = if (command) |c| try allocator.dupe(u8, c) else null;
    errdefer if (cmd_dup) |c| allocator.free(c);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .shortcut = sc_dup,
        .description = desc_dup,
        .command = cmd_dup,
        .extension_path = path_dup,
    };
}

fn makeFlag(
    allocator: std.mem.Allocator,
    name: []const u8,
    type_kind: FlagKind,
    description: ?[]const u8,
    default_value: FlagDefaultInput,
    extension_path: []const u8,
) !ExtensionFlag {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const desc_dup = if (description) |d| try allocator.dupe(u8, d) else null;
    errdefer if (desc_dup) |d| allocator.free(d);
    const default_dup: FlagDefault = switch (default_value) {
        .none => .none,
        .boolean => |b| .{ .boolean = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
    errdefer {
        var d = default_dup;
        d.deinit(allocator);
    }
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .name = name_dup,
        .description = desc_dup,
        .type_kind = type_kind,
        .default_value = default_dup,
        .extension_path = path_dup,
    };
}

/// Outcome of feeding a single JSONL frame into the registry. Used by
/// fixture tests (and the live host driver) to surface deterministic
/// diagnostics for unsupported / malformed register frames without
/// aborting the whole stream.
pub const FrameOutcome = enum {
    none,
    registered_tool,
    registered_command,
    registered_shortcut,
    registered_flag,
    registered_provider,
    unregistered_provider,
    ignored_unsupported,
    ignored_malformed,
};

/// Apply a single JSONL host frame (already JSON-decoded) to the
/// registry. Unknown / malformed frames are reported via the returned
/// `FrameOutcome` rather than throwing so a single bad frame does not
/// break the whole extension stream.
pub fn applyHostFrame(
    registry: *Registry,
    frame: std.json.Value,
) !FrameOutcome {
    if (frame != .object) return .ignored_malformed;
    const object = frame.object;

    const type_value = object.get("type") orelse return .ignored_malformed;
    if (type_value != .string) return .ignored_malformed;
    const type_name = type_value.string;

    const extension_path = optionalString(object, "extensionPath") orelse "";

    if (std.mem.eql(u8, type_name, "register_tool")) {
        const name = optionalString(object, "name") orelse return .ignored_malformed;
        const label = optionalString(object, "label") orelse name;
        const description = optionalString(object, "description") orelse "";
        try registry.registerTool(name, label, description, extension_path);
        return .registered_tool;
    }

    if (std.mem.eql(u8, type_name, "register_command")) {
        const name = optionalString(object, "name") orelse return .ignored_malformed;
        const description = optionalString(object, "description");
        try registry.registerCommand(name, description, extension_path);
        return .registered_command;
    }

    if (std.mem.eql(u8, type_name, "register_shortcut")) {
        const shortcut = optionalString(object, "shortcut") orelse return .ignored_malformed;
        const description = optionalString(object, "description");
        const command = optionalString(object, "command");
        try registry.registerShortcut(shortcut, description, command, extension_path);
        return .registered_shortcut;
    }

    if (std.mem.eql(u8, type_name, "register_flag")) {
        const name = optionalString(object, "name") orelse return .ignored_malformed;
        const type_kind = parseFlagKind(optionalString(object, "valueType") orelse optionalString(object, "type") orelse "boolean") orelse return .ignored_malformed;
        const description = optionalString(object, "description");
        var default_value: FlagDefaultInput = .none;
        if (object.get("default")) |default_val| {
            switch (default_val) {
                .bool => |b| default_value = .{ .boolean = b },
                .string => |s| default_value = .{ .string = s },
                else => {},
            }
        }
        try registry.registerFlag(name, type_kind, description, default_value, extension_path);
        return .registered_flag;
    }

    if (std.mem.eql(u8, type_name, "register_provider")) {
        const name = optionalString(object, "name") orelse return .ignored_malformed;
        const display_name = optionalString(object, "displayName");
        const base_url = optionalString(object, "baseUrl");
        const api = optionalString(object, "api");
        var inputs = std.ArrayList(ProviderModelInput).empty;
        defer inputs.deinit(registry.allocator);
        if (object.get("models")) |models_value| {
            if (models_value == .array) {
                for (models_value.array.items) |m| {
                    if (m != .object) continue;
                    const id = optionalString(m.object, "id") orelse continue;
                    const display = optionalString(m.object, "name") orelse id;
                    try inputs.append(registry.allocator, .{ .id = id, .name = display });
                }
            }
        }
        try registry.registerProvider(name, display_name, base_url, api, inputs.items, extension_path);
        return .registered_provider;
    }

    if (std.mem.eql(u8, type_name, "unregister_provider")) {
        const name = optionalString(object, "name") orelse return .ignored_malformed;
        _ = registry.unregisterProvider(name);
        return .unregistered_provider;
    }

    if (std.mem.eql(u8, type_name, "extension_ui_request")) {
        if (optionalString(object, "id")) |id| {
            try registry.recordUiRequest(id);
        }
        return .none;
    }

    return .ignored_unsupported;
}

/// Load and apply registration frames from a deterministic local
/// sidecar manifest next to a Bun-hosted extension entry. This is the
/// local fixture compatibility hook used by M11 registration tests;
/// live Bun extensions will produce the same frames over the JSONL
/// stdout protocol.
///
/// Tries `<extension>.registry.jsonl` first (file-extension form), then
/// `<extension>/registry.jsonl` for directory-style extensions.
pub fn loadFromExtensionPaths(
    registry: *Registry,
    io: std.Io,
    extension_paths: []const []const u8,
) !void {
    for (extension_paths) |path| {
        const manifest_text = readManifestForPath(registry.allocator, io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer registry.allocator.free(manifest_text);
        _ = try applyHostFrameStream(registry, manifest_text);
    }
}

fn readManifestForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const sidecar = try std.fmt.allocPrint(allocator, "{s}.registry.jsonl", .{path});
    defer allocator.free(sidecar);

    if (std.Io.Dir.readFileAlloc(.cwd(), io, sidecar, allocator, .limited(256 * 1024))) |bytes| {
        return bytes;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const dir_manifest = try std.fs.path.join(allocator, &[_][]const u8{ path, "registry.jsonl" });
    defer allocator.free(dir_manifest);
    return std.Io.Dir.readFileAlloc(.cwd(), io, dir_manifest, allocator, .limited(256 * 1024));
}

/// Feed a buffer of JSONL frames (one JSON object per line) into the
/// registry. Returns the number of frames successfully applied.
pub fn applyHostFrameStream(
    registry: *Registry,
    bytes: []const u8,
) !usize {
    var applied: usize = 0;
    var iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (iterator.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, registry.allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const outcome = try applyHostFrame(registry, parsed.value);
        switch (outcome) {
            .none, .ignored_unsupported, .ignored_malformed => {},
            else => applied += 1,
        }
    }
    return applied;
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn parseFlagKind(name: []const u8) ?FlagKind {
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "string")) return .string;
    return null;
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

test "registry registers tools/commands/shortcuts/flags/providers and round-trips" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerTool("greet", "Greet", "Greets the world", "/tmp/greet.ts");
    try registry.registerCommand("greet", "Greets via slash command", "/tmp/greet.ts");
    try registry.registerShortcut("ctrl+g", "Trigger greet", "greet", "/tmp/greet.ts");
    try registry.registerFlag("plan", .boolean, "Enable plan mode", .{ .boolean = true }, "/tmp/greet.ts");
    try registry.registerFlag("alias", .string, null, .{ .string = "claude" }, "/tmp/greet.ts");
    try registry.registerProvider(
        "fake-provider",
        "Fake Provider",
        "http://localhost:0",
        "openai-completions",
        &.{
            .{ .id = "fake-1", .name = "Fake Model 1" },
            .{ .id = "fake-2", .name = "Fake Model 2" },
        },
        "/tmp/fake.ts",
    );

    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("greet", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("Greets the world", registry.tools.items[0].description);

    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqualStrings("greet", registry.commands.items[0].name);

    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqualStrings("ctrl+g", registry.shortcuts.items[0].shortcut);
    try std.testing.expectEqualStrings("greet", registry.shortcuts.items[0].command.?);

    try std.testing.expectEqual(@as(usize, 2), registry.flags.items.len);
    try std.testing.expect(registry.flags.items[0].type_kind == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value.boolean);
    try std.testing.expect(registry.flags.items[1].type_kind == .string);
    try std.testing.expectEqualStrings("claude", registry.flags.items[1].default_value.string);

    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("fake-provider", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), registry.providers.items[0].models.len);
    try std.testing.expectEqualStrings("fake-1", registry.providers.items[0].models[0].id);

    // Re-register the tool and ensure the listing still has only one
    // entry but with updated metadata.
    try registry.registerTool("greet", "Greet v2", "Greets the world (v2)", "/tmp/greet.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Greet v2", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("Greets the world (v2)", registry.tools.items[0].description);

    // Re-register the provider and ensure model list is replaced.
    try registry.registerProvider(
        "fake-provider",
        "Fake Provider",
        "http://localhost:0",
        "openai-completions",
        &.{.{ .id = "fake-only", .name = "Fake Only" }},
        "/tmp/fake.ts",
    );
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items[0].models.len);
    try std.testing.expectEqualStrings("fake-only", registry.providers.items[0].models[0].id);

    // unregisterProvider removes the entry deterministically and a
    // second call returns false.
    try std.testing.expect(registry.unregisterProvider("fake-provider"));
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expect(!registry.unregisterProvider("fake-provider"));
}

test "applyHostFrame supports register and unregister surfaces with malformed frame fallback" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "say", "label": "Say", "description": "Says hi", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command", "name": "say", "description": "Slash command", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+s", "description": "Trigger say", "command": "say", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_flag", "name": "plan", "valueType": "boolean", "default": true, "description": "Plan mode", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_flag", "name": "alias", "valueType": "string", "default": "claude", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_provider", "name": "fake-provider", "displayName": "Fake", "api": "openai-completions", "baseUrl": "http://localhost:0", "models": [{ "id": "fake-1", "name": "Fake 1" }, { "id": "fake-2", "name": "Fake 2" }], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_tool", "name": "say" }
        \\{ "type": "unsupported_frame" }
        \\{ "type": "unregister_provider", "name": "fake-provider" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    // 6 distinct register_* frames + 1 re-register tool + 1 unregister
    // = 8 successful applies; the unsupported_frame is counted as
    // ignored.
    try std.testing.expectEqual(@as(usize, 8), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("say", registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 2), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
}

test "applyHostFrame replaces re-registered tool metadata for dynamic refresh" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const initial_frames =
        \\{ "type": "register_tool", "name": "greet", "label": "Greet", "description": "v1", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, initial_frames);
    try std.testing.expectEqualStrings("Greet", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("v1", registry.tools.items[0].description);

    // Simulate dynamic refresh: same tool name re-registered with new
    // metadata; registry refreshes in place without leaking stale
    // entries.
    const refresh_frames =
        \\{ "type": "register_tool", "name": "greet", "label": "Greet v2", "description": "v2", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, refresh_frames);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Greet v2", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("v2", registry.tools.items[0].description);
}

test "applyHostFrame ignores malformed JSON lines without aborting the stream" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\not-json
        \\{ "type": 42 }
        \\{ "type": "register_tool", "name": "say", "label": "Say", "description": "ok", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command" }
        \\
    ;
    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
}

const FIXTURE_REGISTRY_JSONL =
    \\{"type":"register_tool","name":"say-hello","label":"Say Hello","description":"Greets the world (fixture tool)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_command","name":"say-hello","description":"Slash command for say-hello","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_shortcut","shortcut":"ctrl+h","description":"Trigger say-hello","command":"say-hello","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_flag","name":"plan","valueType":"boolean","default":true,"description":"Enable plan mode (fixture flag)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_flag","name":"model-alias","valueType":"string","default":"claude-haiku","description":"Model alias override (fixture flag)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_provider","name":"fake-provider","displayName":"Fake Provider","api":"openai-completions","baseUrl":"http://localhost:0","models":[{"id":"fake-model-1","name":"Fake Model 1"},{"id":"fake-model-2","name":"Fake Model 2"}],"extensionPath":"registration-fixture/extension.ts"}
;

const FIXTURE_REFRESH_JSONL =
    \\{"type":"register_tool","name":"say-hello","label":"Say Hello v2","description":"Greets the world (refreshed)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_tool","name":"new-tool","label":"New Tool","description":"Added on refresh","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"unregister_provider","name":"fake-provider"}
;

test "loadFromExtensionPaths reads registration fixture sidecar" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = "extension.ts";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ext_path, .data = "// extension stub" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "extension.ts.registry.jsonl", .data = FIXTURE_REGISTRY_JSONL });

    const tmp_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        ext_path,
    });
    defer allocator.free(tmp_relative);

    var registry = Registry.init(allocator);
    defer registry.deinit();
    try loadFromExtensionPaths(&registry, std.testing.io, &.{tmp_relative});

    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("say-hello", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("Say Hello", registry.tools.items[0].label);

    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqualStrings("say-hello", registry.commands.items[0].name);

    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqualStrings("ctrl+h", registry.shortcuts.items[0].shortcut);
    try std.testing.expectEqualStrings("say-hello", registry.shortcuts.items[0].command.?);

    try std.testing.expectEqual(@as(usize, 2), registry.flags.items.len);
    try std.testing.expect(registry.flags.items[0].type_kind == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value.boolean);
    try std.testing.expect(registry.flags.items[1].type_kind == .string);
    try std.testing.expectEqualStrings("claude-haiku", registry.flags.items[1].default_value.string);

    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("fake-provider", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), registry.providers.items[0].models.len);
}

test "registration fixture refresh updates tools and removes provider" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    _ = try applyHostFrameStream(&registry, FIXTURE_REGISTRY_JSONL);

    // Sanity-check the initial state.
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Say Hello", registry.tools.items[0].label);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);

    // Simulate dynamic refresh by replaying the refresh JSONL frames
    // against the same registry. Existing tools refresh in place; a new
    // tool is added; the provider is unregistered.
    _ = try applyHostFrameStream(&registry, FIXTURE_REFRESH_JSONL);

    try std.testing.expectEqual(@as(usize, 2), registry.tools.items.len);
    try std.testing.expectEqualStrings("Say Hello v2", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("Greets the world (refreshed)", registry.tools.items[0].description);
    try std.testing.expectEqualStrings("new-tool", registry.tools.items[1].name);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
}

test "applyHostFrame records ui request ids for bridge correlation" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "extension_ui_request", "id": "ui-1", "method": "select" }
        \\{ "type": "extension_ui_request", "id": "ui-2", "method": "confirm" }
        \\{ "type": "extension_ui_request" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), registry.ui_request_ids.items.len);
    try std.testing.expectEqualStrings("ui-1", registry.ui_request_ids.items[0]);
    try std.testing.expectEqualStrings("ui-2", registry.ui_request_ids.items[1]);
}
