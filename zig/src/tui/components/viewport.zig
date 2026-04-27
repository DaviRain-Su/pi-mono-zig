const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const layout = @import("../layout.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");
const vaxis_adapter_mod = @import("../vaxis_adapter.zig");

pub const Viewport = struct {
    child: component_mod.Component,
    draw_child: ?draw_mod.Component = null,
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

    pub fn drawComponent(self: *const Viewport) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
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

    pub fn draw(
        self: *const Viewport,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const effective_height = @min(self.height, @as(usize, window.height));
        const inner_window = insetWindow(window, self.padding, effective_height) orelse {
            return .{
                .width = window.width,
                .height = @intCast(effective_height),
            };
        };
        const inner_height = if (self.height > self.padding.vertical())
            self.height - self.padding.vertical()
        else
            0;
        const measurement_height = @max(inner_height + self.scroll_offset + 1, @as(usize, 64));

        const rendered = try renderChildToScreen(
            ctx.arena,
            self.child,
            self.draw_child,
            @max(@as(usize, inner_window.width), 1),
            @max(measurement_height, 1),
            ctx.theme,
        );
        defer {
            rendered.screen.deinit(ctx.arena);
            ctx.arena.destroy(rendered.screen);
        }

        const slice = resolveVisibleSlice(rendered.line_count, inner_height, self.scroll_offset, self.anchor);
        const overflow_above = slice.start > 0;
        const overflow_below = slice.end < rendered.line_count;

        blitAllocatingScreen(rendered.screen, inner_window, slice.start);

        if (self.show_indicators and inner_height > 0) {
            if (overflow_above) {
                drawIndicator(inner_window.child(.{ .y_off = 0, .height = 1 }), ctx.theme orelse self.theme, self.indicator_token, "↑ more");
            }
            if (overflow_below and inner_height <= inner_window.height) {
                drawIndicator(
                    inner_window.child(.{ .y_off = @intCast(inner_height - 1), .height = 1 }),
                    ctx.theme orelse self.theme,
                    self.indicator_token,
                    "↓ more",
                );
            }
        }

        return .{
            .width = window.width,
            .height = @intCast(effective_height),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Viewport = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

const SliceRange = struct {
    start: usize,
    end: usize,
};

const RenderedChild = struct {
    screen: *vaxis.AllocatingScreen,
    line_count: usize,
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

fn renderChildToScreen(
    allocator: std.mem.Allocator,
    child: component_mod.Component,
    draw_child: ?draw_mod.Component,
    width: usize,
    min_height: usize,
    theme: ?*const resources_mod.Theme,
) std.mem.Allocator.Error!RenderedChild {
    if (draw_child) |draw_component| {
        return renderDrawChildToScreen(allocator, draw_component, width, min_height, theme);
    }
    return renderLegacyChildToScreen(allocator, child, width, min_height);
}

fn renderDrawChildToScreen(
    allocator: std.mem.Allocator,
    child: draw_mod.Component,
    width: usize,
    min_height: usize,
    theme: ?*const resources_mod.Theme,
) std.mem.Allocator.Error!RenderedChild {
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = @intCast(@max(min_height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const size = try child.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
        .theme = theme,
    });
    return .{
        .screen = try cloneScreen(allocator, &screen, width, @max(min_height, @as(usize, size.height))),
        .line_count = @max(@as(usize, size.height), 1),
    };
}

fn renderLegacyChildToScreen(
    allocator: std.mem.Allocator,
    child: component_mod.Component,
    width: usize,
    min_height: usize,
) std.mem.Allocator.Error!RenderedChild {
    var child_lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &child_lines);
    try child.renderInto(allocator, @max(width, 1), &child_lines);

    const screen_height = @max(child_lines.items.len, @max(min_height, 1));
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = @intCast(screen_height),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    try vaxis_adapter_mod.renderLineListToWindow(window, child_lines.items, allocator);

    return .{
        .screen = try cloneScreen(allocator, &screen, width, screen_height),
        .line_count = child_lines.items.len,
    };
}

fn cloneScreen(
    allocator: std.mem.Allocator,
    screen: *vaxis.Screen,
    width: usize,
    height: usize,
) std.mem.Allocator.Error!*vaxis.AllocatingScreen {
    const rendered = try allocator.create(vaxis.AllocatingScreen);
    errdefer allocator.destroy(rendered);

    rendered.* = try vaxis.AllocatingScreen.init(
        allocator,
        @intCast(@max(width, 1)),
        @intCast(@max(height, 1)),
    );
    errdefer rendered.deinit(allocator);

    for (0..@max(height, 1)) |row| {
        for (0..@max(width, 1)) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (cell.default and cell.char.grapheme.len == 0) continue;
            rendered.writeCell(@intCast(col), @intCast(row), normalizeCell(cell));
        }
    }

    return rendered;
}

fn normalizeCell(cell: vaxis.Cell) vaxis.Cell {
    if (cell.char.grapheme.len != 0) return cell;

    var normalized = cell;
    normalized.char = .{
        .grapheme = " ",
        .width = 1,
    };
    return normalized;
}

fn insetWindow(window: vaxis.Window, padding: layout.Insets, total_height: usize) ?vaxis.Window {
    const visible_height = @min(total_height, @as(usize, window.height));
    if (visible_height == 0) return null;

    const left: u16 = @intCast(@min(padding.left, @as(usize, window.width)));
    const right: u16 = @intCast(@min(padding.right, @as(usize, window.width) - @min(@as(usize, window.width), padding.left)));
    const top: u16 = @intCast(@min(padding.top, visible_height));
    const bottom: u16 = @intCast(@min(padding.bottom, visible_height - @min(visible_height, padding.top)));
    if (@as(usize, window.width) <= left + right or visible_height <= top + bottom) return null;

    return window.child(.{
        .x_off = @intCast(left),
        .y_off = @intCast(top),
        .width = window.width - left - right,
        .height = @intCast(visible_height - top - bottom),
    });
}

fn blitAllocatingScreen(source: *vaxis.AllocatingScreen, destination: vaxis.Window, source_start_row: usize) void {
    const row_count = @min(destination.height, source.height -| source_start_row);
    const col_count = @min(destination.width, source.width);
    for (0..row_count) |row| {
        for (0..col_count) |col| {
            const cell = source.readCell(@intCast(col), @intCast(source_start_row + row)) orelse continue;
            if (cell.default and cell.char.grapheme.len == 0) continue;
            destination.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
}

fn drawIndicator(
    window: vaxis.Window,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    text: []const u8,
) void {
    const style = if (theme) |active_theme| style_mod.styleFor(active_theme, token) else vaxis.Cell.Style{};
    window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
    _ = window.printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
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

test "viewport draw shows top anchored rows from off-screen screen" {
    const child = StaticLinesComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.component(),
        .height = 2,
    };

    var screen = try test_helpers.renderToScreen(viewport.drawComponent(), 8, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "o", .{});
    try test_helpers.expectCell(&screen, 0, 1, "t", .{});
}

test "viewport draw scrolls a borrowed cell window" {
    const selected_style = vaxis.Cell.Style{ .reverse = true };
    const row_one = [_]vaxis.Cell{.{ .char = .{ .grapheme = "1", .width = 1 } }};
    const row_two = [_]vaxis.Cell{.{ .char = .{ .grapheme = "2", .width = 1 }, .style = selected_style }};
    const row_three = [_]vaxis.Cell{.{ .char = .{ .grapheme = "3", .width = 1 } }};
    const blank = StaticLinesComponent{ .lines = &[_][]const u8{""} };

    const BorrowedRows = struct {
        const Row = struct { cells: []const vaxis.Cell };
        rows: []const Row,

        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{
                .ptr = self,
                .drawFn = draw,
            };
        }

        fn draw(ptr: *const anyopaque, window: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            window.clear();
            for (self.rows, 0..) |row, row_index| {
                if (row_index >= @as(usize, window.height)) break;
                for (row.cells, 0..) |cell, col| {
                    if (col >= @as(usize, window.width)) break;
                    window.writeCell(@intCast(col), @intCast(row_index), cell);
                }
            }
            return .{
                .width = window.width,
                .height = @intCast(@min(self.rows.len, @as(usize, window.height))),
            };
        }
    };

    const borrowed = BorrowedRows{
        .rows = &[_]BorrowedRows.Row{
            .{ .cells = &row_one },
            .{ .cells = &row_two },
            .{ .cells = &row_three },
        },
    };
    const viewport = Viewport{
        .child = blank.component(),
        .draw_child = borrowed.drawComponent(),
        .height = 2,
        .scroll_offset = 1,
    };

    var screen = try test_helpers.renderToScreen(viewport.drawComponent(), 2, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "2", selected_style);
    try test_helpers.expectCell(&screen, 0, 1, "3", .{});
}
