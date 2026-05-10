const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Tabs = struct {
    titles: []const []const u8,
    selected: ?usize = 0,
    style: vaxis.Cell.Style = .{},
    highlight_style: vaxis.Cell.Style = .{ .reverse = true },
    divider: []const u8 = "│",
    padding_left: []const u8 = " ",
    padding_right: []const u8 = " ",

    pub fn drawComponent(self: *const Tabs) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Tabs,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0) return .{ .width = 0, .height = 0 };

        const row: u16 = 0;
        var col: u16 = 0;
        const titles_len = self.titles.len;

        for (self.titles, 0..) |title, i| {
            const last_title = titles_len - 1 == i;
            const remaining = if (col < window.width) window.width - col else 0;
            if (remaining == 0) break;

            // left padding
            col = try writeSegment(window, col, row, self.padding_left, remaining, self.style);
            const remaining_after_left = if (col < window.width) window.width - col else 0;
            if (remaining_after_left == 0) break;

            // title
            const is_selected = if (self.selected) |s| s == i else false;
            const title_style = if (is_selected) self.highlight_style else self.style;
            col = try writeSegment(window, col, row, title, remaining_after_left, title_style);

            const remaining_after_title = if (col < window.width) window.width - col else 0;
            if (remaining_after_title == 0) break;

            // right padding
            col = try writeSegment(window, col, row, self.padding_right, remaining_after_title, self.style);
            const remaining_after_right = if (col < window.width) window.width - col else 0;
            if (remaining_after_right == 0 or last_title) break;

            // divider
            col = try writeSegment(window, col, row, self.divider, remaining_after_right, self.style);
        }

        return .{
            .width = window.width,
            .height = 1,
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Tabs = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }
};

fn writeSegment(
    window: vaxis.Window,
    start_col: u16,
    row: u16,
    text: []const u8,
    max_width: u16,
    style: vaxis.Cell.Style,
) std.mem.Allocator.Error!u16 {
    if (max_width == 0 or row >= window.height) return start_col;

    var col = start_col;
    var index: usize = 0;
    while (index < text.len and col < window.width) {
        const cluster = ansi.nextDisplayCluster(text, index);
        if (cluster.end <= index) break;
        if (cluster.width == 0) {
            index = cluster.end;
            continue;
        }
        if (@as(usize, col) + cluster.width > window.width) break;
        if (col - start_col >= max_width) break;

        window.writeCell(col, row, .{
            .char = .{
                .grapheme = text[index..cluster.end],
                .width = @intCast(cluster.width),
            },
            .style = style,
        });
        col += @intCast(cluster.width);
        index = cluster.end;
    }
    return col;
}

fn renderTabsToString(tabs: Tabs, width: usize, height: usize) ![]u8 {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = @intCast(@max(height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try tabs.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (0..screen.height) |row| {
        if (row > 0) try buffer.append(allocator, '\n');
        for (0..screen.width) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            const grapheme = if (cell.char.grapheme.len == 0) " " else cell.char.grapheme;
            try buffer.appendSlice(allocator, grapheme);
        }
    }
    return buffer.toOwnedSlice(allocator);
}

test "tabs renders titles with divider and highlight" {
    const allocator = std.testing.allocator;

    const tabs = Tabs{
        .titles = &.{ "Tab1", "Tab2", "Tab3" },
        .selected = 1,
    };

    const rendered = try renderTabsToString(tabs, 30, 1);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Tab1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Tab2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Tab3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│") != null);
}

test "tabs selected tab has highlight style" {
    const allocator = std.testing.allocator;

    const tabs = Tabs{
        .titles = &.{"A", "B"},
        .selected = 0,
        .highlight_style = .{ .reverse = true },
    };

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try tabs.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    const cell = screen.readCell(1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A", cell.char.grapheme);
    try std.testing.expect(cell.style.reverse);
}

test "tabs respects window width and truncates" {
    const allocator = std.testing.allocator;

    const tabs = Tabs{
        .titles = &.{ "VeryLongTab", "Another" },
        .selected = 0,
    };

    const rendered = try renderTabsToString(tabs, 8, 1);
    defer allocator.free(rendered);
    try std.testing.expect(rendered.len <= 8);
}

test "tabs empty titles renders nothing" {
    const allocator = std.testing.allocator;

    const tabs = Tabs{
        .titles = &.{},
        .selected = null,
    };

    const rendered = try renderTabsToString(tabs, 10, 1);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, rendered, " "));
}
