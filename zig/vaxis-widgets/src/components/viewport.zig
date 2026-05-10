const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const layout = @import("../layout.zig");
const scroll_mod = @import("../scroll.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Viewport = struct {
    child: draw_mod.Component,
    height: usize,
    scroll_offset: usize = 0,
    anchor: layout.ViewportAnchor = .top,
    padding: layout.Insets = .{},
    show_indicators: bool = false,
    indicator_style: vaxis.Cell.Style = .{},
    show_scrollbar: bool = false,
    scrollbar_thumb: []const u8 = "█",
    scrollbar_track: []const u8 = "│",

    pub fn drawComponent(self: *const Viewport) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
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
            @max(@as(usize, inner_window.width), 1),
            @max(measurement_height, 1),
        );
        defer {
            rendered.screen.deinit(ctx.arena);
            ctx.arena.destroy(rendered.screen);
        }

        const slice = resolveVisibleSlice(rendered.line_count, inner_height, self.scroll_offset, self.anchor);
        const overflow_above = slice.start > 0;
        const overflow_below = slice.end < rendered.line_count;

        blitAllocatingScreen(rendered.screen, inner_window, slice.start);

        if (self.show_scrollbar and inner_height > 0 and rendered.line_count > inner_height) {
            const scroll_offset = slice.start;
            const thumb = scroll_mod.thumb(inner_height, rendered.line_count, inner_height, scroll_offset);
            const scroll_col = inner_window.width -| 1;
            for (0..inner_height) |i| {
                const row_y: u16 = @intCast(i);
                if (row_y >= inner_window.height) break;
                const is_thumb = i >= thumb.start and i < thumb.start + thumb.length;
                inner_window.writeCell(scroll_col, row_y, .{
                    .char = .{ .grapheme = if (is_thumb) self.scrollbar_thumb else self.scrollbar_track, .width = 1 },
                    .style = .{},
                });
            }
        }

        if (self.show_indicators and inner_height > 0) {
            if (overflow_above) {
                drawIndicator(inner_window.child(.{ .y_off = 0, .height = 1 }), self.indicator_style, "↑ more");
            }
            if (overflow_below and inner_height <= inner_window.height) {
                drawIndicator(
                    inner_window.child(.{ .y_off = @intCast(inner_height - 1), .height = 1 }),
                    self.indicator_style,
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

    const max_start = scroll_mod.clampOffset(line_count, height, std.math.maxInt(usize));
    const start = switch (anchor) {
        .top => scroll_mod.clampOffset(line_count, height, scroll_offset),
        .bottom => max_start -| @min(scroll_offset, max_start),
    };
    return .{
        .start = start,
        .end = start + height,
    };
}

fn renderChildToScreen(
    allocator: std.mem.Allocator,
    child: draw_mod.Component,
    width: usize,
    min_height: usize,
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
    });
    return .{
        .screen = try cloneScreen(allocator, &screen, width, @max(min_height, @as(usize, size.height))),
        .line_count = @max(@as(usize, size.height), 1),
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
    style: vaxis.Cell.Style,
    text: []const u8,
) void {
    window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
    _ = window.printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
}

const StaticLinesDrawComponent = struct {
    lines: []const []const u8,

    fn drawComponent(self: *const StaticLinesDrawComponent) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *const anyopaque, window: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const StaticLinesDrawComponent = @ptrCast(@alignCast(ptr));
        window.clear();
        for (self.lines, 0..) |line, row_index| {
            if (row_index >= @as(usize, window.height)) break;
            const row_window = window.child(.{
                .y_off = @intCast(row_index),
                .height = 1,
            });
            _ = row_window.printSegment(.{ .text = line }, .{ .wrap = .none });
        }
        return .{
            .width = window.width,
            .height = @intCast(@min(self.lines.len, @as(usize, window.height))),
        };
    }
};

test "viewport clips top anchored content to fixed height" {
    const child = StaticLinesDrawComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.drawComponent(),
        .height = 2,
    };

    var screen = try test_helpers.renderToScreen(viewport.drawComponent(), 8, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "o", .{});
    try test_helpers.expectCell(&screen, 0, 1, "t", .{});
}

test "viewport bottom anchor keeps latest lines visible" {
    const child = StaticLinesDrawComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.drawComponent(),
        .height = 2,
        .anchor = .bottom,
    };

    var screen = try test_helpers.renderToScreen(viewport.drawComponent(), 8, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "t", .{});
    try test_helpers.expectCell(&screen, 0, 1, "f", .{});
}

test "viewport adds indicators when clipping overflow" {
    const child = StaticLinesDrawComponent{
        .lines = &[_][]const u8{ "one", "two", "three", "four" },
    };
    const viewport = Viewport{
        .child = child.drawComponent(),
        .height = 2,
        .scroll_offset = 1,
        .show_indicators = true,
        .indicator_style = .{ .dim = true },
    };

    var screen = try test_helpers.renderToScreen(viewport.drawComponent(), 10, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "↑", .{ .dim = true });
    try test_helpers.expectCell(&screen, 0, 1, "↓", .{ .dim = true });
}

test "viewport draw scrolls a borrowed cell window" {
    const selected_style = vaxis.Cell.Style{ .reverse = true };
    const row_one = [_]vaxis.Cell{.{ .char = .{ .grapheme = "1", .width = 1 } }};
    const row_two = [_]vaxis.Cell{.{ .char = .{ .grapheme = "2", .width = 1 }, .style = selected_style }};
    const row_three = [_]vaxis.Cell{.{ .char = .{ .grapheme = "3", .width = 1 } }};

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
        .child = borrowed.drawComponent(),
        .height = 2,
        .scroll_offset = 1,
    };

    var screen = try test_helpers.renderToScreen(viewport.drawComponent(), 2, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "2", selected_style);
    try test_helpers.expectCell(&screen, 0, 1, "3", .{});
}
