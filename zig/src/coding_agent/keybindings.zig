const std = @import("std");
const tui = @import("tui");

pub const Action = enum(u8) {
    interrupt,
    exit,
    clear,
    open_sessions,
    open_models,
    paste_image,
};

pub const KeySpec = union(enum) {
    ctrl: u8,
    escape,
    enter,
    tab,
    shift_tab,
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

    pub fn matches(self: KeySpec, key: tui.Key) bool {
        return switch (self) {
            .ctrl => |value| switch (key) {
                .ctrl => |pressed| pressed == value,
                else => false,
            },
            .escape => key == .escape,
            .enter => key == .enter,
            .tab => key == .tab,
            .shift_tab => key == .shift_tab,
            .up => key == .up,
            .down => key == .down,
            .left => key == .left,
            .right => key == .right,
            .home => key == .home,
            .end => key == .end,
            .page_up => key == .page_up,
            .page_down => key == .page_down,
            .backspace => key == .backspace,
            .delete => key == .delete,
        };
    }

    pub fn format(self: KeySpec, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .ctrl => |value| std.fmt.allocPrint(allocator, "Ctrl+{c}", .{std.ascii.toUpper(value)}),
            .escape => allocator.dupe(u8, "Esc"),
            .enter => allocator.dupe(u8, "Enter"),
            .tab => allocator.dupe(u8, "Tab"),
            .shift_tab => allocator.dupe(u8, "Shift+Tab"),
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
    .{ .action = .paste_image, .id = "app.clipboard.pasteImage", .defaults = &.{"ctrl+v"} },
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
        for (DEFINITIONS, 0..) |definition, index| {
            for (self.bindings[index]) |spec| {
                if (spec.matches(key)) return definition.action;
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
    try std.testing.expectEqual(Action.paste_image, defaults.actionForKey(.{ .ctrl = 'v' }).?);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "app.clear": "ctrl+x",
        \\  "app.exit": ["ctrl+q"],
        \\  "app.clipboard.pasteImage": "ctrl+y"
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
    try std.testing.expectEqual(Action.paste_image, loaded.actionForKey(.{ .ctrl = 'y' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'v' }) == null);
}
