const std = @import("std");
const tui = @import("tui");

pub const Action = enum(u8) {
    interrupt,
    clear,
    exit,
    app_suspend,
    thinking_cycle,
    model_cycleForward,
    model_cycleBackward,
    model_select,
    tools_expand,
    thinking_toggle,
    session_toggleNamedFilter,
    editor_external,
    message_followUp,
    message_dequeue,
    clipboard_pasteImage,
    session_new,
    session_tree,
    session_fork,
    session_resume,
    tree_foldOrUp,
    tree_unfoldOrDown,
    tree_editLabel,
    tree_toggleLabelTimestamp,
    session_togglePath,
    session_toggleSort,
    session_rename,
    session_delete,
    session_deleteNoninvasive,
    models_save,
    models_enableAll,
    models_clearAll,
    models_toggleProvider,
    models_reorderUp,
    models_reorderDown,
    tree_filter_default,
    tree_filter_noTools,
    tree_filter_userOnly,
    tree_filter_labeledOnly,
    tree_filter_all,
    tree_filter_cycleForward,
    tree_filter_cycleBackward,
};

pub const KeySpec = union(enum) {
    ctrl: u8,
    escape,
    enter,
    tab,
    shift_tab,
    alt_enter,
    alt_up,
    alt_down,
    alt_left,
    alt_right,
    ctrl_left,
    ctrl_right,
    ctrl_backspace,
    shift_char: u8,
    shift_ctrl_char: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    backspace,
    delete,

    pub fn matches(self: KeySpec, key: tui.Key, modifiers: tui.keys.KeyModifiers) bool {
        return switch (self) {
            .ctrl => |value| switch (key) {
                .ctrl => |pressed| pressed == value and !modifiers.hasAny(),
                else => false,
            },
            .escape => key == .escape and !modifiers.hasAny(),
            .enter => key == .enter and !modifiers.hasAny(),
            .tab => key == .tab and !modifiers.hasAny(),
            .shift_tab => key == .shift_tab and !modifiers.hasAny(),
            .alt_enter => key == .enter and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
            .alt_up => key == .up and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
            .alt_down => key == .down and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
            .alt_left => key == .left and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
            .alt_right => key == .right and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
            .ctrl_left => key == .ctrl_left and !modifiers.hasAny(),
            .ctrl_right => key == .ctrl_right and !modifiers.hasAny(),
            .ctrl_backspace => key == .backspace and modifiers.ctrl and !modifiers.shift and !modifiers.alt and !modifiers.super,
            .shift_char => |letter| blk: {
                break :blk switch (key) {
                    .printable => |pk| pk.slice().len == 1 and
                        (pk.slice()[0] == letter or pk.slice()[0] == std.ascii.toUpper(letter)) and
                        modifiers.shift and !modifiers.ctrl and !modifiers.alt and !modifiers.super,
                    else => false,
                };
            },
            .shift_ctrl_char => |letter| blk: {
                // Match both:
                // - printable "P" with shift+ctrl (modern kitty terminals)
                // - ctrl 'p' with shift modifier (some terminal emulators / unit tests)
                break :blk switch (key) {
                    .printable => |pk| pk.slice().len == 1 and
                        (pk.slice()[0] == letter or pk.slice()[0] == std.ascii.toUpper(letter)) and
                        modifiers.shift and modifiers.ctrl and !modifiers.alt and !modifiers.super,
                    .ctrl => |c| c == letter and modifiers.shift and !modifiers.alt and !modifiers.super,
                    else => false,
                };
            },
            .up => key == .up and !modifiers.hasAny(),
            .down => key == .down and !modifiers.hasAny(),
            .left => key == .left and !modifiers.hasAny(),
            .right => key == .right and !modifiers.hasAny(),
            .home => key == .home and !modifiers.hasAny(),
            .end => key == .end and !modifiers.hasAny(),
            .page_up => key == .page_up and !modifiers.hasAny(),
            .page_down => key == .page_down and !modifiers.hasAny(),
            .backspace => key == .backspace and !modifiers.hasAny(),
            .delete => key == .delete and !modifiers.hasAny(),
        };
    }

    pub fn format(self: KeySpec, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .ctrl => |value| std.fmt.allocPrint(allocator, "Ctrl+{c}", .{std.ascii.toUpper(value)}),
            .escape => allocator.dupe(u8, "Esc"),
            .enter => allocator.dupe(u8, "Enter"),
            .tab => allocator.dupe(u8, "Tab"),
            .shift_tab => allocator.dupe(u8, "Shift+Tab"),
            .alt_enter => allocator.dupe(u8, "Alt+Enter"),
            .alt_up => allocator.dupe(u8, "Alt+Up"),
            .alt_down => allocator.dupe(u8, "Alt+Down"),
            .alt_left => allocator.dupe(u8, "Alt+Left"),
            .alt_right => allocator.dupe(u8, "Alt+Right"),
            .ctrl_left => allocator.dupe(u8, "Ctrl+Left"),
            .ctrl_right => allocator.dupe(u8, "Ctrl+Right"),
            .ctrl_backspace => allocator.dupe(u8, "Ctrl+Backspace"),
            .shift_char => |letter| std.fmt.allocPrint(allocator, "Shift+{c}", .{std.ascii.toUpper(letter)}),
            .shift_ctrl_char => |letter| std.fmt.allocPrint(allocator, "Shift+Ctrl+{c}", .{std.ascii.toUpper(letter)}),
            .up => allocator.dupe(u8, "Up"),
            .down => allocator.dupe(u8, "Down"),
            .left => allocator.dupe(u8, "Left"),
            .right => allocator.dupe(u8, "Right"),
            .home => allocator.dupe(u8, "Home"),
            .end => allocator.dupe(u8, "End"),
            .page_up => allocator.dupe(u8, "PgUp"),
            .page_down => allocator.dupe(u8, "PgDn"),
            .backspace => allocator.dupe(u8, "Backspace"),
            .delete => allocator.dupe(u8, "Delete"),
        };
    }
};

const BindingDefinition = struct {
    action: Action,
    id: []const u8,
    defaults: []const []const u8,
};

const DEFINITIONS = [_]BindingDefinition{
    .{ .action = .interrupt, .id = "app.interrupt", .defaults = &.{"escape"} },
    .{ .action = .clear, .id = "app.clear", .defaults = &.{"ctrl+c"} },
    .{ .action = .exit, .id = "app.exit", .defaults = &.{"ctrl+d"} },
    .{ .action = .app_suspend, .id = "app.suspend", .defaults = &.{"ctrl+z"} },
    .{ .action = .thinking_cycle, .id = "app.thinking.cycle", .defaults = &.{"shift+tab"} },
    .{ .action = .model_cycleForward, .id = "app.model.cycleForward", .defaults = &.{"ctrl+p"} },
    .{ .action = .model_cycleBackward, .id = "app.model.cycleBackward", .defaults = &.{"shift+ctrl+p"} },
    .{ .action = .model_select, .id = "app.model.select", .defaults = &.{"ctrl+l"} },
    .{ .action = .tools_expand, .id = "app.tools.expand", .defaults = &.{"ctrl+o"} },
    .{ .action = .thinking_toggle, .id = "app.thinking.toggle", .defaults = &.{"ctrl+t"} },
    .{ .action = .session_toggleNamedFilter, .id = "app.session.toggleNamedFilter", .defaults = &.{"ctrl+n"} },
    .{ .action = .editor_external, .id = "app.editor.external", .defaults = &.{"ctrl+g"} },
    .{ .action = .message_followUp, .id = "app.message.followUp", .defaults = &.{"alt+enter"} },
    .{ .action = .message_dequeue, .id = "app.message.dequeue", .defaults = &.{"alt+up"} },
    .{ .action = .clipboard_pasteImage, .id = "app.clipboard.pasteImage", .defaults = &.{"ctrl+v"} },
    .{ .action = .session_new, .id = "app.session.new", .defaults = &.{} },
    .{ .action = .session_tree, .id = "app.session.tree", .defaults = &.{} },
    .{ .action = .session_fork, .id = "app.session.fork", .defaults = &.{} },
    .{ .action = .session_resume, .id = "app.session.resume", .defaults = &.{} },
    .{ .action = .tree_foldOrUp, .id = "app.tree.foldOrUp", .defaults = &.{ "ctrl+left", "alt+left" } },
    .{ .action = .tree_unfoldOrDown, .id = "app.tree.unfoldOrDown", .defaults = &.{ "ctrl+right", "alt+right" } },
    .{ .action = .tree_editLabel, .id = "app.tree.editLabel", .defaults = &.{"shift+l"} },
    .{ .action = .tree_toggleLabelTimestamp, .id = "app.tree.toggleLabelTimestamp", .defaults = &.{"shift+t"} },
    .{ .action = .session_togglePath, .id = "app.session.togglePath", .defaults = &.{"ctrl+p"} },
    .{ .action = .session_toggleSort, .id = "app.session.toggleSort", .defaults = &.{"ctrl+s"} },
    .{ .action = .session_rename, .id = "app.session.rename", .defaults = &.{"ctrl+r"} },
    .{ .action = .session_delete, .id = "app.session.delete", .defaults = &.{"ctrl+d"} },
    .{ .action = .session_deleteNoninvasive, .id = "app.session.deleteNoninvasive", .defaults = &.{"ctrl+backspace"} },
    .{ .action = .models_save, .id = "app.models.save", .defaults = &.{"ctrl+s"} },
    .{ .action = .models_enableAll, .id = "app.models.enableAll", .defaults = &.{"ctrl+a"} },
    .{ .action = .models_clearAll, .id = "app.models.clearAll", .defaults = &.{"ctrl+x"} },
    .{ .action = .models_toggleProvider, .id = "app.models.toggleProvider", .defaults = &.{"ctrl+p"} },
    .{ .action = .models_reorderUp, .id = "app.models.reorderUp", .defaults = &.{"alt+up"} },
    .{ .action = .models_reorderDown, .id = "app.models.reorderDown", .defaults = &.{"alt+down"} },
    .{ .action = .tree_filter_default, .id = "app.tree.filter.default", .defaults = &.{"ctrl+d"} },
    .{ .action = .tree_filter_noTools, .id = "app.tree.filter.noTools", .defaults = &.{"ctrl+t"} },
    .{ .action = .tree_filter_userOnly, .id = "app.tree.filter.userOnly", .defaults = &.{"ctrl+u"} },
    .{ .action = .tree_filter_labeledOnly, .id = "app.tree.filter.labeledOnly", .defaults = &.{"ctrl+l"} },
    .{ .action = .tree_filter_all, .id = "app.tree.filter.all", .defaults = &.{"ctrl+a"} },
    .{ .action = .tree_filter_cycleForward, .id = "app.tree.filter.cycleForward", .defaults = &.{"ctrl+o"} },
    .{ .action = .tree_filter_cycleBackward, .id = "app.tree.filter.cycleBackward", .defaults = &.{"shift+ctrl+o"} },
};

comptime {
    std.debug.assert(DEFINITIONS.len == 41);
    std.debug.assert(DEFINITIONS.len == @typeInfo(Action).@"enum".fields.len);
}

/// Legacy keybinding name → modern dotted ID migration table.
/// Matches TS KEYBINDING_NAME_MIGRATIONS (app-level entries only).
const LEGACY_MIGRATIONS = [_]struct { legacy: []const u8, modern: []const u8 }{
    .{ .legacy = "interrupt", .modern = "app.interrupt" },
    .{ .legacy = "clear", .modern = "app.clear" },
    .{ .legacy = "exit", .modern = "app.exit" },
    .{ .legacy = "suspend", .modern = "app.suspend" },
    .{ .legacy = "cycleThinkingLevel", .modern = "app.thinking.cycle" },
    .{ .legacy = "cycleModelForward", .modern = "app.model.cycleForward" },
    .{ .legacy = "cycleModelBackward", .modern = "app.model.cycleBackward" },
    .{ .legacy = "selectModel", .modern = "app.model.select" },
    .{ .legacy = "expandTools", .modern = "app.tools.expand" },
    .{ .legacy = "toggleThinking", .modern = "app.thinking.toggle" },
    .{ .legacy = "toggleSessionNamedFilter", .modern = "app.session.toggleNamedFilter" },
    .{ .legacy = "externalEditor", .modern = "app.editor.external" },
    .{ .legacy = "followUp", .modern = "app.message.followUp" },
    .{ .legacy = "dequeue", .modern = "app.message.dequeue" },
    .{ .legacy = "pasteImage", .modern = "app.clipboard.pasteImage" },
    .{ .legacy = "newSession", .modern = "app.session.new" },
    .{ .legacy = "tree", .modern = "app.session.tree" },
    .{ .legacy = "fork", .modern = "app.session.fork" },
    .{ .legacy = "resume", .modern = "app.session.resume" },
    .{ .legacy = "treeFoldOrUp", .modern = "app.tree.foldOrUp" },
    .{ .legacy = "treeUnfoldOrDown", .modern = "app.tree.unfoldOrDown" },
    .{ .legacy = "treeEditLabel", .modern = "app.tree.editLabel" },
    .{ .legacy = "treeToggleLabelTimestamp", .modern = "app.tree.toggleLabelTimestamp" },
    .{ .legacy = "toggleSessionPath", .modern = "app.session.togglePath" },
    .{ .legacy = "toggleSessionSort", .modern = "app.session.toggleSort" },
    .{ .legacy = "renameSession", .modern = "app.session.rename" },
    .{ .legacy = "deleteSession", .modern = "app.session.delete" },
    .{ .legacy = "deleteSessionNoninvasive", .modern = "app.session.deleteNoninvasive" },
};

pub const Keybindings = struct {
    allocator: std.mem.Allocator,
    bindings: [DEFINITIONS.len][]KeySpec,

    pub fn initDefaults(allocator: std.mem.Allocator) !Keybindings {
        var result = Keybindings{
            .allocator = allocator,
            .bindings = undefined,
        };
        errdefer result.deinit();

        for (DEFINITIONS, 0..) |definition, index| {
            result.bindings[index] = try parseBindingList(allocator, definition.defaults);
        }
        return result;
    }

    pub fn deinit(self: *Keybindings) void {
        for (&self.bindings) |*binding| {
            self.allocator.free(binding.*);
        }
        self.* = undefined;
    }

    pub fn setBinding(self: *Keybindings, action: Action, specs: []const KeySpec) !void {
        const index = @intFromEnum(action);
        const owned = try self.allocator.dupe(KeySpec, specs);
        self.allocator.free(self.bindings[index]);
        self.bindings[index] = owned;
    }

    pub fn actionForKey(self: *const Keybindings, key: tui.Key) ?Action {
        return self.actionForKeyWithModifiers(key, .{});
    }

    pub fn actionForKeyWithModifiers(
        self: *const Keybindings,
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
    ) ?Action {
        for (DEFINITIONS, 0..) |definition, index| {
            for (self.bindings[index]) |spec| {
                if (spec.matches(key, modifiers)) return definition.action;
            }
        }
        return null;
    }

    pub fn primaryLabel(self: *const Keybindings, allocator: std.mem.Allocator, action: Action) ![]u8 {
        const binding = self.bindings[@intFromEnum(action)];
        if (binding.len == 0) return allocator.dupe(u8, "Unbound");
        return binding[0].format(allocator);
    }
};

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Keybindings {
    var keybindings = try Keybindings.initDefaults(allocator);
    errdefer keybindings.deinit();

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return keybindings,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return keybindings;
    defer parsed.deinit();

    if (parsed.value != .object) return keybindings;

    // Build a migration-resolved config: apply legacy name migrations.
    // Modern name takes precedence over legacy when both are present.
    var resolved = std.StringHashMap(std.json.Value).init(allocator);
    defer resolved.deinit();

    for (parsed.value.object.keys(), parsed.value.object.values()) |key, value| {
        // Check if this is a legacy name and find the modern equivalent.
        const modern_key = legacyToModern(key) orelse key;
        // If modern key is already present (from an explicit modern entry), skip the legacy one.
        if (std.mem.eql(u8, modern_key, key)) {
            // Not a legacy name, or no migration found: use as-is.
            try resolved.put(key, value);
        } else {
            // This is a legacy name. Only add if the modern name is not already present.
            if (!parsed.value.object.contains(modern_key)) {
                try resolved.put(modern_key, value);
            }
        }
    }

    for (DEFINITIONS) |definition| {
        const raw_binding = resolved.get(definition.id) orelse continue;
        const specs = parseBindingValue(allocator, raw_binding) catch continue;
        defer allocator.free(specs);
        try keybindings.setBinding(definition.action, specs);
    }

    return keybindings;
}

fn legacyToModern(key: []const u8) ?[]const u8 {
    for (LEGACY_MIGRATIONS) |migration| {
        if (std.mem.eql(u8, migration.legacy, key)) return migration.modern;
    }
    return null;
}

fn parseBindingValue(allocator: std.mem.Allocator, value: std.json.Value) ![]KeySpec {
    return switch (value) {
        .string => |binding| parseBindingList(allocator, &.{binding}),
        .array => |items| blk: {
            var values = std.ArrayList([]const u8).empty;
            defer values.deinit(allocator);

            for (items.items) |item| {
                if (item != .string) continue;
                try values.append(allocator, item.string);
            }
            break :blk parseBindingList(allocator, values.items);
        },
        else => allocator.dupe(KeySpec, &.{}),
    };
}

fn parseBindingList(allocator: std.mem.Allocator, entries: []const []const u8) ![]KeySpec {
    var specs = std.ArrayList(KeySpec).empty;
    defer specs.deinit(allocator);

    for (entries) |entry| {
        const spec = parseKeySpec(entry) orelse continue;
        try specs.append(allocator, spec);
    }

    return specs.toOwnedSlice(allocator);
}

fn parseKeySpec(raw: []const u8) ?KeySpec {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    var buffer: [64]u8 = undefined;
    if (trimmed.len > buffer.len) return null;
    for (trimmed, 0..) |byte, index| {
        buffer[index] = std.ascii.toLower(byte);
    }
    const normalized = buffer[0..trimmed.len];

    if (std.mem.eql(u8, normalized, "escape") or std.mem.eql(u8, normalized, "esc")) return .escape;
    if (std.mem.eql(u8, normalized, "enter") or std.mem.eql(u8, normalized, "return")) return .enter;
    if (std.mem.eql(u8, normalized, "tab")) return .tab;
    if (std.mem.eql(u8, normalized, "shift+tab")) return .shift_tab;
    if (std.mem.eql(u8, normalized, "alt+enter")) return .alt_enter;
    if (std.mem.eql(u8, normalized, "alt+up")) return .alt_up;
    if (std.mem.eql(u8, normalized, "alt+down")) return .alt_down;
    if (std.mem.eql(u8, normalized, "alt+left")) return .alt_left;
    if (std.mem.eql(u8, normalized, "alt+right")) return .alt_right;
    if (std.mem.eql(u8, normalized, "ctrl+left")) return .ctrl_left;
    if (std.mem.eql(u8, normalized, "ctrl+right")) return .ctrl_right;
    if (std.mem.eql(u8, normalized, "ctrl+backspace")) return .ctrl_backspace;
    if (std.mem.eql(u8, normalized, "up")) return .up;
    if (std.mem.eql(u8, normalized, "down")) return .down;
    if (std.mem.eql(u8, normalized, "left")) return .left;
    if (std.mem.eql(u8, normalized, "right")) return .right;
    if (std.mem.eql(u8, normalized, "home")) return .home;
    if (std.mem.eql(u8, normalized, "end")) return .end;
    if (std.mem.eql(u8, normalized, "pageup") or std.mem.eql(u8, normalized, "page_up")) return .page_up;
    if (std.mem.eql(u8, normalized, "pagedown") or std.mem.eql(u8, normalized, "page_down")) return .page_down;
    if (std.mem.eql(u8, normalized, "backspace")) return .backspace;
    if (std.mem.eql(u8, normalized, "delete") or std.mem.eql(u8, normalized, "del")) return .delete;

    // shift+ctrl+<letter>: e.g. "shift+ctrl+p"
    if (std.mem.startsWith(u8, normalized, "shift+ctrl+") and normalized.len == 12) {
        const value = normalized[11];
        if (value >= 'a' and value <= 'z') {
            return .{ .shift_ctrl_char = value };
        }
    }

    // ctrl+<letter or digit>: e.g. "ctrl+c", "ctrl+0"
    if (std.mem.startsWith(u8, normalized, "ctrl+") and normalized.len == 6) {
        const value = normalized[5];
        if ((value >= 'a' and value <= 'z') or (value >= '0' and value <= '9')) {
            return .{ .ctrl = value };
        }
    }

    // shift+<letter>: e.g. "shift+l", "shift+t"
    if (std.mem.startsWith(u8, normalized, "shift+") and normalized.len == 7) {
        const value = normalized[6];
        if (value >= 'a' and value <= 'z') {
            return .{ .shift_char = value };
        }
    }

    return null;
}

test "keybinding definitions count matches action enum" {
    try std.testing.expectEqual(41, DEFINITIONS.len);
    try std.testing.expectEqual(41, @typeInfo(Action).@"enum".fields.len);
}

test "keybinding definition IDs are unique" {
    for (DEFINITIONS, 0..) |def_a, i| {
        for (DEFINITIONS, 0..) |def_b, j| {
            if (i == j) continue;
            try std.testing.expect(!std.mem.eql(u8, def_a.id, def_b.id));
        }
    }
}

test "keybinding definition actions are unique" {
    for (DEFINITIONS, 0..) |def_a, i| {
        for (DEFINITIONS, 0..) |def_b, j| {
            if (i == j) continue;
            try std.testing.expect(def_a.action != def_b.action);
        }
    }
}

test "keybinding definition actions match enum index order" {
    for (DEFINITIONS, 0..) |def, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), @intFromEnum(def.action));
    }
}

test "keybinding interrupt/clear/exit defaults match TS" {
    const allocator = std.testing.allocator;
    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();

    // interrupt = escape (not ctrl+c)
    try std.testing.expectEqual(Action.interrupt, defaults.actionForKey(.escape).?);
    try std.testing.expect(defaults.actionForKey(.{ .ctrl = 'c' }).? != Action.interrupt);

    // clear = ctrl+c (not ctrl+l)
    try std.testing.expectEqual(Action.clear, defaults.actionForKey(.{ .ctrl = 'c' }).?);
    try std.testing.expect(defaults.actionForKey(.{ .ctrl = 'l' }) != null); // ctrl+l is model_select now

    // exit = ctrl+d only (escape is no longer in exit defaults)
    try std.testing.expectEqual(Action.exit, defaults.actionForKey(.{ .ctrl = 'd' }).?);
    try std.testing.expectEqual(Action.interrupt, defaults.actionForKey(.escape).?);
}

test "keybinding new defaults match TS" {
    const allocator = std.testing.allocator;
    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();

    // app.suspend → ctrl+z
    try std.testing.expectEqual(Action.app_suspend, defaults.actionForKey(.{ .ctrl = 'z' }).?);

    // app.thinking.cycle → shift+tab
    try std.testing.expectEqual(Action.thinking_cycle, defaults.actionForKey(.shift_tab).?);

    // app.model.cycleForward → ctrl+p
    try std.testing.expectEqual(Action.model_cycleForward, defaults.actionForKey(.{ .ctrl = 'p' }).?);

    // app.model.cycleBackward → shift+ctrl+p
    try std.testing.expectEqual(Action.model_cycleBackward, defaults.actionForKeyWithModifiers(.{ .ctrl = 'p' }, .{ .shift = true }).?);

    // app.model.select → ctrl+l
    try std.testing.expectEqual(Action.model_select, defaults.actionForKey(.{ .ctrl = 'l' }).?);

    // app.tools.expand → ctrl+o
    try std.testing.expectEqual(Action.tools_expand, defaults.actionForKey(.{ .ctrl = 'o' }).?);

    // app.thinking.toggle → ctrl+t
    try std.testing.expectEqual(Action.thinking_toggle, defaults.actionForKey(.{ .ctrl = 't' }).?);

    // app.session.toggleNamedFilter → ctrl+n
    try std.testing.expectEqual(Action.session_toggleNamedFilter, defaults.actionForKey(.{ .ctrl = 'n' }).?);

    // app.editor.external → ctrl+g
    try std.testing.expectEqual(Action.editor_external, defaults.actionForKey(.{ .ctrl = 'g' }).?);

    // app.message.followUp → alt+enter
    try std.testing.expectEqual(Action.message_followUp, defaults.actionForKeyWithModifiers(.enter, .{ .alt = true }).?);

    // app.message.dequeue → alt+up
    try std.testing.expectEqual(Action.message_dequeue, defaults.actionForKeyWithModifiers(.up, .{ .alt = true }).?);

    // app.clipboard.pasteImage → ctrl+v
    try std.testing.expectEqual(Action.clipboard_pasteImage, defaults.actionForKey(.{ .ctrl = 'v' }).?);

    // app.session.new/tree/fork/resume → empty defaults
    try std.testing.expectEqual(@as(usize, 0), defaults.bindings[@intFromEnum(Action.session_new)].len);
    try std.testing.expectEqual(@as(usize, 0), defaults.bindings[@intFromEnum(Action.session_tree)].len);
    try std.testing.expectEqual(@as(usize, 0), defaults.bindings[@intFromEnum(Action.session_fork)].len);
    try std.testing.expectEqual(@as(usize, 0), defaults.bindings[@intFromEnum(Action.session_resume)].len);

    // app.tree.foldOrUp → [ctrl+left, alt+left]
    try std.testing.expectEqual(Action.tree_foldOrUp, defaults.actionForKey(.ctrl_left).?);
    try std.testing.expectEqual(Action.tree_foldOrUp, defaults.actionForKeyWithModifiers(.left, .{ .alt = true }).?);

    // app.tree.unfoldOrDown → [ctrl+right, alt+right]
    try std.testing.expectEqual(Action.tree_unfoldOrDown, defaults.actionForKey(.ctrl_right).?);
    try std.testing.expectEqual(Action.tree_unfoldOrDown, defaults.actionForKeyWithModifiers(.right, .{ .alt = true }).?);

    // app.tree.editLabel → shift+l
    try std.testing.expectEqual(Action.tree_editLabel, defaults.actionForKeyWithModifiers(
        .{ .printable = tui.keys.PrintableKey.fromSlice("L") },
        .{ .shift = true },
    ).?);

    // app.tree.toggleLabelTimestamp → shift+t
    try std.testing.expectEqual(Action.tree_toggleLabelTimestamp, defaults.actionForKeyWithModifiers(
        .{ .printable = tui.keys.PrintableKey.fromSlice("T") },
        .{ .shift = true },
    ).?);

    // app.session.deleteNoninvasive → ctrl+backspace
    try std.testing.expectEqual(Action.session_deleteNoninvasive, defaults.actionForKeyWithModifiers(.backspace, .{ .ctrl = true }).?);

    // app.models.reorderUp → alt+up
    // Note: message_dequeue also defaults to alt+up; first match wins (message_dequeue is index 13, models_reorderUp is 33)
    // so alt+up resolves to message_dequeue in default config
    try std.testing.expectEqual(Action.message_dequeue, defaults.actionForKeyWithModifiers(.up, .{ .alt = true }).?);

    // app.models.reorderDown → alt+down
    try std.testing.expectEqual(Action.models_reorderDown, defaults.actionForKeyWithModifiers(.down, .{ .alt = true }).?);

    // app.tree.filter.cycleBackward → shift+ctrl+o
    try std.testing.expectEqual(Action.tree_filter_cycleBackward, defaults.actionForKeyWithModifiers(.{ .ctrl = 'o' }, .{ .shift = true }).?);
}

test "keybinding initDefaults produces 41 bindings" {
    const allocator = std.testing.allocator;
    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 41), defaults.bindings.len);
}

test "keybinding parseKeySpec handles all new formats" {
    // ctrl+left/right
    try std.testing.expectEqual(KeySpec.ctrl_left, parseKeySpec("ctrl+left").?);
    try std.testing.expectEqual(KeySpec.ctrl_right, parseKeySpec("ctrl+right").?);

    // alt+left/right/down
    try std.testing.expectEqual(KeySpec.alt_left, parseKeySpec("alt+left").?);
    try std.testing.expectEqual(KeySpec.alt_right, parseKeySpec("alt+right").?);
    try std.testing.expectEqual(KeySpec.alt_down, parseKeySpec("alt+down").?);

    // ctrl+backspace
    try std.testing.expectEqual(KeySpec.ctrl_backspace, parseKeySpec("ctrl+backspace").?);

    // shift+letter
    try std.testing.expectEqualDeep(KeySpec{ .shift_char = 'l' }, parseKeySpec("shift+l").?);
    try std.testing.expectEqualDeep(KeySpec{ .shift_char = 't' }, parseKeySpec("shift+t").?);

    // shift+ctrl+letter
    try std.testing.expectEqualDeep(KeySpec{ .shift_ctrl_char = 'p' }, parseKeySpec("shift+ctrl+p").?);
    try std.testing.expectEqualDeep(KeySpec{ .shift_ctrl_char = 'o' }, parseKeySpec("shift+ctrl+o").?);

    // Case insensitive input
    try std.testing.expectEqualDeep(KeySpec{ .shift_char = 'l' }, parseKeySpec("Shift+L").?);
    try std.testing.expectEqualDeep(KeySpec{ .shift_ctrl_char = 'p' }, parseKeySpec("Shift+Ctrl+P").?);

    // Existing formats still work
    try std.testing.expectEqual(KeySpec.shift_tab, parseKeySpec("shift+tab").?);
    try std.testing.expectEqual(KeySpec.escape, parseKeySpec("escape").?);
    try std.testing.expectEqualDeep(KeySpec{ .ctrl = 'c' }, parseKeySpec("ctrl+c").?);
}

test "keybinding shift_char matches uppercase printable key with shift modifier" {
    const spec = KeySpec{ .shift_char = 'l' };

    // Matches uppercase printable "L" with shift
    try std.testing.expect(spec.matches(
        .{ .printable = tui.keys.PrintableKey.fromSlice("L") },
        .{ .shift = true },
    ));

    // Also matches lowercase printable "l" with shift (fallback for some terminals)
    try std.testing.expect(spec.matches(
        .{ .printable = tui.keys.PrintableKey.fromSlice("l") },
        .{ .shift = true },
    ));

    // Does NOT match without shift modifier
    try std.testing.expect(!spec.matches(
        .{ .printable = tui.keys.PrintableKey.fromSlice("L") },
        .{},
    ));

    // Does NOT match with ctrl modifier
    try std.testing.expect(!spec.matches(
        .{ .printable = tui.keys.PrintableKey.fromSlice("L") },
        .{ .shift = true, .ctrl = true },
    ));
}

test "keybinding shift_ctrl_char matches both ctrl key and printable key" {
    const spec = KeySpec{ .shift_ctrl_char = 'p' };

    // Matches ctrl 'p' with shift (unit test / some terminals)
    try std.testing.expect(spec.matches(
        .{ .ctrl = 'p' },
        .{ .shift = true },
    ));

    // Matches printable "P" with shift+ctrl (kitty terminals)
    try std.testing.expect(spec.matches(
        .{ .printable = tui.keys.PrintableKey.fromSlice("P") },
        .{ .shift = true, .ctrl = true },
    ));

    // Does NOT match without shift
    try std.testing.expect(!spec.matches(.{ .ctrl = 'p' }, .{}));

    // Does NOT match without ctrl (would be shift_char then)
    try std.testing.expect(!spec.matches(
        .{ .printable = tui.keys.PrintableKey.fromSlice("P") },
        .{ .shift = true },
    ));
}

test "keybinding loadFromFile overrides defaults" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "app.clear": "ctrl+x",
        \\  "app.exit": ["ctrl+q"],
        \\  "app.message.followUp": "alt+up",
        \\  "app.message.dequeue": "alt+enter",
        \\  "app.clipboard.pasteImage": "ctrl+y",
        \\  "app.session.rename": "ctrl+9"
        \\}
        ,
    });

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "keybindings.json" });
    defer allocator.free(config_path);

    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();

    try std.testing.expectEqual(Action.clear, loaded.actionForKey(.{ .ctrl = 'x' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'c' }) == null);
    try std.testing.expectEqual(Action.exit, loaded.actionForKey(.{ .ctrl = 'q' }).?);
    try std.testing.expectEqual(Action.message_followUp, loaded.actionForKeyWithModifiers(.up, .{ .alt = true }).?);
    try std.testing.expectEqual(Action.message_dequeue, loaded.actionForKeyWithModifiers(.enter, .{ .alt = true }).?);
    try std.testing.expectEqual(Action.clipboard_pasteImage, loaded.actionForKey(.{ .ctrl = 'y' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'v' }) == null);
    try std.testing.expectEqual(Action.session_rename, loaded.actionForKey(.{ .ctrl = '9' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'r' }) == null);
}

test "keybinding loadFromFile handles missing file" {
    const allocator = std.testing.allocator;
    var loaded = try loadFromFile(allocator, std.testing.io, "/nonexistent/path/keybindings.json");
    defer loaded.deinit();
    // Should return defaults (interrupt = escape)
    try std.testing.expectEqual(Action.interrupt, loaded.actionForKey(.escape).?);
}

test "keybinding loadFromFile handles malformed JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = "not valid json" });
    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "bad.json" });
    defer allocator.free(config_path);

    // Malformed JSON falls back to defaults without error
    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();
    try std.testing.expectEqual(Action.interrupt, loaded.actionForKey(.escape).?);
}

test "keybinding loadFromFile ignores unknown keys" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "unknown.action": "ctrl+x",
        \\  "app.clear": "ctrl+9"
        \\}
        ,
    });

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "keybindings.json" });
    defer allocator.free(config_path);

    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();

    // Known key overridden
    try std.testing.expectEqual(Action.clear, loaded.actionForKey(.{ .ctrl = '9' }).?);
    // Default interrupt unchanged
    try std.testing.expectEqual(Action.interrupt, loaded.actionForKey(.escape).?);
}

test "keybinding loadFromFile legacy name migration" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "interrupt": "ctrl+x",
        \\  "clear": "ctrl+y",
        \\  "followUp": "ctrl+f",
        \\  "dequeue": "ctrl+e",
        \\  "pasteImage": "ctrl+i",
        \\  "newSession": "ctrl+q",
        \\  "tree": "ctrl+w",
        \\  "renameSession": "ctrl+9"
        \\}
        ,
    });

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "keybindings.json" });
    defer allocator.free(config_path);

    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();

    try std.testing.expectEqual(Action.interrupt, loaded.actionForKey(.{ .ctrl = 'x' }).?);
    try std.testing.expectEqual(Action.clear, loaded.actionForKey(.{ .ctrl = 'y' }).?);
    try std.testing.expectEqual(Action.message_followUp, loaded.actionForKey(.{ .ctrl = 'f' }).?);
    try std.testing.expectEqual(Action.message_dequeue, loaded.actionForKey(.{ .ctrl = 'e' }).?);
    try std.testing.expectEqual(Action.clipboard_pasteImage, loaded.actionForKey(.{ .ctrl = 'i' }).?);
    try std.testing.expectEqual(Action.session_new, loaded.actionForKey(.{ .ctrl = 'q' }).?);
    try std.testing.expectEqual(Action.session_tree, loaded.actionForKey(.{ .ctrl = 'w' }).?);
    try std.testing.expectEqual(Action.session_rename, loaded.actionForKey(.{ .ctrl = '9' }).?);
}

test "keybinding modern name takes precedence over legacy on collision" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both "interrupt" (legacy) and "app.interrupt" (modern) present.
    // Modern should win: ctrl+8, not ctrl+9.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "interrupt": "ctrl+9",
        \\  "app.interrupt": "ctrl+8"
        \\}
        ,
    });

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "keybindings.json" });
    defer allocator.free(config_path);

    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();

    try std.testing.expectEqual(Action.interrupt, loaded.actionForKey(.{ .ctrl = '8' }).?);
    // ctrl+9 (legacy value) must not map to interrupt; modern "ctrl+8" wins
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = '9' }) == null);
}

test "keybinding setBinding replaces all keys for action" {
    const allocator = std.testing.allocator;
    var kb = try Keybindings.initDefaults(allocator);
    defer kb.deinit();

    // Use ctrl+0 and ctrl+9 which have no default bindings
    try kb.setBinding(.clear, &.{.{ .ctrl = '0' }});
    try std.testing.expectEqual(Action.clear, kb.actionForKey(.{ .ctrl = '0' }).?);
    try std.testing.expect(kb.actionForKey(.{ .ctrl = 'c' }) == null);

    try kb.setBinding(.clear, &.{.{ .ctrl = '9' }});
    try std.testing.expectEqual(Action.clear, kb.actionForKey(.{ .ctrl = '9' }).?);
    try std.testing.expect(kb.actionForKey(.{ .ctrl = '0' }) == null);
}
