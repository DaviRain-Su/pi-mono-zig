const std = @import("std");
const tui = @import("tui");

pub const Action = enum(u8) {
    interrupt,
    exit,
    clear,
    open_sessions,
    open_models,
    queue_follow_up,
    dequeue_messages,
    paste_image,
    chat_scroll_to_tail,
};

pub const KeySpec = union(enum) {
    ctrl: u8,
    escape,
    enter,
    tab,
    shift_tab,
    alt_enter,
    alt_up,
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
    .{ .action = .interrupt, .id = "app.interrupt", .defaults = &.{"ctrl+c"} },
    .{ .action = .exit, .id = "app.exit", .defaults = &.{ "ctrl+d", "escape" } },
    .{ .action = .clear, .id = "app.clear", .defaults = &.{"ctrl+l"} },
    .{ .action = .open_sessions, .id = "app.session.select", .defaults = &.{"ctrl+s"} },
    .{ .action = .open_models, .id = "app.model.select", .defaults = &.{"ctrl+p"} },
    .{ .action = .queue_follow_up, .id = "app.message.followUp", .defaults = &.{"alt+enter"} },
    .{ .action = .dequeue_messages, .id = "app.message.dequeue", .defaults = &.{"alt+up"} },
    .{ .action = .paste_image, .id = "app.clipboard.pasteImage", .defaults = &.{"ctrl+v"} },
    .{ .action = .chat_scroll_to_tail, .id = "app.chat.scrollToTail", .defaults = &.{"ctrl+g"} },
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

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return keybindings;

    for (DEFINITIONS) |definition| {
        const raw_binding = parsed.value.object.get(definition.id) orelse continue;
        const specs = parseBindingValue(allocator, raw_binding) catch continue;
        defer allocator.free(specs);
        try keybindings.setBinding(definition.action, specs);
    }

    return keybindings;
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

    if (std.mem.startsWith(u8, normalized, "ctrl+") and normalized.len == 6) {
        const value = normalized[5];
        if ((value >= 'a' and value <= 'z') or (value >= '0' and value <= '9')) {
            return .{ .ctrl = value };
        }
    }

    return null;
}

test "keybindings use defaults and allow overrides from file" {
    const allocator = std.testing.allocator;

    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();

    try std.testing.expectEqual(Action.clear, defaults.actionForKey(.{ .ctrl = 'l' }).?);
    try std.testing.expectEqual(Action.exit, defaults.actionForKey(.{ .ctrl = 'd' }).?);
    try std.testing.expectEqual(Action.exit, defaults.actionForKey(.escape).?);
    try std.testing.expectEqual(Action.queue_follow_up, defaults.actionForKeyWithModifiers(.enter, .{ .alt = true }).?);
    try std.testing.expectEqual(Action.dequeue_messages, defaults.actionForKeyWithModifiers(.up, .{ .alt = true }).?);
    try std.testing.expectEqual(Action.paste_image, defaults.actionForKey(.{ .ctrl = 'v' }).?);
    try std.testing.expectEqual(Action.chat_scroll_to_tail, defaults.actionForKey(.{ .ctrl = 'g' }).?);

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
        \\  "app.chat.scrollToTail": "ctrl+z"
        \\}
        ,
    });

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "keybindings.json" });
    defer allocator.free(config_path);

    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();

    try std.testing.expectEqual(Action.clear, loaded.actionForKey(.{ .ctrl = 'x' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'l' }) == null);
    try std.testing.expectEqual(Action.exit, loaded.actionForKey(.{ .ctrl = 'q' }).?);
    try std.testing.expect(loaded.actionForKey(.escape) == null);
    try std.testing.expectEqual(Action.queue_follow_up, loaded.actionForKeyWithModifiers(.up, .{ .alt = true }).?);
    try std.testing.expectEqual(Action.dequeue_messages, loaded.actionForKeyWithModifiers(.enter, .{ .alt = true }).?);
    try std.testing.expectEqual(Action.paste_image, loaded.actionForKey(.{ .ctrl = 'y' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'v' }) == null);
    try std.testing.expectEqual(Action.chat_scroll_to_tail, loaded.actionForKey(.{ .ctrl = 'z' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'g' }) == null);
}
