const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("draw.zig");
const theme_mod = @import("theme.zig");

pub fn renderToScreen(component: draw_mod.Component, width: usize, height: usize) !vaxis.AllocatingScreen {
    return renderToScreenWithTheme(component, width, height, null);
}

pub fn renderToScreenWithTheme(
    component: draw_mod.Component,
    width: usize,
    height: usize,
    theme: ?*const theme_mod.Theme,
) !vaxis.AllocatingScreen {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = @intCast(@max(height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try component.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
        .theme = theme,
    });

    var rendered = try vaxis.AllocatingScreen.init(
        std.testing.allocator,
        @intCast(@max(width, 1)),
        @intCast(@max(height, 1)),
    );
    errdefer rendered.deinit(std.testing.allocator);

    for (0..@max(height, 1)) |row| {
        for (0..@max(width, 1)) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (cell.default and cell.char.grapheme.len == 0) continue;
            rendered.writeCell(@intCast(col), @intCast(row), normalizeCell(cell));
        }
    }

    return rendered;
}

pub fn screenToString(screen: *vaxis.AllocatingScreen) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(std.testing.allocator);

    for (0..screen.height) |row| {
        if (row > 0) try buffer.append(std.testing.allocator, '\n');
        for (0..screen.width) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            const grapheme = if (cell.char.grapheme.len == 0) " " else cell.char.grapheme;
            try buffer.appendSlice(std.testing.allocator, grapheme);
        }
    }

    return buffer.toOwnedSlice(std.testing.allocator);
}

pub fn expectCell(
    screen: *vaxis.AllocatingScreen,
    col: usize,
    row: usize,
    grapheme: []const u8,
    style: vaxis.Cell.Style,
) !void {
    const cell = screen.readCell(@intCast(col), @intCast(row)) orelse return error.TestUnexpectedResult;
    const actual = if (cell.char.grapheme.len == 0) " " else cell.char.grapheme;
    try std.testing.expectEqualStrings(grapheme, actual);
    try std.testing.expectEqual(style, cell.style);
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
