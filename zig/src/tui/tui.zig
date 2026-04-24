const std = @import("std");
const ansi = @import("ansi.zig");
const component_mod = @import("component.zig");
const terminal_mod = @import("terminal.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    terminal: *terminal_mod.Terminal,
    previous_lines: component_mod.LineList = .empty,
    previous_size: ?terminal_mod.Size = null,

    pub fn init(allocator: std.mem.Allocator, terminal: *terminal_mod.Terminal) Renderer {
        return .{
            .allocator = allocator,
            .terminal = terminal,
        };
    }

    pub fn deinit(self: *Renderer) void {
        component_mod.freeLines(self.allocator, &self.previous_lines);
        self.* = undefined;
    }

    pub fn render(self: *Renderer, root: component_mod.Component) !void {
        const size = try self.terminal.refreshSize();

        var new_lines = component_mod.LineList.empty;
        defer component_mod.freeLines(self.allocator, &new_lines);
        try root.renderInto(self.allocator, size.width, &new_lines);

        if (self.previous_size == null or self.previous_size.?.width != size.width or self.previous_size.?.height != size.height) {
            try self.fullRedraw(new_lines.items);
        } else {
            try self.diffRedraw(new_lines.items);
        }

        try self.replacePreviousLines(new_lines.items);
        self.previous_size = size;
    }

    fn fullRedraw(self: *Renderer, lines: []const []u8) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        try buffer.appendSlice(self.allocator, "\x1b[2J\x1b[H");
        for (lines, 0..) |line, index| {
            if (index > 0) try buffer.append(self.allocator, '\n');
            try buffer.appendSlice(self.allocator, line);
        }
        try self.terminal.write(buffer.items);
    }

    fn diffRedraw(self: *Renderer, lines: []const []u8) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        const max_lines = @max(lines.len, self.previous_lines.items.len);
        for (0..max_lines) |row| {
            const old_line = if (row < self.previous_lines.items.len) self.previous_lines.items[row] else "";
            const new_line = if (row < lines.len) lines[row] else "";
            if (std.mem.eql(u8, old_line, new_line)) continue;

            const cursor = try std.fmt.allocPrint(self.allocator, "\x1b[{d};1H\x1b[2K", .{row + 1});
            defer self.allocator.free(cursor);
            try buffer.appendSlice(self.allocator, cursor);
            try buffer.appendSlice(self.allocator, new_line);
        }

        if (buffer.items.len > 0) {
            try self.terminal.write(buffer.items);
        }
    }

    fn replacePreviousLines(self: *Renderer, lines: []const []u8) !void {
        component_mod.freeLines(self.allocator, &self.previous_lines);
        self.previous_lines = .empty;
        for (lines) |line| {
            try self.previous_lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }
};

test "differential renderer only redraws changed lines" {
    const allocator = std.testing.allocator;

    const MockBackend = struct {
        size: terminal_mod.Size = .{ .width = 12, .height = 4 },
        writes: std.ArrayList([]u8) = .empty,

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            for (self.writes.items) |entry| alloc.free(entry);
            self.writes.deinit(alloc);
        }

        fn backend(self: *@This()) terminal_mod.Backend {
            return .{
                .ptr = self,
                .enterRawModeFn = enterRawMode,
                .restoreModeFn = restoreMode,
                .writeFn = write,
                .getSizeFn = getSize,
            };
        }

        fn enterRawMode(_: *anyopaque) !void {}
        fn restoreMode(_: *anyopaque) !void {}

        fn write(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.writes.append(allocator, try allocator.dupe(u8, bytes));
        }

        fn getSize(ptr: *anyopaque) !terminal_mod.Size {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.size;
        }
    };

    const StaticComponent = struct {
        lines: []const []const u8,

        fn component(self: *const @This()) component_mod.Component {
            return .{
                .ptr = self,
                .renderIntoFn = renderIntoOpaque,
            };
        }

        fn renderInto(self: *const @This(), alloc: std.mem.Allocator, width: usize, lines: *component_mod.LineList) !void {
            for (self.lines) |line| {
                const padded = try ansi.padRightVisibleAlloc(alloc, line, width);
                defer alloc.free(padded);
                try component_mod.appendOwnedLine(lines, alloc, padded);
            }
        }

        fn renderIntoOpaque(ptr: *const anyopaque, alloc: std.mem.Allocator, width: usize, lines: *component_mod.LineList) !void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            try self.renderInto(alloc, width, lines);
        }
    };

    var backend = MockBackend{};
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const first = StaticComponent{ .lines = &[_][]const u8{ "alpha", "bravo", "charlie" } };
    try renderer.render(first.component());

    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[1], "\x1b[2J\x1b[H") != null);

    const baseline_write_count = backend.writes.items.len;
    const second = StaticComponent{ .lines = &[_][]const u8{ "alpha", "BRAVO", "charlie" } };
    try renderer.render(second.component());

    try std.testing.expectEqual(baseline_write_count + 1, backend.writes.items.len);
    const delta = backend.writes.items[backend.writes.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[2;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[1;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[3;1H") == null);
}

test "renderer performs a full redraw when the terminal size changes" {
    const allocator = std.testing.allocator;

    const MockBackend = struct {
        size: terminal_mod.Size = .{ .width = 10, .height = 3 },
        writes: std.ArrayList([]u8) = .empty,

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            for (self.writes.items) |entry| alloc.free(entry);
            self.writes.deinit(alloc);
        }

        fn backend(self: *@This()) terminal_mod.Backend {
            return .{
                .ptr = self,
                .enterRawModeFn = enterRawMode,
                .restoreModeFn = restoreMode,
                .writeFn = write,
                .getSizeFn = getSize,
            };
        }

        fn enterRawMode(_: *anyopaque) !void {}
        fn restoreMode(_: *anyopaque) !void {}

        fn write(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.writes.append(allocator, try allocator.dupe(u8, bytes));
        }

        fn getSize(ptr: *anyopaque) !terminal_mod.Size {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.size;
        }
    };

    const StaticComponent = struct {
        lines: []const []const u8,

        fn component(self: *const @This()) component_mod.Component {
            return .{
                .ptr = self,
                .renderIntoFn = renderIntoOpaque,
            };
        }

        fn renderInto(self: *const @This(), alloc: std.mem.Allocator, width: usize, lines: *component_mod.LineList) !void {
            for (self.lines) |line| {
                const padded = try ansi.padRightVisibleAlloc(alloc, line, width);
                defer alloc.free(padded);
                try component_mod.appendOwnedLine(lines, alloc, padded);
            }
        }

        fn renderIntoOpaque(ptr: *const anyopaque, alloc: std.mem.Allocator, width: usize, lines: *component_mod.LineList) !void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            try self.renderInto(alloc, width, lines);
        }
    };

    var backend = MockBackend{};
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const static_component = StaticComponent{ .lines = &[_][]const u8{ "one", "two" } };
    try renderer.render(static_component.component());

    const initial_write_count = backend.writes.items.len;
    backend.size = .{ .width = 14, .height = 5 };

    try renderer.render(static_component.component());

    try std.testing.expectEqual(initial_write_count + 1, backend.writes.items.len);
    const redraw = backend.writes.items[backend.writes.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, redraw, "\x1b[2J\x1b[H"));
    try std.testing.expect(std.mem.indexOf(u8, redraw, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, redraw, "two") != null);
}
