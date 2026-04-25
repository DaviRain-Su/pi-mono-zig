const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const resources_mod = @import("../theme.zig");

pub const Box = struct {
    padding_x: usize = 1,
    padding_y: usize = 1,
    theme: ?*const resources_mod.Theme = null,
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
        const has_border = self.theme != null and effective_width >= 2;
        const border_width: usize = if (has_border) 2 else 0;
        const content_width = @max(effective_width, border_width + self.padding_x * 2 + 1) - border_width - self.padding_x * 2;

        var child_lines = component_mod.LineList.empty;
        defer component_mod.freeLines(allocator, &child_lines);

        for (self.children.items) |child| {
            try child.renderInto(allocator, content_width, &child_lines);
        }

        if (child_lines.items.len == 0) return;

        if (!has_border) {
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
            return;
        }

        const interior_width = effective_width - 2;
        const top_border = try renderBorderLine(allocator, self.theme.?, "┌", "┐", interior_width);
        defer allocator.free(top_border);
        try component_mod.appendOwnedLine(lines, allocator, top_border);

        const blank_inside = try renderInteriorLine(allocator, self.theme.?, "", self.padding_x, interior_width);
        defer allocator.free(blank_inside);
        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_inside);
        }

        for (child_lines.items) |child_line| {
            const rendered = try renderInteriorLine(allocator, self.theme.?, child_line, self.padding_x, interior_width);
            defer allocator.free(rendered);
            try component_mod.appendOwnedLine(lines, allocator, rendered);
        }

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_inside);
        }

        const bottom_border = try renderBorderLine(allocator, self.theme.?, "└", "┘", interior_width);
        defer allocator.free(bottom_border);
        try component_mod.appendOwnedLine(lines, allocator, bottom_border);
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

fn renderBorderLine(
    allocator: std.mem.Allocator,
    theme: *const resources_mod.Theme,
    left: []const u8,
    right: []const u8,
    interior_width: usize,
) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, left);
    for (0..interior_width) |_| {
        try builder.appendSlice(allocator, "─");
    }
    try builder.appendSlice(allocator, right);
    const themed = try theme.applyAlloc(allocator, .box_border, builder.items);
    builder.deinit(allocator);
    return themed;
}

fn renderInteriorLine(
    allocator: std.mem.Allocator,
    theme: *const resources_mod.Theme,
    child_line: []const u8,
    padding_x: usize,
    interior_width: usize,
) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, "│");
    try builder.appendNTimes(allocator, ' ', padding_x);
    try builder.appendSlice(allocator, child_line);
    const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, interior_width + 1);
    defer allocator.free(padded);

    var with_right = std.ArrayList(u8).empty;
    errdefer with_right.deinit(allocator);
    try with_right.appendSlice(allocator, padded);
    try with_right.appendSlice(allocator, "│");
    const themed = try theme.applyAlloc(allocator, .box_border, with_right.items);
    with_right.deinit(allocator);
    builder.deinit(allocator);
    return themed;
}

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

test "box renders themed borders when a theme is provided" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    const text = @import("text.zig").Text{
        .text = "hello",
        .padding_x = 0,
        .padding_y = 0,
    };

    var box = Box.init(1, 0);
    defer box.deinit(allocator);
    box.theme = &theme;
    try box.addChild(allocator, text.component());

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try box.renderInto(allocator, 9, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[2], "┘") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[") != null);
}
