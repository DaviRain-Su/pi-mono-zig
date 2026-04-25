const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const resources_mod = @import("../theme.zig");

pub const TextGradient = struct {
    start_hex: []const u8,
    end_hex: []const u8,
};

pub const Text = struct {
    text: []const u8 = "",
    padding_x: usize = 1,
    padding_y: usize = 1,
    theme: ?*const resources_mod.Theme = null,
    gradient: ?TextGradient = null,

    pub fn component(self: *const Text) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderInto(
        self: *const Text,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) return;

        const effective_width = @max(width, 1);
        const content_width = @max(effective_width, self.padding_x * 2 + 1) - self.padding_x * 2;

        var wrapped = component_mod.LineList.empty;
        defer component_mod.freeLines(allocator, &wrapped);
        try ansi.wrapTextWithAnsi(allocator, self.text, content_width, &wrapped);

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .text, blank_line);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
            }
        }

        for (wrapped.items) |line| {
            const rendered_line = try self.renderLineAlloc(allocator, line);
            defer allocator.free(rendered_line);

            var builder = std.ArrayList(u8).empty;
            errdefer builder.deinit(allocator);

            try builder.appendNTimes(allocator, ' ', self.padding_x);
            try builder.appendSlice(allocator, rendered_line);

            const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
            defer allocator.free(padded);
            if (self.gradient != null) {
                try component_mod.appendOwnedLine(lines, allocator, padded);
            } else if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .text, padded);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, padded);
            }
            builder.deinit(allocator);
        }

        for (0..self.padding_y) |_| {
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .text, blank_line);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
            }
        }
    }

    fn renderLineAlloc(self: *const Text, allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error![]u8 {
        const gradient = self.gradient orelse return allocator.dupe(u8, line);
        const start = ansi.parseHexColor(gradient.start_hex) orelse return allocator.dupe(u8, line);
        const end = ansi.parseHexColor(gradient.end_hex) orelse return allocator.dupe(u8, line);
        return ansi.applyHorizontalGradientAlloc(allocator, line, start, end);
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }
};

test "text renders wrapped ANSI content with padding" {
    const allocator = std.testing.allocator;
    const text = Text{
        .text = "\x1b[31mred blue\x1b[0m",
        .padding_x = 1,
        .padding_y = 1,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 6, &lines);

    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    try std.testing.expectEqual(@as(usize, 6), ansi.visibleWidth(lines.items[1]));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "\x1b[31m") != null);
}

test "text applies the active theme to padded output" {
    const allocator = std.testing.allocator;
    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    const text = Text{
        .text = "hello",
        .padding_x = 1,
        .padding_y = 0,
        .theme = &theme,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "hello") != null);
}

test "text supports horizontal gradients" {
    const allocator = std.testing.allocator;

    const text = Text{
        .text = "Glow",
        .padding_x = 0,
        .padding_y = 0,
        .gradient = .{
            .start_hex = "#ff0000",
            .end_hex = "#0000ff",
        },
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try text.renderInto(allocator, 6, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[38;2;255;0;0mG") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[38;2;0;0;255mw") != null);
}
