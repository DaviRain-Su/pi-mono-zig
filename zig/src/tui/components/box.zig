const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");

pub const Box = struct {
    padding_x: usize = 1,
    padding_y: usize = 1,
    children: std.ArrayList(component_mod.Component) = .empty,

    pub fn init(padding_x: usize, padding_y: usize) Box {
        return .{
            .padding_x = padding_x,
            .padding_y = padding_y,
        };
    }

    pub fn deinit(self: *Box, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.* = undefined;
    }

    pub fn addChild(self: *Box, allocator: std.mem.Allocator, child: component_mod.Component) std.mem.Allocator.Error!void {
        try self.children.append(allocator, child);
    }

    pub fn component(self: *const Box) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderInto(
        self: *const Box,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (self.children.items.len == 0) return;

        const effective_width = @max(width, 1);
        const content_width = @max(effective_width, self.padding_x * 2 + 1) - self.padding_x * 2;

        var child_lines = component_mod.LineList.empty;
        defer component_mod.freeLines(allocator, &child_lines);

        for (self.children.items) |child| {
            try child.renderInto(allocator, content_width, &child_lines);
        }

        if (child_lines.items.len == 0) return;

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }

        for (child_lines.items) |child_line| {
            var builder = std.ArrayList(u8).empty;
            errdefer builder.deinit(allocator);

            try builder.appendNTimes(allocator, ' ', self.padding_x);
            try builder.appendSlice(allocator, child_line);

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
        const self: *const Box = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }
};

test "box renders nested text with outer padding" {
    const allocator = std.testing.allocator;

    const text = @import("text.zig").Text{
        .text = "hello",
        .padding_x = 0,
        .padding_y = 0,
    };

    var box = Box.init(1, 1);
    defer box.deinit(allocator);
    try box.addChild(allocator, text.component());

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try box.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("        ", lines.items[0]);
    try std.testing.expectEqualStrings(" hello  ", lines.items[1]);
    try std.testing.expectEqualStrings("        ", lines.items[2]);
}
