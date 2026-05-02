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
    /// Parsed CLI value for this flag, set by `setFlagValue` when the
    /// CLI parser observes `--<name>` (and optional value) on the
    /// command line. Mirrors TypeScript `extensionState.flags[name]`
    /// so extensions can observe CLI flag values via `getFlag()`.
    cli_value: FlagDefault = .none,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionFlag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        self.default_value.deinit(allocator);
        self.cli_value.deinit(allocator);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Resolved CLI/runtime flag value used by `Registry.getFlag`. Mirrors
/// the TypeScript `extensionState.flags[name]` shape: explicit CLI
/// value wins, else the registered default, else `.none`.
pub const FlagValue = union(enum) {
    none,
    boolean: bool,
    string: []const u8,
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

/// Header / footer hook captured from the live Bun host. Mirrors the
/// TS `ExtensionUIContext.setHeader` / `setFooter` factories: at the
/// JSONL protocol layer the host serializes a deterministic content
/// preview (line array) plus the owning extension path so cleanup on
/// reload / session replacement can target hooks by extension.
pub const InjectionHook = struct {
    lines: [][]u8,
    extension_path: []u8,

    pub fn deinit(self: *InjectionHook, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Terminal input subscription. The host serializes the consume +
/// transform behavior so cleanup/unsubscribe can be observed without a
/// real TUI: `consume = true` mirrors `{ consume: true }` returned from
/// the TS handler; `transform_to` mirrors `{ data: <new> }`. A pure
/// observer subscription has both `consume = false` and
/// `transform_to == null`.
pub const TerminalInputSubscription = struct {
    id: []u8,
    consume: bool = false,
    transform_to: ?[]u8 = null,
    extension_path: []u8,

    pub fn deinit(self: *TerminalInputSubscription, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.transform_to) |t| allocator.free(t);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Custom editor component hook. The host serializes a deterministic
/// label (the registered editor name) so reload/cleanup can confirm
/// the previous custom editor did not survive.
pub const EditorComponentHook = struct {
    label: []u8,
    extension_path: []u8,

    pub fn deinit(self: *EditorComponentHook, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Result of feeding terminal input bytes through the registered
/// subscriptions. `consumed` blocks the default editor; `data` is the
/// final transformed bytes (caller borrows).
pub const TerminalInputResult = struct {
    consumed: bool,
    data: []const u8,
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
    /// Currently-installed extension header hook (TS `setHeader`).
    /// Single-slot to mirror the TS interactive runtime contract:
    /// later setHeader frames replace the previous one. `null` means
    /// the built-in header is in use.
    header_hook: ?InjectionHook = null,
    /// Currently-installed extension footer hook (TS `setFooter`).
    footer_hook: ?InjectionHook = null,
    /// Terminal input subscriptions in registration order. Each
    /// subscription has a stable id so unsubscribe frames can target
    /// the exact handler.
    terminal_input_subs: std.ArrayList(TerminalInputSubscription) = .empty,
    /// Custom editor component hook (TS `setEditorComponent`).
    /// Single-slot; `null` means the default editor is in use.
    editor_component_hook: ?EditorComponentHook = null,

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
        if (self.header_hook) |*h| h.deinit(self.allocator);
        if (self.footer_hook) |*h| h.deinit(self.allocator);
        for (self.terminal_input_subs.items) |*sub| sub.deinit(self.allocator);
        self.terminal_input_subs.deinit(self.allocator);
        if (self.editor_component_hook) |*h| h.deinit(self.allocator);
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

    /// Set the parsed CLI value for a registered flag. Mirrors the TS
    /// `extensionState.flags[name] = value` step the runtime performs
    /// after parsing the CLI. Returns `true` when the flag is known
    /// (the value is stored regardless of registration order, but
    /// callers should register the flag first).
    pub fn setFlagValue(self: *Registry, name: []const u8, value: FlagDefaultInput) !bool {
        const idx = self.findFlagIndex(name) orelse return false;
        var new_value: FlagDefault = switch (value) {
            .none => .none,
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
        };
        errdefer new_value.deinit(self.allocator);
        self.flags.items[idx].cli_value.deinit(self.allocator);
        self.flags.items[idx].cli_value = new_value;
        return true;
    }

    /// Return the resolved flag value: explicit CLI value if set, else
    /// the registered default, else `.none`. The returned `.string`
    /// borrow is valid for the registry lifetime.
    pub fn getFlag(self: *const Registry, name: []const u8) FlagValue {
        const idx = self.findFlagIndex(name) orelse return .none;
        const flag = self.flags.items[idx];
        switch (flag.cli_value) {
            .boolean => |b| return .{ .boolean = b },
            .string => |s| return .{ .string = s },
            .none => {},
        }
        return switch (flag.default_value) {
            .none => .none,
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = s },
        };
    }

    pub fn recordUiRequest(self: *Registry, id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.ui_request_ids.append(self.allocator, owned);
    }

    /// Install the extension header hook. Replaces any previous header
    /// hook (TS `setHeader` is single-slot per runtime).
    pub fn setHeaderHook(
        self: *Registry,
        lines: []const []const u8,
        extension_path: []const u8,
    ) !void {
        var owned_lines = try self.allocator.alloc([]u8, lines.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_lines[0..initialized]) |line| self.allocator.free(line);
            self.allocator.free(owned_lines);
        }
        for (lines, 0..) |line, idx| {
            owned_lines[idx] = try self.allocator.dupe(u8, line);
            initialized = idx + 1;
        }
        const path_dup = try self.allocator.dupe(u8, extension_path);
        if (self.header_hook) |*existing| existing.deinit(self.allocator);
        self.header_hook = .{ .lines = owned_lines, .extension_path = path_dup };
    }

    /// Remove the extension header hook (TS `setHeader(undefined)` /
    /// session replacement clears the hook).
    pub fn clearHeaderHook(self: *Registry) bool {
        if (self.header_hook) |*existing| {
            existing.deinit(self.allocator);
            self.header_hook = null;
            return true;
        }
        return false;
    }

    /// Install the extension footer hook. Replaces any previous footer
    /// hook (TS `setFooter` is single-slot per runtime).
    pub fn setFooterHook(
        self: *Registry,
        lines: []const []const u8,
        extension_path: []const u8,
    ) !void {
        var owned_lines = try self.allocator.alloc([]u8, lines.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_lines[0..initialized]) |line| self.allocator.free(line);
            self.allocator.free(owned_lines);
        }
        for (lines, 0..) |line, idx| {
            owned_lines[idx] = try self.allocator.dupe(u8, line);
            initialized = idx + 1;
        }
        const path_dup = try self.allocator.dupe(u8, extension_path);
        if (self.footer_hook) |*existing| existing.deinit(self.allocator);
        self.footer_hook = .{ .lines = owned_lines, .extension_path = path_dup };
    }

    pub fn clearFooterHook(self: *Registry) bool {
        if (self.footer_hook) |*existing| {
            existing.deinit(self.allocator);
            self.footer_hook = null;
            return true;
        }
        return false;
    }

    /// Register a terminal input subscription with a stable id. Later
    /// frames with the same id replace the previous behavior so
    /// extensions can change consume/transform behavior at runtime.
    pub fn registerTerminalInput(
        self: *Registry,
        id: []const u8,
        consume: bool,
        transform_to: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        // Replace existing subscription with the same id (TS unsubscribe
        // is by closure identity, but the JSONL protocol surfaces the
        // id explicitly so the runtime can route updates).
        for (self.terminal_input_subs.items, 0..) |*sub, idx| {
            if (std.mem.eql(u8, sub.id, id)) {
                sub.deinit(self.allocator);
                self.terminal_input_subs.items[idx] = try makeTerminalInputSubscription(self.allocator, id, consume, transform_to, extension_path);
                return;
            }
        }
        const sub = try makeTerminalInputSubscription(self.allocator, id, consume, transform_to, extension_path);
        try self.terminal_input_subs.append(self.allocator, sub);
    }

    /// Remove a terminal input subscription by id. Mirrors calling the
    /// TS unsubscribe closure returned from `onTerminalInput`. Returns
    /// `true` when an entry was removed.
    pub fn unregisterTerminalInput(self: *Registry, id: []const u8) bool {
        for (self.terminal_input_subs.items, 0..) |*sub, idx| {
            if (std.mem.eql(u8, sub.id, id)) {
                var removed = self.terminal_input_subs.orderedRemove(idx);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Apply terminal input bytes through the registered subscriptions
    /// in registration order. Mirrors TS behavior:
    ///   * If a subscription returns `{ consume: true }`, propagation
    ///     stops and the default editor does not see the bytes.
    ///   * If a subscription returns `{ data: <new> }` without consume,
    ///     the bytes are rewritten and propagation continues to later
    ///     subscriptions and finally the default editor.
    ///   * If a subscription returns nothing, propagation continues
    ///     unchanged.
    /// `scratch` is filled with owned bytes when a transform happens
    /// across multiple subscriptions; the returned `data` slice
    /// borrows from `scratch.items` or the original `bytes` slice.
    pub fn applyTerminalInput(
        self: *Registry,
        bytes: []const u8,
        scratch: *std.ArrayList(u8),
    ) !TerminalInputResult {
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(self.allocator, bytes);
        var consumed = false;
        for (self.terminal_input_subs.items) |sub| {
            if (sub.consume) {
                consumed = true;
                break;
            }
            if (sub.transform_to) |new_data| {
                scratch.clearRetainingCapacity();
                try scratch.appendSlice(self.allocator, new_data);
            }
        }
        return .{ .consumed = consumed, .data = scratch.items };
    }

    /// Install the custom editor component hook. Replaces any previous
    /// editor hook (TS `setEditorComponent` is single-slot per runtime).
    pub fn setEditorComponentHook(
        self: *Registry,
        label: []const u8,
        extension_path: []const u8,
    ) !void {
        const label_dup = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_dup);
        const path_dup = try self.allocator.dupe(u8, extension_path);
        if (self.editor_component_hook) |*existing| existing.deinit(self.allocator);
        self.editor_component_hook = .{ .label = label_dup, .extension_path = path_dup };
    }

    pub fn clearEditorComponentHook(self: *Registry) bool {
        if (self.editor_component_hook) |*existing| {
            existing.deinit(self.allocator);
            self.editor_component_hook = null;
            return true;
        }
        return false;
    }

    /// Drop every UI hook that should not survive an extension reload
    /// or session replacement. This mirrors the TS interactive runtime
    /// teardown that clears extension header/footer factories,
    /// extension terminal input listeners, and the custom editor
    /// component before re-binding extensions on the new session.
    /// Static registrations (tools, commands, shortcuts, flags,
    /// providers) are left intact and re-asserted by the next round of
    /// register_* frames; UI hooks are NOT, by design.
    pub fn clearUiHooksForReload(self: *Registry) void {
        if (self.header_hook) |*existing| {
            existing.deinit(self.allocator);
            self.header_hook = null;
        }
        if (self.footer_hook) |*existing| {
            existing.deinit(self.allocator);
            self.footer_hook = null;
        }
        for (self.terminal_input_subs.items) |*sub| sub.deinit(self.allocator);
        self.terminal_input_subs.clearRetainingCapacity();
        if (self.editor_component_hook) |*existing| {
            existing.deinit(self.allocator);
            self.editor_component_hook = null;
        }
    }
};

fn makeTerminalInputSubscription(
    allocator: std.mem.Allocator,
    id: []const u8,
    consume: bool,
    transform_to: ?[]const u8,
    extension_path: []const u8,
) !TerminalInputSubscription {
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const transform_dup = if (transform_to) |t| try allocator.dupe(u8, t) else null;
    errdefer if (transform_dup) |t| allocator.free(t);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .id = id_dup,
        .consume = consume,
        .transform_to = transform_dup,
        .extension_path = path_dup,
    };
}

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

/// CLI-parsed flag value the runtime layer hands back to the registry
/// after parsing `--<name> [value]`. The string payload is borrowed;
/// `Registry.setFlagValue` clones what it stores.
pub const ParsedCliFlag = struct {
    name: []const u8,
    value: FlagDefaultInput,
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

/// Render a deterministic JSON snapshot of the registry to `writer` for
/// CLI/TS-RPC observability. The snapshot includes tools/labels/
/// descriptions, commands/descriptions, shortcuts, flag definitions
/// with parsed CLI values resolved through `getFlag()`, providers +
/// models, and the captured UI request ids. Order is registration
/// order to match the underlying ArrayList storage and the
/// TypeScript listing order.
pub fn writeRegistrySnapshotJson(
    allocator: std.mem.Allocator,
    registry: *const Registry,
    writer: *std.Io.Writer,
) !void {
    const value = try buildRegistryJsonValue(allocator, registry);
    defer deinitJsonValueLocal(allocator, value);
    try std.json.Stringify.value(value, .{}, writer);
}

fn buildRegistryJsonValue(allocator: std.mem.Allocator, registry: *const Registry) !std.json.Value {
    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});

    var tools_array = std.json.Array.init(allocator);
    for (registry.tools.items) |tool| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try entry.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, tool.label) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, tool.extension_path) });
        try tools_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = tools_array });

    var commands_array = std.json.Array.init(allocator);
    for (registry.commands.items) |cmd| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, cmd.name) });
        try entry.put(allocator, try allocator.dupe(u8, "description"), try optionalStringJson(allocator, cmd.description));
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, cmd.extension_path) });
        try commands_array.append(.{ .object = entry });
    }
    try root.put(allocator, try allocator.dupe(u8, "commands"), .{ .array = commands_array });

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

    var providers_array = std.json.Array.init(allocator);
    for (registry.providers.items) |p| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, p.name) });
        try entry.put(allocator, try allocator.dupe(u8, "displayName"), try optionalStringJson(allocator, p.display_name));
        try entry.put(allocator, try allocator.dupe(u8, "baseUrl"), try optionalStringJson(allocator, p.base_url));
        try entry.put(allocator, try allocator.dupe(u8, "api"), try optionalStringJson(allocator, p.api));
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

    var ids_array = std.json.Array.init(allocator);
    for (registry.ui_request_ids.items) |id| {
        try ids_array.append(.{ .string = try allocator.dupe(u8, id) });
    }
    try root.put(allocator, try allocator.dupe(u8, "uiRequestIds"), .{ .array = ids_array });

    try root.put(allocator, try allocator.dupe(u8, "headerHook"), try injectionHookJson(allocator, registry.header_hook));
    try root.put(allocator, try allocator.dupe(u8, "footerHook"), try injectionHookJson(allocator, registry.footer_hook));

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

    if (registry.editor_component_hook) |hook| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try entry.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, hook.label) });
        try entry.put(allocator, try allocator.dupe(u8, "extensionPath"), .{ .string = try allocator.dupe(u8, hook.extension_path) });
        try root.put(allocator, try allocator.dupe(u8, "editorComponentHook"), .{ .object = entry });
    } else {
        try root.put(allocator, try allocator.dupe(u8, "editorComponentHook"), .null);
    }

    return .{ .object = root };
}

fn injectionHookJson(allocator: std.mem.Allocator, hook: ?InjectionHook) !std.json.Value {
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

fn flagDefaultToJson(allocator: std.mem.Allocator, default: FlagDefault) !std.json.Value {
    return switch (default) {
        .none => .null,
        .boolean => |b| .{ .bool = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

fn flagValueToJson(allocator: std.mem.Allocator, value: FlagValue) !std.json.Value {
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
    set_header_hook,
    cleared_header_hook,
    set_footer_hook,
    cleared_footer_hook,
    registered_terminal_input,
    unregistered_terminal_input,
    set_editor_component_hook,
    cleared_editor_component_hook,
    cleared_ui_hooks_for_reload,
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

    if (std.mem.eql(u8, type_name, "set_header")) {
        const lines = try optionalLinesArray(registry.allocator, object, "lines");
        defer registry.allocator.free(lines);
        try registry.setHeaderHook(lines, extension_path);
        return .set_header_hook;
    }
    if (std.mem.eql(u8, type_name, "clear_header")) {
        _ = registry.clearHeaderHook();
        return .cleared_header_hook;
    }
    if (std.mem.eql(u8, type_name, "set_footer")) {
        const lines = try optionalLinesArray(registry.allocator, object, "lines");
        defer registry.allocator.free(lines);
        try registry.setFooterHook(lines, extension_path);
        return .set_footer_hook;
    }
    if (std.mem.eql(u8, type_name, "clear_footer")) {
        _ = registry.clearFooterHook();
        return .cleared_footer_hook;
    }
    if (std.mem.eql(u8, type_name, "register_terminal_input")) {
        const id = optionalString(object, "id") orelse return .ignored_malformed;
        const consume = optionalBool(object, "consume") orelse false;
        const transform_to = optionalString(object, "transformTo");
        try registry.registerTerminalInput(id, consume, transform_to, extension_path);
        return .registered_terminal_input;
    }
    if (std.mem.eql(u8, type_name, "unregister_terminal_input")) {
        const id = optionalString(object, "id") orelse return .ignored_malformed;
        _ = registry.unregisterTerminalInput(id);
        return .unregistered_terminal_input;
    }
    if (std.mem.eql(u8, type_name, "set_editor_component")) {
        const label = optionalString(object, "label") orelse return .ignored_malformed;
        try registry.setEditorComponentHook(label, extension_path);
        return .set_editor_component_hook;
    }
    if (std.mem.eql(u8, type_name, "clear_editor_component")) {
        _ = registry.clearEditorComponentHook();
        return .cleared_editor_component_hook;
    }
    if (std.mem.eql(u8, type_name, "clear_ui_hooks_for_reload")) {
        registry.clearUiHooksForReload();
        return .cleared_ui_hooks_for_reload;
    }

    return .ignored_unsupported;
}

fn optionalBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn optionalLinesArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) ![][]const u8 {
    const value = object.get(field) orelse return try allocator.alloc([]const u8, 0);
    if (value != .array) return try allocator.alloc([]const u8, 0);
    var collected = std.ArrayList([]const u8).empty;
    defer collected.deinit(allocator);
    for (value.array.items) |item| {
        if (item != .string) continue;
        try collected.append(allocator, item.string);
    }
    return try collected.toOwnedSlice(allocator);
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
        error.FileNotFound, error.NotDir, error.IsDir => {},
        else => return err,
    }

    const dir_manifest = try std.fs.path.join(allocator, &[_][]const u8{ path, "registry.jsonl" });
    defer allocator.free(dir_manifest);
    return std.Io.Dir.readFileAlloc(.cwd(), io, dir_manifest, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.NotDir, error.IsDir => return error.FileNotFound,
        else => return err,
    };
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

// --------------------------------------------------------------------------
// M11 extension UI hooks tests
// --------------------------------------------------------------------------

test "M11 setHeaderHook and setFooterHook are single-slot and replaceable" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const v1 = [_][]const u8{ "Header v1 line 1", "Header v1 line 2" };
    try registry.setHeaderHook(&v1, "fixture/extension.ts");
    try std.testing.expect(registry.header_hook != null);
    try std.testing.expectEqual(@as(usize, 2), registry.header_hook.?.lines.len);
    try std.testing.expectEqualStrings("Header v1 line 1", registry.header_hook.?.lines[0]);

    // Replace; previous hook bytes are freed and the new content wins.
    const v2 = [_][]const u8{"Header v2 only line"};
    try registry.setHeaderHook(&v2, "fixture/extension.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.header_hook.?.lines.len);
    try std.testing.expectEqualStrings("Header v2 only line", registry.header_hook.?.lines[0]);

    // Footer mirrors the header API.
    const f1 = [_][]const u8{ "Footer A", "Footer B" };
    try registry.setFooterHook(&f1, "fixture/extension.ts");
    try std.testing.expect(registry.footer_hook != null);
    try std.testing.expectEqualStrings("Footer A", registry.footer_hook.?.lines[0]);

    // Clearing returns true the first time and false the second.
    try std.testing.expect(registry.clearHeaderHook());
    try std.testing.expect(!registry.clearHeaderHook());
    try std.testing.expect(registry.clearFooterHook());
    try std.testing.expect(!registry.clearFooterHook());
}

test "M11 terminal input subscriptions support consume / transform / unsubscribe" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Pure observer (no consume, no transform) leaves bytes intact.
    try registry.registerTerminalInput("observer", false, null, "fixture/extension.ts");

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);
    var result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("hello", result.data);

    // Transform handler rewrites bytes.
    try registry.registerTerminalInput("transform", false, "world", "fixture/extension.ts");
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("world", result.data);

    // Consume handler stops propagation.
    try registry.registerTerminalInput("consumer", true, null, "fixture/extension.ts");
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(result.consumed);

    // Unsubscribing the consumer restores propagation through the
    // remaining transform handler.
    try std.testing.expect(registry.unregisterTerminalInput("consumer"));
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("world", result.data);

    // Unsubscribing the transform handler returns to the original
    // observer-only behavior.
    try std.testing.expect(registry.unregisterTerminalInput("transform"));
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("hello", result.data);

    // Unsubscribe returns false for an unknown id and the registry is
    // left intact.
    try std.testing.expect(!registry.unregisterTerminalInput("does-not-exist"));
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);
}

test "M11 setEditorComponentHook is single-slot and clearable" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.setEditorComponentHook("VimEditor", "fixture/extension.ts");
    try std.testing.expect(registry.editor_component_hook != null);
    try std.testing.expectEqualStrings("VimEditor", registry.editor_component_hook.?.label);

    try registry.setEditorComponentHook("EmacsEditor", "fixture/extension.ts");
    try std.testing.expectEqualStrings("EmacsEditor", registry.editor_component_hook.?.label);

    try std.testing.expect(registry.clearEditorComponentHook());
    try std.testing.expect(!registry.clearEditorComponentHook());
    try std.testing.expect(registry.editor_component_hook == null);
}

test "M11 clearUiHooksForReload drops UI hooks but keeps static registrations" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Static surfaces.
    try registry.registerTool("greet", "Greet", "Greets", "fixture/extension.ts");
    try registry.registerCommand("greet", "Slash command", "fixture/extension.ts");
    try registry.registerFlag("plan", .boolean, null, .{ .boolean = true }, "fixture/extension.ts");

    // UI hooks.
    const lines = [_][]const u8{"Header"};
    try registry.setHeaderHook(&lines, "fixture/extension.ts");
    try registry.setFooterHook(&lines, "fixture/extension.ts");
    try registry.registerTerminalInput("sub-1", true, null, "fixture/extension.ts");
    try registry.setEditorComponentHook("VimEditor", "fixture/extension.ts");

    registry.clearUiHooksForReload();

    // Hooks gone.
    try std.testing.expect(registry.header_hook == null);
    try std.testing.expect(registry.footer_hook == null);
    try std.testing.expectEqual(@as(usize, 0), registry.terminal_input_subs.items.len);
    try std.testing.expect(registry.editor_component_hook == null);

    // Static registrations preserved.
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.flags.items.len);
}

test "M11 applyHostFrameStream covers UI hook frame types end-to-end" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "set_header", "lines": ["Header line A", "Header line B"], "extensionPath": "fixture/extension.ts" }
        \\{ "type": "set_footer", "lines": ["Footer line"], "extensionPath": "fixture/extension.ts" }
        \\{ "type": "register_terminal_input", "id": "consumer", "consume": true, "extensionPath": "fixture/extension.ts" }
        \\{ "type": "register_terminal_input", "id": "transform", "consume": false, "transformTo": "rewritten", "extensionPath": "fixture/extension.ts" }
        \\{ "type": "set_editor_component", "label": "VimEditor", "extensionPath": "fixture/extension.ts" }
        \\
    ;
    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 5), applied);

    try std.testing.expect(registry.header_hook != null);
    try std.testing.expectEqualStrings("Header line A", registry.header_hook.?.lines[0]);
    try std.testing.expect(registry.footer_hook != null);
    try std.testing.expectEqual(@as(usize, 2), registry.terminal_input_subs.items.len);
    try std.testing.expect(registry.editor_component_hook != null);
    try std.testing.expectEqualStrings("VimEditor", registry.editor_component_hook.?.label);

    // Removing one terminal input subscription via JSONL.
    const remove_frame =
        \\{ "type": "unregister_terminal_input", "id": "consumer" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, remove_frame);
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);
    try std.testing.expectEqualStrings("transform", registry.terminal_input_subs.items[0].id);

    // clear_header / clear_footer / clear_editor_component frames.
    const clear_frames =
        \\{ "type": "clear_header" }
        \\{ "type": "clear_footer" }
        \\{ "type": "clear_editor_component" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, clear_frames);
    try std.testing.expect(registry.header_hook == null);
    try std.testing.expect(registry.footer_hook == null);
    try std.testing.expect(registry.editor_component_hook == null);
    // Static surfaces and the surviving subscription remain.
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);

    // clear_ui_hooks_for_reload drops the surviving subscription too.
    const reload_frame =
        \\{ "type": "clear_ui_hooks_for_reload" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, reload_frame);
    try std.testing.expectEqual(@as(usize, 0), registry.terminal_input_subs.items.len);
}

test "M11 snapshot JSON includes UI hook state" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const lines = [_][]const u8{ "Header A", "Header B" };
    const single_line = [_][]const u8{"Header A"};
    try registry.setHeaderHook(&lines, "fixture/extension.ts");
    try registry.setFooterHook(&single_line, "fixture/extension.ts");
    try registry.registerTerminalInput("consumer", true, null, "fixture/extension.ts");
    try registry.registerTerminalInput("transform", false, "rewritten", "fixture/extension.ts");
    try registry.setEditorComponentHook("VimEditor", "fixture/extension.ts");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);

    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"headerHook\":{\"lines\":[\"Header A\",\"Header B\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"footerHook\":{\"lines\":[\"Header A\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"terminalInputSubscriptions\":[{\"id\":\"consumer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"transformTo\":\"rewritten\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"editorComponentHook\":{\"label\":\"VimEditor\"") != null);

    // After clearUiHooksForReload, the snapshot reflects empty hooks.
    registry.clearUiHooksForReload();
    var out2: std.Io.Writer.Allocating = .init(allocator);
    defer out2.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out2.writer);
    const snapshot2 = out2.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"headerHook\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"footerHook\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"terminalInputSubscriptions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"editorComponentHook\":null") != null);
}
