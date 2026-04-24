const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");

pub const Text = struct {
    text: []const u8 = "",
    padding_x: usize = 1,
    padding_y: usize = 1,

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
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }

        for (wrapped.items) |line| {
            var builder = std.ArrayList(u8).empty;
            errdefer builder.deinit(allocator);

            try builder.appendNTimes(allocator, ' ', self.padding_x);
            try builder.appendSlice(allocator, line);

            const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
            defer allocator.free(padded);
            try component_mod.appendOwnedLine(lines, allocator, padded);
            builder.deinit(allocator);
        }

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }
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
