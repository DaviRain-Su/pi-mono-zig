const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const layout = @import("../layout.zig");
const resources_mod = @import("../theme.zig");

pub const Viewport = struct {
    child: component_mod.Component,
    height: usize,
    scroll_offset: usize = 0,
    anchor: layout.ViewportAnchor = .top,
    padding: layout.Insets = .{},
    show_indicators: bool = false,
    indicator_token: resources_mod.ThemeToken = .status,
    theme: ?*const resources_mod.Theme = null,

    pub fn component(self: *const Viewport) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderInto(
        self: *const Viewport,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);
        const inner_width = if (effective_width > self.padding.horizontal())
            effective_width - self.padding.horizontal()
        else
            1;
        const inner_height = if (self.height > self.padding.vertical())
            self.height - self.padding.vertical()
        else
            0;

        var child_lines = component_mod.LineList.empty;
        defer component_mod.freeLines(allocator, &child_lines);
        try self.child.renderInto(allocator, inner_width, &child_lines);

        const slice = resolveVisibleSlice(child_lines.items.len, inner_height, self.scroll_offset, self.anchor);
        const overflow_above = slice.start > 0;
        const overflow_below = slice.end < child_lines.items.len;

        try layout.appendBlankLines(allocator, lines, self.padding.top, effective_width);

        for (0..inner_height) |visible_index| {
            const rendered_line = if (visible_index < slice.end - slice.start)
                child_lines.items[slice.start + visible_index]
            else
                "";

            var line_text = rendered_line;
            var owned_indicator: ?[]u8 = null;
            defer if (owned_indicator) |indicator| allocator.free(indicator);

            if (self.show_indicators and inner_height > 0) {
                if (visible_index == 0 and overflow_above) {
                    owned_indicator = try indicatorLine(allocator, self.theme, self.indicator_token, inner_width, "↑ more");
                    line_text = owned_indicator.?;
                } else if (visible_index + 1 == inner_height and overflow_below) {
                    owned_indicator = try indicatorLine(allocator, self.theme, self.indicator_token, inner_width, "↓ more");
                    line_text = owned_indicator.?;
                }
            }

            const fitted = try layout.wrapInsetLineAlloc(
                allocator,
                line_text,
                inner_width,
                effective_width,
                self.padding,
                .stretch,
            );
            defer allocator.free(fitted);
            try component_mod.appendOwnedLine(lines, allocator, fitted);
        }

        try layout.appendBlankLines(allocator, lines, self.padding.bottom, effective_width);
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Viewport = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }
};

const SliceRange = struct {
    start: usize,
    end: usize,
};

fn resolveVisibleSlice(
    line_count: usize,
    height: usize,
    scroll_offset: usize,
    anchor: layout.ViewportAnchor,
) SliceRange {
    if (height == 0 or line_count == 0) return .{ .start = 0, .end = 0 };
    if (line_count <= height) return .{ .start = 0, .end = line_count };

    const max_start = line_count - height;
    const start = switch (anchor) {
        .top => @min(scroll_offset, max_start),
        .bottom => max_start -| @min(scroll_offset, max_start),
    };
    return .{
        .start = start,
        .end = start + height,
    };
}

fn indicatorLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    width: usize,
    text: []const u8,
) std.mem.Allocator.Error![]u8 {
    const fitted = try ansi.padRightVisibleAlloc(allocator, text, width);
    defer allocator.free(fitted);
    if (theme) |selected_theme| {
        return selected_theme.applyAlloc(allocator, token, fitted);
    }
    return allocator.dupe(u8, fitted);
}

const StaticLinesComponent = struct {
    lines: []const []const u8,

    fn component(self: *const StaticLinesComponent) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const StaticLinesComponent = @ptrCast(@alignCast(ptr));
        for (self.lines) |line| {
            const fitted = try ansi.padRightVisibleAlloc(allocator, line, width);
            defer allocator.free(fitted);
            try component_mod.appendOwnedLine(lines, allocator, fitted);
        }
    }
};

test "viewport clips top anchored content to fixed height" {
    const allocator = std.testing.allocator;

    const child = StaticLinesComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.component(),
        .height = 2,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try viewport.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "two") != null);
}

test "viewport bottom anchor keeps latest lines visible" {
    const allocator = std.testing.allocator;

    const child = StaticLinesComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.component(),
        .height = 2,
        .anchor = .bottom,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try viewport.renderInto(allocator, 8, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "four") != null);
}

test "viewport adds indicators when clipping overflow" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    const child = StaticLinesComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.component(),
        .height = 2,
        .scroll_offset = 1,
        .show_indicators = true,
        .theme = &theme,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try viewport.renderInto(allocator, 10, &lines);

    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "↑ more") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "↓ more") != null);
}
